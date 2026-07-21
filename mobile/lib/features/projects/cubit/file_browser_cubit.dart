import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import '../../../core/models/project_tree.dart';
import 'file_browser_state.dart';

/// Cubit for the Project File Browser Screen (FEAT-005).
///
/// Subscribes to four groups of Firestore real-time listeners and rebuilds
/// the [ProjectTree] whenever any of them fires:
///
/// 1. **Project root doc** — `users/{uid}/projects/{slug}`
///    Provides `display_name`, `story_content`, `gcs_final_path`.
/// 2. **Global assets** — `users/{uid}/projects/{slug}/assets`
///    Provides the list of global asset documents.
/// 3. **Scenes** — `users/{uid}/projects/{slug}/scenes`
///    Provides the list of scene documents (sorted by `scene_number`).
/// 4. **Per-scene assets** — `users/{uid}/projects/{slug}/scenes/{n}/assets`
///    One subscription per scene, added/removed dynamically as scenes are
///    created or deleted.
///
/// A fifth source — [jobsCubit] — is not a Firestore listener but is merged
/// in the same way: every [JobsCubit] state change also triggers [_rebuild],
/// which is what populates each [AssetNode.isGeneratingPrompt] /
/// [AssetNode.isGeneratingImage] / [SceneNode.isGeneratingStoryboard] /
/// [SceneNode.isGeneratingVideo] flag driving the blue "running" dot in the
/// file browser tree. Previously these flags always defaulted to `false` —
/// this cubit never read job state at all, so the dots could only ever show
/// pending (grey) or done (green), never running (blue).
///
/// The cubit merges all sources into a single [ProjectTree] via [_rebuild]
/// and emits [FileBrowserLoaded]. All subscriptions are cancelled in [close].
class FileBrowserCubit extends Cubit<FileBrowserState> {
  FileBrowserCubit({required this.jobsCubit, required this.apiClient})
      : super(const FileBrowserLoading());

  final JobsCubit jobsCubit;

  /// Used for `/assets` extraction (FEAT-009) — as of FEAT-038 this is the
  /// sole entry point for asset extraction in the app (the Story Editor no
  /// longer offers it). Mirrors the pattern StoryCubit used to own.
  final ArkMaskApiClient apiClient;

  // ── Subscriptions ───────────────────────────────────────────────────────────

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _projectSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _globalAssetsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _scenesSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _assetsJobSub;

  /// Per-scene asset subscriptions keyed by scene Firestore doc ID.
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _sceneAssetSubs = {};

  StreamSubscription<JobsState>? _jobsSub;

  // ── Extraction UI state ──────────────────────────────────────────────────
  //
  // Kept as cubit-lifetime fields (not solely derived from `state`) for the
  // same reason as _expandedIds/_selectedId below — _rebuild() re-emits on
  // every Firestore snapshot and must not silently clear an in-flight
  // extraction's UI state.
  String? _extractError;
  bool _hasExistingAssets = false;

  /// True while a project-level `/assets` extraction job is pending/running
  /// — derived live from [jobsCubit] (same pattern StoryCubit used to own),
  /// so returning to this screen mid-extraction restores the indicator
  /// correctly even if the job resolves via FCM/poll while elsewhere.
  bool get _isExtracting => _projectSlug != null &&
      jobsCubit.activeJob(type: 'assets', projectId: _projectSlug!) != null;

  // ── Cached Firestore state ───────────────────────────────────────────────────

  DocumentSnapshot<Map<String, dynamic>>? _projectSnap;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _globalAssets = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _scenes = [];

  /// Scene-local assets keyed by scene Firestore doc ID.
  final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _sceneAssets = {};

  // ── Stored so _syncSceneAssetSubs can re-subscribe ─────────────────────────
  String? _projectSlug;
  String? _uid;

