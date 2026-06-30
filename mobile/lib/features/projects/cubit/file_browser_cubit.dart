import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
/// The cubit merges all four into a single [ProjectTree] via [_rebuild] and
/// emits [FileBrowserLoaded]. All subscriptions are cancelled in [close].
class FileBrowserCubit extends Cubit<FileBrowserState> {
  FileBrowserCubit() : super(const FileBrowserLoading());

  // ── Subscriptions ───────────────────────────────────────────────────────────

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _projectSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _globalAssetsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _scenesSub;

  /// Per-scene asset subscriptions keyed by scene Firestore doc ID.
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _sceneAssetSubs = {};

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
    final s = state as FileBrowserLoaded;
    final updated = Set<String>.from(s.expandedIds);
    if (!updated.remove(nodeId)) {
      updated.add(nodeId);
    }
    emit(s.copyWith(expandedIds: updated));
  }

  /// Marks a node as selected (highlighted in the file browser).
  void select(String nodeId) {
    if (state is! FileBrowserLoaded) return;
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
      );
    }).toList()
      ..sort((a, b) => _assetTypeSortOrder(a.type) - _assetTypeSortOrder(b.type));

    // Build scene nodes.
    final sceneNodes = _scenes.map((sceneDoc) {
      final sd = sceneDoc.data();
      final sceneAssetDocs = _sceneAssets[sceneDoc.id] ?? [];

      final sceneAssetNodes = sceneAssetDocs.map((assetDoc) {
        final ad = assetDoc.data();
        return AssetNode(
          id: assetDoc.id,
          name: ad['name'] as String? ?? assetDoc.id,
          type: AssetType.fromString(ad['type'] as String? ?? 'character'),
          description: ad['description'] as String? ?? '',
          hasPromptBody: (ad['prompt_body'] as String?)?.isNotEmpty ?? false,
          hasImage: ad['gcs_image_path'] != null,
          isGlobal: false,
          sceneNumber: sd['scene_number'] as int?,
          gcsImagePath: ad['gcs_image_path'] as String?,
        );
      }).toList()
        ..sort((a, b) => _assetTypeSortOrder(a.type) - _assetTypeSortOrder(b.type));

      return SceneNode(
        id: sceneDoc.id,
        sceneNumber: sd['scene_number'] as int? ?? int.tryParse(sceneDoc.id) ?? 1,
        hasStoryboard: (sd['storyboard_body'] as String?)?.isNotEmpty ?? false,
        hasVideo: sd['gcs_video_path'] != null,
        gcsVideoPath: sd['gcs_video_path'] as String?,
        assets: sceneAssetNodes,
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
    );

    final current = state;
    emit(FileBrowserLoaded(
      tree: tree,
      expandedIds:
          current is FileBrowserLoaded ? current.expandedIds : const {},
      selectedId: current is FileBrowserLoaded ? current.selectedId : null,
    ));
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
