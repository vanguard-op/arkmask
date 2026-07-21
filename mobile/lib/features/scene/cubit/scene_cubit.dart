import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import 'scene_state.dart';

/// Cubit for the Scene Detail Screen (FEAT-014, FEAT-015, FEAT-016).
///
/// Owns three Firestore real-time listeners:
///   1. Scene document — scene_text, storyboard_body, gcs_video_path
///   2. Scene assets subcollection — per-scene asset documents
///   3. Global assets collection — used to resolve pass-through GCS image paths
///
/// [isGeneratingStoryboard] / [isGeneratingVideo] are derived live from
/// [JobsCubit] (the app-lifetime job orchestrator) rather than owned as local
/// mutable flags — see [_syncGeneratingFlags]. This means returning to this
/// screen mid-generation correctly restores the spinner, and the flag clears
/// as soon as the job resolves even if that happens while a different screen
/// is on top (via FCM or [JobsCubit.pollPendingJobs]).
///
/// Completion is additionally detected as a fast path when the Firestore
/// listener delivers a non-null `storyboard_body` / `gcs_video_path` — it now
/// calls [JobsCubit.resolve] instead of writing to the registry directly.
class SceneCubit extends Cubit<SceneState> {
  SceneCubit({
    required this.projectSlug,
    required this.sceneNumber,
    required this.apiClient,
    required this.jobsCubit,
  }) : super(SceneLoading());

  final String projectSlug;
  final int sceneNumber;
  final ArkMaskApiClient apiClient;
  final JobsCubit jobsCubit;

  // ── Firestore subscriptions ────────────────────────────────────────────────

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _projectDocSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sceneDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sceneAssetsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _globalAssetsSub;
  StreamSubscription<JobsState>? _jobsSub;

  /// Lazily-opened listeners on other scenes' local asset subcollections,
  /// keyed by scene number. A pass-through `ref` (FEAT-013 — see
  /// docs/ArkMask/schema.md "Global Asset Document") of the form
  /// `'scenes/N/assets/<slug>'` with N != 0 points at a *scene-local* asset
  /// defined in scene N — those are never copied into the project-level
  /// `assets` collection (only scene_number == 0 assets are — see
  /// asset_writer.write_extracted_assets), so resolving such a reference
  /// requires reading scene N's own `assets` subcollection directly. Opened
  /// on demand as references are discovered in `_rebuildState`, never closed
  /// until this cubit closes.
  ///
  /// Note: this cubit resolves only ONE hop of a `ref` chain (for live UI
  /// gating — "does this scene's directly-referenced source have an image
  /// yet"). A `ref` chain with more than one hop resolves fully and
  /// authoritatively server-side at generation time (see
  /// app.services.asset_ref.resolve_asset_ref_chain /
  /// app.services.scene_assets.resolve_scene_assets), which is what actually
  /// gates `/video-prompt`/`/video`. A deeper chain simply shows this
  /// screen's "ready" indicator slightly conservatively until the
  /// intermediate hop itself has an image.
  final Map<int, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _refSceneAssetsSubs = {};

  /// Cached documents from each opened `_refSceneAssetsSubs` listener.
  final Map<int, List<AssetDocument>> _refSceneAssets = {};

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

  /// Set once in [load]; reused by [_rebuildState] to open reference-scene
  /// asset listeners on demand.
  late final String _projectPath;

  // ── Local UI-only fields (not derived from JobsCubit) ───────────────────────

  String? _storyboardError;
  String? _videoError;
  int _selectedTabIndex = 0;

  /// True while a manual `storyboard_body` edit is being written to
  /// Firestore (FEAT-015). Local flag rather than a job — the write is a
  /// direct, synchronous Firestore update, not an async worker job.
  bool _isSavingStoryboard = false;

  bool get _isGeneratingStoryboard => jobsCubit.activeJob(
        type: 'video_prompt',
        projectId: projectSlug,
        sceneIndex: sceneNumber,
        assetName: null,
      ) != null;

  bool get _isGeneratingVideo => jobsCubit.activeJob(
        type: 'video',
        projectId: projectSlug,
        sceneIndex: sceneNumber,
        assetName: null,
      ) != null;

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
    _projectPath = projectPath;
    final sceneId = sceneNumber.toString();