  // ── Tree UI state ────────────────────────────────────────────────────────
  //
  // Deliberately NOT derived from `state` (i.e. not "carried over from the
  // previous FileBrowserLoaded"): `load()` is re-called every time a child
  // screen is popped back to (see project_file_browser_screen.dart onTap
  // handlers), and it immediately emits FileBrowserLoading before the first
  // Firestore snapshot arrives. If expand/select state lived only on the
  // FileBrowserLoaded state, that emit wipes it — every "back" navigation
  // collapsed the whole tree. Keeping these as cubit-lifetime fields means
  // they survive `load()` being called any number of times.
  final Set<String> _expandedIds = {};
  String? _selectedId;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Starts all Firestore listeners for [projectSlug].
  ///
  /// [projectSlug] is the immutable Firestore document ID and GCS folder
  /// prefix. Safe to call multiple times — cancels existing listeners first.
  void load(String projectSlug) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(const FileBrowserError(message: 'Not signed in.'));
      return;
    }

    _cancelAll();
    _projectSlug = projectSlug;
    _uid = uid;
    emit(const FileBrowserLoading());

    // Re-run _rebuild on every job-state change so the running (blue) dot
    // appears the instant a job is enqueued and clears the instant it
    // resolves — independent of which Firestore listener (if any) happens
    // to fire around the same time.
    _jobsSub = jobsCubit.stream.listen((_) => _rebuild());

    final fs = FirebaseFirestore.instance;
    final projectPath = 'users/$uid/projects/$projectSlug';

    // 1. Project root document.
    _projectSub = fs
        .doc(projectPath)
        .snapshots()
        .listen(
          (snap) {
            _projectSnap = snap;
            _rebuild();
          },
          onError: (Object e) =>
              emit(FileBrowserError(message: 'Failed to load project: $e')),
        );

    // 2. Global assets subcollection.
    _globalAssetsSub = fs
        .collection('$projectPath/assets')
        .snapshots()
        .listen(
          (snap) {
            _globalAssets = snap.docs;
            _rebuild();
          },
          onError: (_) {}, // non-fatal — tree renders with empty assets
        );

    // 3. Scenes subcollection.
    _scenesSub = fs
        .collection('$projectPath/scenes')
        .orderBy('scene_number')
        .snapshots()
        .listen(
          (snap) {
            _scenes = snap.docs;
            _syncSceneAssetSubs();
            _rebuild();
          },
          onError: (_) {},
        );
  }

  /// Toggles expand/collapse for a folder node identified by its logical ID.
  void toggleExpand(String nodeId) {
    if (state is! FileBrowserLoaded) return;
    if (!_expandedIds.remove(nodeId)) {
      _expandedIds.add(nodeId);
    }
    emit((state as FileBrowserLoaded).copyWith(expandedIds: Set.of(_expandedIds)));
  }

  /// Marks a node as selected (highlighted in the file browser).
  void select(String nodeId) {
    if (state is! FileBrowserLoaded) return;
    _selectedId = nodeId;
    emit((state as FileBrowserLoaded).copyWith(selectedId: nodeId));
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Dynamically adjusts per-scene asset subscriptions when the scenes
  /// snapshot changes. New scenes get a subscription; removed scenes have
  /// theirs cancelled.
  void _syncSceneAssetSubs() {
    final uid = _uid;
    final slug = _projectSlug;
    if (uid == null || slug == null) return;

    final currentIds = _scenes.map((d) => d.id).toSet();
    final trackedIds = _sceneAssetSubs.keys.toSet();

    // Cancel subs for scenes that no longer exist.
    for (final id in trackedIds.difference(currentIds)) {
      _sceneAssetSubs.remove(id)?.cancel();
      _sceneAssets.remove(id);
    }

    // Add subs for newly appearing scenes.
    final fs = FirebaseFirestore.instance;
    for (final id in currentIds.difference(trackedIds)) {
      _sceneAssetSubs[id] = fs
          .collection('users/$uid/projects/$slug/scenes/$id/assets')
          .snapshots()
          .listen(
            (snap) {
              _sceneAssets[id] = snap.docs;
              _rebuild();
            },
            onError: (_) {},
          );
    }
  }

  /// Merges all cached Firestore state into a [ProjectTree] and emits
  /// [FileBrowserLoaded]. Preserves expand/select state across rebuilds.
  void _rebuild() {
    final snap = _projectSnap;
    if (snap == null || !snap.exists) return;
    final data = snap.data();
    if (data == null) return;

    // Build global asset nodes, sorted: background → character → object.
    final globalAssetNodes = _globalAssets.map((doc) {
      final d = doc.data();
      return AssetNode(
        id: doc.id,
        name: d['name'] as String? ?? doc.id,
        type: AssetType.fromString(d['type'] as String? ?? 'character'),
        description: d['description'] as String? ?? '',
        hasPromptBody: (d['prompt_body'] as String?)?.isNotEmpty ?? false,
        hasImage: d['gcs_image_path'] != null,
        isGlobal: true,
        gcsImagePath: d['gcs_image_path'] as String?,
        isGeneratingPrompt: _isAssetJobActive(
          type: 'image_prompt',
          sceneIndex: null,
          assetName: d['name'] as String? ?? doc.id,
        ),
        isGeneratingImage: _isAssetJobActive(
          type: 'image',
          sceneIndex: null,
          assetName: d['name'] as String? ?? doc.id,
        ),
        ref: d['ref'] as String?,
        source: d['source'] as String? ?? 'extracted',
        styleAdapted: d['style_adapted'] as bool?,
        originalUploadGcsPath: d['original_upload_gcs_path'] as String?,
      );
    }).toList()
      ..sort((a, b) => _assetTypeSortOrder(a.type) - _assetTypeSortOrder(b.type));

    // Build scene nodes.
    final sceneNodes = _scenes.map((sceneDoc) {
      final sd = sceneDoc.data();
      final sceneAssetDocs = _sceneAssets[sceneDoc.id] ?? [];

      final sceneNumber = sd['scene_number'] as int?;

      final sceneAssetNodes = sceneAssetDocs.map((assetDoc) {
        final ad = assetDoc.data();
        final assetName = ad['name'] as String? ?? assetDoc.id;
        return AssetNode(
          id: assetDoc.id,
          name: assetName,
          type: AssetType.fromString(ad['type'] as String? ?? 'character'),
          description: ad['description'] as String? ?? '',
          hasPromptBody: (ad['prompt_body'] as String?)?.isNotEmpty ?? false,
          hasImage: ad['gcs_image_path'] != null,
          isGlobal: false,
          sceneNumber: sceneNumber,
          gcsImagePath: ad['gcs_image_path'] as String?,
          isGeneratingPrompt: _isAssetJobActive(
            type: 'image_prompt',
            sceneIndex: sceneNumber,
            assetName: assetName,
          ),
          isGeneratingImage: _isAssetJobActive(
            type: 'image',
            sceneIndex: sceneNumber,
            assetName: assetName,
          ),
          ref: ad['ref'] as String?,
          source: ad['source'] as String? ?? 'extracted',
          styleAdapted: ad['style_adapted'] as bool?,
          originalUploadGcsPath: ad['original_upload_gcs_path'] as String?,
        );
      }).toList()
        ..sort((a, b) => _assetTypeSortOrder(a.type) - _assetTypeSortOrder(b.type));

      final resolvedSceneNumber =
          sceneNumber ?? int.tryParse(sceneDoc.id) ?? 1;

      return SceneNode(
        id: sceneDoc.id,
        sceneNumber: resolvedSceneNumber,
        hasStoryboard: (sd['storyboard_body'] as String?)?.isNotEmpty ?? false,
        hasVideo: sd['gcs_video_path'] != null,
        gcsVideoPath: sd['gcs_video_path'] as String?,
        assets: sceneAssetNodes,
        isGeneratingStoryboard: _isSceneJobActive(
          type: 'video_prompt',
          sceneIndex: resolvedSceneNumber,
        ),
        isGeneratingVideo: _isSceneJobActive(
          type: 'video',
          sceneIndex: resolvedSceneNumber,
        ),
      );
    }).toList();

    final tree = ProjectTree(
      projectSlug: _projectSlug!,
      displayName: data['display_name'] as String? ?? _projectSlug!,
      storyHasContent:
          (data['story_content'] as String?)?.trim().isNotEmpty ?? false,
      globalAssets: globalAssetNodes,
      scenes: sceneNodes,
      gcsFinalPath: data['gcs_final_path'] as String?,
      storyScenesCount: _countStoryScenes(data['story_content'] as String? ?? ''),
    );

    // Read from the cubit-lifetime fields (not `state`) so expand/select
    // survives `load()` being re-invoked — see the field doc comments above.
    emit(FileBrowserLoaded(
      tree: tree,
      expandedIds: Set.of(_expandedIds),
      selectedId: _selectedId,
      isExtracting: _isExtracting,
      extractError: _extractError,
      hasExistingAssets: _hasExistingAssets,
    ));
  }

  // ── Asset extraction (FEAT-009, sole entry point as of FEAT-038) ────────

  /// Enqueues `/assets` extraction (async job) and tracks completion via the
  /// job document's status field — mirrors StoryCubit.extractAssets, which
  /// used to own this before the Extract Assets action moved here.
  ///
  /// Pass [force] = true to skip the existing-assets guard (the screen shows
  /// a confirmation dialog when `state.hasExistingAssets == true` and calls
  /// this method with `force: true` on user confirmation).
  Future<void> extractAssets({bool force = false}) async {
    final current = state;
    if (current is! FileBrowserLoaded) return;
    final slug = _projectSlug;
    final uid = _uid;
    if (slug == null || uid == null) return;

    if (!current.tree.storyHasContent) {
      emit(current.copyWith(
          extractError: 'Write at least one scene before extracting assets.'));
      return;
    }

    if (!force) {
      final existing = await FirebaseFirestore.instance
          .collection('users/$uid/projects/$slug/assets')
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) {
        _hasExistingAssets = true;
        emit(current.copyWith(hasExistingAssets: true));
        return;
      }
    }

    _extractError = null;
    _hasExistingAssets = false;
    emit(current.copyWith(
      isExtracting: true,
      clearExtractError: true,
      hasExistingAssets: false,
    ));

    try {
      final storyContent = _projectSnap?.data()?['story_content'] as String? ?? '';
      final jobId = await apiClient.extractAssets(
        projectSlug: slug,
        storyContent: storyContent,
      );

      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'assets',
        projectId: slug,
        status: 'pending',
        createdAt: DateTime.now(),
      ));

      _listenForAssetsJobCompletion(jobId);
      // isExtracting is derived live from jobsCubit — no explicit clear
      // needed here; _rebuild()/the jobsCubit stream listener below both
      // re-emit once the job resolves.
    } on ApiInsufficientCredits {
      _extractError = '__credits__';
      _rebuild();
    } on ApiError catch (e) {
      _extractError = _apiErrorMessage(e);
      _rebuild();
    } catch (e) {
      _extractError = e.toString();
      _rebuild();
    }
  }

  /// Listens to the job document for [jobId] until it reaches a terminal
  /// state (success/failed), then resolves it in the job registry and
  /// surfaces any failure message. There's no single Firestore field to
  /// watch for this job type (extraction creates multiple new documents) —
  /// see StoryCubit's identical rationale before this moved here.
  void _listenForAssetsJobCompletion(String jobId) {
    final uid = _uid;
    if (uid == null) return;
    _assetsJobSub?.cancel();
    _assetsJobSub = FirebaseFirestore.instance
        .doc('users/$uid/jobs/$jobId')
        .snapshots()
        .listen((snap) {
      final jobStatus = snap.data()?['status'] as String?;
      if (jobStatus != 'success' && jobStatus != 'failed') return;

      _assetsJobSub?.cancel();
      _assetsJobSub = null;

      jobsCubit.resolve(jobId, jobStatus!);

      if (jobStatus == 'failed') {
        _extractError =
            snap.data()?['error_message'] as String? ?? 'Asset extraction failed.';
      }
      _rebuild();
    });
  }

  void clearExtractError() {
    if (state is! FileBrowserLoaded) return;
    _extractError = null;
    _rebuild();
  }

  static String _apiErrorMessage(ApiError e) => switch (e) {
        ApiConflict(:final message) => message,
        ApiValidationError(:final detail) => detail,
        ApiServerError(:final message) => message,
        ApiNetworkError(:final message) => message,
        ApiUnknownError(:final message) => message,
        ApiInsufficientCredits() => 'Insufficient credits',
        ApiUnauthorized() => 'Unauthorized',
      };

  /// True when a job of [type] is pending/running for the given routing
  /// context — mirrors the matching scheme used by AssetEditorCubit /
  /// SceneCubit so the file browser's dots agree with the editor screens'
  /// spinners for the same asset/scene.
  bool _isAssetJobActive({
    required String type,
    required int? sceneIndex,
    required String assetName,
  }) {
    final slug = _projectSlug;
    if (slug == null) return false;
    return jobsCubit.activeJob(
          type: type,
          projectId: slug,
          sceneIndex: sceneIndex,
          assetName: assetName,
        ) !=
        null;
  }

  bool _isSceneJobActive({required String type, required int sceneIndex}) {
    final slug = _projectSlug;
    if (slug == null) return false;
    return jobsCubit.activeJob(
          type: type,
          projectId: slug,
          sceneIndex: sceneIndex,
          assetName: null,
        ) !=
        null;
  }

  /// Counts `# N` scene headings in raw `story_content` MDX — mirrors
  /// StoryCubit._parseScenes' heading detection (kept independent rather
  /// than shared code since this cubit only needs the count, not full scene
  /// bodies). No headings but non-empty content means the whole thing is an
  /// unheaded scene 1, matching StoryCubit's fallback. Used to compute
  /// [ProjectTree.missingSceneNumbers] for manual scene creation (FEAT-038).
  static int _countStoryScenes(String raw) {
    if (raw.trim().isEmpty) return 0;
    // ignore: deprecated_member_use
    final headingPattern = RegExp(r'^# (\d+)\s*$', multiLine: true);
    final matches = headingPattern.allMatches(raw).toList();
    if (matches.isEmpty) return 1;
    // Story scenes are always sequentially re-indexed 1..N on save (see
    // StoryCubit._reindex), so the highest heading number found is the count.
    var maxNumber = 0;
    for (final m in matches) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > maxNumber) maxNumber = n;
    }
    return maxNumber;
  }

  /// Sort priority for asset types in the file browser.
  /// background (0) → character (1) → object (2) → unknown (3).
  int _assetTypeSortOrder(AssetType? type) => switch (type) {
        AssetType.background => 0,
        AssetType.character => 1,
        AssetType.object => 2,
        null => 3,
      };

  void _cancelAll() {
    _projectSub?.cancel();
    _globalAssetsSub?.cancel();
    _scenesSub?.cancel();
    _jobsSub?.cancel();
    _assetsJobSub?.cancel();
    for (final sub in _sceneAssetSubs.values) {
      sub.cancel();
    }
    _sceneAssetSubs.clear();
    _sceneAssets.clear();
    _globalAssets = [];
    _scenes = [];
    _projectSnap = null;
  }

  @override
  Future<void> close() async {
    _cancelAll();
    return super.close();
  }
}
