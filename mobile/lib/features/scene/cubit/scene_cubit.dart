import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/job_registry_service.dart';
import '../../../core/models/models.dart';
import 'scene_state.dart';

/// Cubit for the Scene Detail Screen (FEAT-014, FEAT-015, FEAT-016).
///
/// Owns three Firestore real-time listeners:
///   1. Scene document — scene_text, storyboard_body, gcs_video_path
///   2. Scene assets subcollection — per-scene asset documents
///   3. Global assets collection — used to resolve pass-through GCS image paths
///
/// On every listener update the cubit rebuilds [SceneLoaded] by merging all
/// three snapshots plus the local generation flags.
///
/// Completion of video generation is detected when the Firestore listener
/// delivers a non-null gcs_video_path — no Timer.periodic polling.
class SceneCubit extends Cubit<SceneState> {
  SceneCubit({
    required this.projectSlug,
    required this.sceneNumber,
    required this.apiClient,
    required this.jobRegistryService,
  }) : super(SceneLoading());

  final String projectSlug;
  final int sceneNumber;
  final ArkMaskApiClient apiClient;
  final JobRegistryService jobRegistryService;

  // ── Firestore subscriptions ────────────────────────────────────────────────

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _projectDocSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sceneDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sceneAssetsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _globalAssetsSub;

  // ── Snapshot caches ────────────────────────────────────────────────────────

  /// Parsed scene document. Null until the first snapshot arrives.
  SceneDocument? _sceneDoc;

  /// Scene body text parsed from the project's `story_content` field.
  ///
  /// `story_content` is the canonical source of truth — SceneCubit subscribes
  /// to the project document and re-parses this field on every change so that
  /// edits made in the Story Editor are immediately reflected here without
  /// requiring a separate `scene_text` write per scene doc.
  String? _sceneText;

  List<AssetDocument> _sceneAssets = [];
  List<AssetDocument> _globalAssets = [];

  // ── Generation flags (mutable, not from Firestore) ─────────────────────────

  bool _isGeneratingStoryboard = false;
  bool _isGeneratingVideo = false;
  String? _currentStoryboardJobId;
  String? _currentVideoJobId;
  String? _storyboardError;
  String? _videoError;
  int _selectedTabIndex = 0;

  // ── Load ──────────────────────────────────────────────────────────────────

  Future<void> load() async {
    emit(SceneLoading());

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(SceneError(message: 'Not authenticated.'));
      return;
    }

    final db = FirebaseFirestore.instance;
    final projectPath = 'users/$uid/projects/$projectSlug';
    final sceneId = sceneNumber.toString();

    // ── 0. Project document — parse story_content for this scene's text ────
    //
    // story_content is the canonical source of truth for scene bodies.
    // Subscribing here means any edit saved in the Story Editor is reflected
    // immediately without a separate scene_text write per scene document.
    _projectDocSub = db.doc(projectPath).snapshots().listen(
      (snap) {
        final raw = snap.data()?['story_content'] as String? ?? '';
        _sceneText = _parseSceneText(raw, sceneNumber);
        _rebuildState();
      },
      onError: (Object e) =>
          emit(SceneError(message: 'Project listener error: $e')),
    );

    // ── 1. Scene document ──────────────────────────────────────────────────
    _sceneDocSub = db
        .doc('$projectPath/scenes/$sceneId')
        .snapshots()
        .listen(
      (snap) {
        if (!snap.exists || snap.data() == null) {
          _sceneDoc = null;
        } else {
          final data = snap.data()!;
          final prevVideoPath = _sceneDoc?.gcsVideoPath;
          final prevStoryboard = _sceneDoc?.storyboardBody;
          _sceneDoc = SceneDocument.fromFirestore(snap.id, data);

          // Detect storyboard completion: storyboard_body transitioned from
          // null to non-null (async /video-prompt job). Clear the generating
          // flag and update job registry — same pattern as video below.
          if (_isGeneratingStoryboard &&
              prevStoryboard == null &&
              _sceneDoc!.storyboardBody != null) {
            _isGeneratingStoryboard = false;
            if (_currentStoryboardJobId != null) {
              jobRegistryService.updateStatus(
                _currentStoryboardJobId!,
                'success',
                resolvedAt: DateTime.now(),
              );
              _currentStoryboardJobId = null;
            }
            // Auto-switch to the Storyboard tab so the user sees the result
            // (previously done inline after the synchronous HTTP response).
            _selectedTabIndex = 1;
          }

          // Detect video completion: gcs_video_path transitioned from null
          // to non-null. Clear the generating flag and update job registry.
          if (_isGeneratingVideo &&
              prevVideoPath == null &&
              _sceneDoc!.gcsVideoPath != null) {
            _isGeneratingVideo = false;
            if (_currentVideoJobId != null) {
              jobRegistryService.updateStatus(
                _currentVideoJobId!,
                'success',
                resolvedAt: DateTime.now(),
              );
              _currentVideoJobId = null;
            }
          }
        }
        _rebuildState();
      },
      onError: (Object e) =>
          emit(SceneError(message: 'Scene listener error: $e')),
    );