    // Re-derive isGenerating* and rebuild on every job-state change — this is
    // what keeps the spinner correct across navigation, independent of
    // whether the completing Firestore write happens to arrive while this
    // screen is open.
    _jobsSub?.cancel();
    _jobsSub = jobsCubit.stream.listen((_) => _rebuildState());

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
          // null to non-null (async /video-prompt job). Resolve the matching
          // job via jobsCubit — same pattern as video below.
          if (prevStoryboard == null && _sceneDoc!.storyboardBody != null) {
            final job = jobsCubit.activeJob(
              type: 'video_prompt',
              projectId: projectSlug,
              sceneIndex: sceneNumber,
              assetName: null,
            );
            if (job != null) jobsCubit.resolve(job.jobId, 'success');
            // Auto-switch to the Storyboard tab so the user sees the result
            // (previously done inline after the synchronous HTTP response).
            _selectedTabIndex = 1;
          }

          // Detect video completion: gcs_video_path transitioned from null
          // to non-null. Resolve the matching job via jobsCubit.
          if (prevVideoPath == null && _sceneDoc!.gcsVideoPath != null) {
            final job = jobsCubit.activeJob(
              type: 'video',
              projectId: projectSlug,
              sceneIndex: sceneNumber,
              assetName: null,
            );
            if (job != null) jobsCubit.resolve(job.jobId, 'success');
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

  /// Merges the three Firestore snapshots with the live [jobsCubit]-derived
  /// generation flags into a [SceneLoaded] state.
  void _rebuildState() {
    if (isClosed) return;

    // Ensure a listener is open for every distinct non-root scene referenced
    // by this scene's pass-through assets, so their gcs_image_path can be
    // resolved below. Safe to call on every rebuild — no-ops once opened.
    for (final asset in _sceneAssets) {
      if (asset.ref == null || asset.description.isNotEmpty) continue;
      final parsed = _parseRefPath(asset.ref!);
      if (parsed != null && parsed.scope != 0) {
        _ensureRefSceneAssetsListener(parsed.scope);
      }
    }

    final resolved = <SceneAsset>[];
    for (final asset in _sceneAssets) {
      final isPassThrough = asset.ref != null && asset.description.isEmpty;
      String? gcsImagePath;

      if (isPassThrough) {
        // Pass-through: resolve against the asset's `ref` (FEAT-013) —
        // scope 0 ("root") assets live in the project-level `assets`
        // collection; any other scope's assets are scene-local only (see
        // asset_writer.write_extracted_assets) and must be looked up in
        // that scene's own `assets` subcollection.
        final parsed = _parseRefPath(asset.ref!);
        if (parsed == null) {
          gcsImagePath = null;
        } else if (parsed.scope == 0) {
          gcsImagePath = _findGlobalAsset(parsed.slug)?.gcsImagePath;
        } else {
          gcsImagePath = _findRefSceneAsset(parsed.scope, parsed.slug)?.gcsImagePath;
        }
      } else {
        gcsImagePath = asset.gcsImagePath;
      }

      resolved.add(SceneAsset(
        id: asset.id,
        name: asset.name,
        type: asset.type,
        description: asset.description,
        ref: asset.ref,
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
      isSavingStoryboard: _isSavingStoryboard,
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
    // This mirrors the server-side gate in
    // app.services.scene_assets.assets_ready_for_storyboard — kept here too
    // purely for instant UX feedback; the backend independently re-validates
    // and resolves the scene text / asset list / art style itself from
    // Firestore, so nothing computed here is sent over the wire.
    if (s.assets.isEmpty || !s.allAssetsHaveImages) {
      _storyboardError = 'All asset images must be generated first.';
      emit(s.copyWith(storyboardError: _storyboardError));
      return;
    }

    _storyboardError = null;
    emit(s.copyWith(
      isGeneratingStoryboard: true,
      storyboardError: null,
    ));

    try {
      final jobId = await apiClient.generateVideoPrompt(
        projectSlug: projectSlug,
        sceneIndex: sceneNumber,
      );

      // Register the job so it survives app restarts and can be polled on
      // foreground return (FEAT-017), and so isGeneratingStoryboard reflects
      // it immediately via jobsCubit regardless of navigation.
      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'video_prompt',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: sceneNumber,
      ));

      // isGeneratingStoryboard stays true — cleared via jobsCubit (and the
      // tab auto-switches) when storyboard_body is set on the scene document.
    } on ApiInsufficientCredits {
      _storyboardError = '__credits__';
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      _storyboardError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: msg,
        ));
      }
    } catch (e) {
      final msg = e.toString();
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

    _videoError = null;
    emit(s.copyWith(
      isGeneratingVideo: true,
      videoError: null,
    ));

    try {
      final jobId = await apiClient.generateVideo(
        projectSlug: projectSlug,
        sceneIndex: sceneNumber,
      );

      // Register the job so it survives app restarts and can be polled on
      // foreground return (FEAT-017).
      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'video',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: sceneNumber,
      ));

      // isGeneratingVideo stays true — cleared via jobsCubit when
      // gcs_video_path is set on the scene document.
    } on ApiInsufficientCredits {
      _videoError = '__credits__';
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      _videoError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: msg,
        ));
      }
    } catch (e) {
      final msg = e.toString();
      _videoError = msg;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: msg,
        ));
      }
    }
  }

  // ── Manual storyboard edit (FEAT-015) ─────────────────────────────────────

  /// Called when the storyboard `TextField` loses focus, mirroring
  /// [AssetEditorCubit.onPromptBodyChanged] — direct Firestore write, no job
  /// queue, since this is a synchronous user edit rather than a generation.
  Future<void> onStoryboardBodyChanged(String body) async {
    final s = state;
    if (s is! SceneLoaded) return;
    _isSavingStoryboard = true;
    emit(s.copyWith(isSavingStoryboard: true));
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance
          .doc('users/$uid/projects/$projectSlug/scenes/$sceneNumber')
          .update({'storyboard_body': body});
    } catch (e) {
      // The Firestore listener will not fire on a failed write; restore flag.
      _isSavingStoryboard = false;
      if (!isClosed && state is SceneLoaded) {
        emit((state as SceneLoaded).copyWith(isSavingStoryboard: false));
      }
      return;
    }
    _isSavingStoryboard = false;
    if (!isClosed && state is SceneLoaded) {
      emit((state as SceneLoaded).copyWith(isSavingStoryboard: false));
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
    // Forward-compat notice that RegExp will become `final` in a future Dart
    // release (implement `Pattern` instead of `RegExp`); constructing one via
    // `RegExp(pattern)` remains the supported API and has no replacement.
    // ignore: deprecated_member_use
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

  /// Returns the global asset whose Firestore document ID matches [slug].
  AssetDocument? _findGlobalAsset(String slug) {
    for (final g in _globalAssets) {
      if (g.id == slug) return g;
    }
    return null;
  }

  /// Parses a `ref` field value (FEAT-013 — e.g. `"assets/hero"` or
  /// `"scenes/2/assets/hero"`) into its source scope (0 = global) and slug.
  /// Returns `null` if [ref] does not match either expected shape.
  static ({int scope, String slug})? _parseRefPath(String ref) {
    // See project_file_service.dart's _invalidNameChars doc comment:
    // constructing RegExp(pattern) remains the supported API despite the
    // class itself being slated `final` in a future release.
    // ignore: deprecated_member_use
    final globalMatch = RegExp(r'^assets/([^/]+)$').firstMatch(ref);
    if (globalMatch != null) {
      return (scope: 0, slug: globalMatch.group(1)!);
    }
    // ignore: deprecated_member_use
    final sceneMatch = RegExp(r'^scenes/(\d+)/assets/([^/]+)$').firstMatch(ref);
    if (sceneMatch != null) {
      return (
        scope: int.parse(sceneMatch.group(1)!),
        slug: sceneMatch.group(2)!,
      );
    }
    return null;
  }

  /// Opens (once) a listener on `scenes/{sceneNumber}/assets` so pass-through
  /// references into that (non-root) scene can be resolved. No-op if a
  /// listener for [sceneNumber] is already open.
  void _ensureRefSceneAssetsListener(int sceneNumber) {
    if (_refSceneAssetsSubs.containsKey(sceneNumber)) return;
    final db = FirebaseFirestore.instance;
    _refSceneAssetsSubs[sceneNumber] = db
        .collection('$_projectPath/scenes/$sceneNumber/assets')
        .snapshots()
        .listen(
      (snap) {
        _refSceneAssets[sceneNumber] =
            snap.docs.map((d) => AssetDocument.fromFirestore(d.id, d.data())).toList();
        _rebuildState();
      },
      onError: (Object e) =>
          emit(SceneError(message: 'Reference scene assets listener error: $e')),
    );
  }

  /// Returns the asset with Firestore document ID [slug] from scene
  /// [sceneNumber]'s cached local assets, or `null` if not yet loaded / not
  /// found.
  AssetDocument? _findRefSceneAsset(int sceneNumber, String slug) {
    final assets = _refSceneAssets[sceneNumber];
    if (assets == null) return null;
    for (final a in assets) {
      if (a.id == slug) return a;
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
    _jobsSub?.cancel();
    for (final sub in _refSceneAssetsSubs.values) {
      sub.cancel();
    }
    return super.close();
  }
}