    // ── 2. Scene assets subcollection ──────────────────────────────────────
    _sceneAssetsSub = db
        .collection('$projectPath/scenes/$sceneId/assets')
        .snapshots()
        .listen(
      (snap) {
        _sceneAssets = snap.docs
            .map((d) => AssetDocument.fromFirestore(d.id, d.data()))
            .toList();
        _rebuildState();
      },
      onError: (Object e) =>
          emit(SceneError(message: 'Scene assets listener error: $e')),
    );

    // ── 3. Global assets collection ────────────────────────────────────────
    _globalAssetsSub = db
        .collection('$projectPath/assets')
        .snapshots()
        .listen(
      (snap) {
        _globalAssets = snap.docs
            .map((d) => AssetDocument.fromFirestore(d.id, d.data()))
            .toList();
        _rebuildState();
      },
      onError: (Object e) =>
          emit(SceneError(message: 'Global assets listener error: $e')),
    );
  }

  // ── State builder ─────────────────────────────────────────────────────────

  /// Merges the three Firestore snapshots with the local generation flags into
  /// a [SceneLoaded] state.
  void _rebuildState() {
    if (isClosed) return;

    final resolved = <SceneAsset>[];
    for (final asset in _sceneAssets) {
      final isPassThrough = asset.description.isEmpty;
      String? gcsImagePath;

      if (isPassThrough) {
        // Pass-through: find the global asset with matching base name and use
        // its gcs_image_path. The scene asset's name is `@/scenes/N/{baseName}`.
        final baseName = _extractBaseName(asset.name);
        final global = _findGlobalAsset(baseName);
        gcsImagePath = global?.gcsImagePath;
      } else {
        gcsImagePath = asset.gcsImagePath;
      }

      resolved.add(SceneAsset(
        id: asset.id,
        name: asset.name,
        type: asset.type,
        description: asset.description,
        promptBody: asset.promptBody,
        gcsImagePath: gcsImagePath,
        isPassThrough: isPassThrough,
      ));
    }

    // Sort: background (0) → character (1) → object (2). Stable sort preserves
    // relative FCFS order within each type group.
    resolved.sort(
      (a, b) => _typePriority(a.type).compareTo(_typePriority(b.type)),
    );

    emit(SceneLoaded(
      sceneNumber: sceneNumber,
      sceneText: _sceneText,
      storyboardBody: _sceneDoc?.storyboardBody,
      gcsVideoPath: _sceneDoc?.gcsVideoPath,
      assets: resolved,
      isGeneratingStoryboard: _isGeneratingStoryboard,
      isGeneratingVideo: _isGeneratingVideo,
      storyboardError: _storyboardError,
      videoError: _videoError,
      selectedTabIndex: _selectedTabIndex,
    ));
  }

  // ── Tab switch ────────────────────────────────────────────────────────────

  void switchTab(int index) {
    _selectedTabIndex = index;
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(selectedTabIndex: index));
  }

  // ── Generate Storyboard (FEAT-014) ────────────────────────────────────────

  Future<void> generateStoryboard() async {
    final s = state;
    if (s is! SceneLoaded) return;

    // Guard: all assets must have GCS images before generating a storyboard.
    if (s.assets.isEmpty || !s.allAssetsHaveImages) {
      _storyboardError = 'All asset images must be generated first.';
      emit(s.copyWith(storyboardError: _storyboardError));
      return;
    }

    final sceneText = s.sceneText ?? '';

    // Collect ordered GCS image paths (already sorted by type priority).
    final refImageGcsPaths = [
      for (final asset in s.assets)
        if (asset.gcsImagePath != null) asset.gcsImagePath!,
    ];

    _isGeneratingStoryboard = true;
    _storyboardError = null;
    emit(s.copyWith(
      isGeneratingStoryboard: true,
      storyboardError: null,
    ));

    try {
      final jobId = await apiClient.generateVideoPrompt(
        projectSlug: projectSlug,
        sceneIndex: sceneNumber,
        sceneText: sceneText,
        refImageGcsPaths: refImageGcsPaths,
      );

      // Register the job in the local Hive CE registry so it survives
      // app restarts and can be polled on foreground return (FEAT-017).
      await jobRegistryService.register(JobRegistryEntry(
        jobId: jobId,
        type: 'video_prompt',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: sceneNumber,
      ));

      // Store for the Firestore listener to mark success on completion.
      _currentStoryboardJobId = jobId;

      // isGeneratingStoryboard stays true — the Firestore listener clears it
      // (and auto-switches to the Storyboard tab) when storyboard_body is
      // set on the scene document.
    } on ApiInsufficientCredits {
      _isGeneratingStoryboard = false;
      _storyboardError = '__credits__';
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      _isGeneratingStoryboard = false;
      _storyboardError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: msg,
        ));
      }
    } catch (e) {
      final msg = e.toString();
      _isGeneratingStoryboard = false;
      _storyboardError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: msg,
        ));
      }
    }
  }

  // ── Generate Video (FEAT-016) ─────────────────────────────────────────────

  Future<void> generateVideo() async {
    final s = state;
    if (s is! SceneLoaded) return;
    if (!s.hasStoryboard) return;

    // Collect ordered GCS image paths (already sorted by type priority).
    final refImageGcsPaths = [
      for (final asset in s.assets)
        if (asset.gcsImagePath != null) asset.gcsImagePath!,
    ];

    _isGeneratingVideo = true;
    _videoError = null;
    emit(s.copyWith(
      isGeneratingVideo: true,
      videoError: null,
    ));

    try {
      final jobId = await apiClient.generateVideo(
        projectSlug: projectSlug,
        sceneIndex: sceneNumber,
        refImageGcsPaths: refImageGcsPaths,
      );

      // Register the job in the local Hive CE registry so it survives
      // app restarts and can be polled on foreground return (FEAT-017).
      await jobRegistryService.register(JobRegistryEntry(
        jobId: jobId,
        type: 'video',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: sceneNumber,
      ));

      // Store for the Firestore listener to mark success on completion.
      _currentVideoJobId = jobId;

      // isGeneratingVideo stays true — the Firestore listener clears it
      // when gcs_video_path is set on the scene document.
    } on ApiInsufficientCredits {
      _isGeneratingVideo = false;
      _videoError = '__credits__';
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      _isGeneratingVideo = false;
      _videoError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: msg,
        ));
      }
    } catch (e) {
      final msg = e.toString();
      _isGeneratingVideo = false;
      _videoError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: msg,
        ));
      }
    }
  }

  // ── Error dismissal ───────────────────────────────────────────────────────

  void clearStoryboardError() {
    _storyboardError = null;
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(storyboardError: null));
  }

  void clearVideoError() {
    _videoError = null;
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(videoError: null));
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Parses `story_content` (MDX with `# N` headings) and returns the body
  /// for [targetScene], or `null` if the heading is not found.
  ///
  /// Mirrors the logic in `StoryCubit._parseScenes` but returns a single
  /// scene body rather than the full list.
  static String? _parseSceneText(String raw, int targetScene) {
    if (raw.trim().isEmpty) return null;
    final headingPattern = RegExp(r'^# (\d+)\s*$', multiLine: true);
    final matches = headingPattern.allMatches(raw).toList();
    if (matches.isEmpty) {
      // No headings — treat entire content as scene 1.
      return targetScene == 1 ? raw.trim() : null;
    }
    for (var i = 0; i < matches.length; i++) {
      final number = int.parse(matches[i].group(1)!);
      if (number != targetScene) continue;
      final bodyStart = matches[i].end;
      final bodyEnd = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      return raw.substring(bodyStart, bodyEnd).trim();
    }
    return null;
  }

  /// Extracts the base asset name from a pass-through reference.
  ///
  /// Reference format: `@/scenes/N/{baseName}` → returns `{baseName}`.
  /// Falls back to the last path segment or the full name if the format
  /// does not match.
  static String _extractBaseName(String name) {
    // Strip leading '@' before splitting.
    final withoutAt =
        name.startsWith('@') ? name.substring(1) : name;
    final parts = withoutAt.split('/').where((s) => s.isNotEmpty).toList();
    // Expected: ['scenes', 'N', 'baseName'] — take the last segment.
    return parts.isNotEmpty ? parts.last : name;
  }

  /// Returns the global asset whose name matches [baseName] (case-insensitive).
  AssetDocument? _findGlobalAsset(String baseName) {
    final lower = baseName.toLowerCase();
    for (final g in _globalAssets) {
      if (g.name == baseName || g.name.toLowerCase() == lower) return g;
    }
    return null;
  }

  /// Sort priority for asset types — lower value sorts first.
  ///
  /// background (0) → character (1) → object (2).
  /// This ordering ensures scene-defining refs are sent first to generation
  /// models that enforce a hard ref cap (e.g. Veo's 3-image limit).
  static int _typePriority(AssetType type) => switch (type) {
        AssetType.background => 0,
        AssetType.character => 1,
        AssetType.object => 2,
      };

  static String _apiErrorMessage(ApiError e) => switch (e) {
        ApiConflict(:final message) => message,
        ApiValidationError(:final detail) => detail,
        ApiServerError(:final message) => message,
        ApiNetworkError(:final message) => message,
        ApiUnknownError(:final message) => message,
        ApiInsufficientCredits() => 'Insufficient credits',
        ApiUnauthorized() => 'Unauthorized',
      };

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> close() {
    _projectDocSub?.cancel();
    _sceneDocSub?.cancel();
    _sceneAssetsSub?.cancel();
    _globalAssetsSub?.cancel();
    return super.close();
  }
}
