// Firestore-backed project tree node types used by FileBrowserCubit and
// FileBrowserState.
//
// These replace the filesystem-based ProjectTree / AssetNode / SceneNode types
// that were defined in core/filesystem/project_file_service.dart.
//
// Separation from models.dart avoids symbol conflicts with the old
// filesystem types that still exist in project_file_service.dart (kept for
// Phase 2 backward compat until all Phase 2 cubits are migrated).

import 'package:ark_mask/core/models/models.dart';

/// The complete Firestore-backed content tree for one project.
///
/// Built by [FileBrowserCubit] by merging the project root Firestore document,
/// the global assets subcollection, and the scenes subcollection (plus each
/// scene's assets subcollection). Consumed by [FileBrowserLoaded].
class ProjectTree {
  const ProjectTree({
    required this.projectSlug,
    required this.displayName,
    required this.storyHasContent,
    required this.globalAssets,
    required this.scenes,
    this.gcsFinalPath,
    this.storyScenesCount = 0,
  });

  /// Immutable project identifier — Firestore doc ID and GCS folder prefix.
  final String projectSlug;

  /// User-facing display name (mutable).
  final String displayName;

  /// True when `story_content` on the project root document is non-empty.
  final bool storyHasContent;

  /// Global assets from `users/{uid}/projects/{slug}/assets` subcollection.
  /// Sorted by type priority: background → character → object.
  final List<AssetNode> globalAssets;

  /// Scenes from `users/{uid}/projects/{slug}/scenes` subcollection, sorted
  /// by `scene_number` ascending.
  final List<SceneNode> scenes;

  /// GCS object path for the merged `final.mp4`. Non-null once a merge job
  /// completes. Used to show the final.mp4 node in the file browser.
  final String? gcsFinalPath;

  /// Number of `# N` scenes currently written in the project's `story_content`
  /// (parsed the same way as StoryCubit — see FileBrowserCubit._countStoryScenes).
  /// 0 when the story is empty. Scene *documents* under `scenes/` may lag
  /// behind this — a story scene only gets a `scenes/{n}` document once
  /// asset extraction touches it or the user manually creates one (FEAT-038).
  final int storyScenesCount;

  /// True when there are no global assets and no scenes yet (blank new project).
  bool get isBlank => globalAssets.isEmpty && scenes.isEmpty;

  /// Story scene numbers (1..[storyScenesCount]) that do not yet have a
  /// corresponding `scenes/{n}` document — candidates for manual scene
  /// creation (FEAT-038). Empty when every story scene already has one, or
  /// the story has no scenes yet.
  List<int> get missingSceneNumbers {
    if (storyScenesCount <= 0) return const [];
    final existing = scenes.map((s) => s.sceneNumber).toSet();
    return [
      for (var n = 1; n <= storyScenesCount; n++)
        if (!existing.contains(n)) n,
    ];
  }
}

/// Represents a single asset document in the Firestore assets subcollection.
///
/// Used to render asset rows in the file browser. Both global and scene-local
/// assets are represented by this type.
class AssetNode {
  const AssetNode({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    required this.hasPromptBody,
    required this.hasImage,
    required this.isGlobal,
    this.sceneNumber,
    this.gcsImagePath,
    this.isGeneratingPrompt = false,
    this.isGeneratingImage = false,
    this.source = 'extracted',
    this.styleAdapted,
    this.originalUploadGcsPath,
  });

  /// Firestore document ID for this asset.
  final String id;

  /// Asset name. No @ prefix = independent local asset.
  /// @ prefix = reference: pass-through if [description] is empty, variant otherwise.
  final String name;

  final AssetType? type;

  /// Creator-written description. Empty for pass-through reference assets.
  final String description;

  /// True when `prompt_body` is non-empty (image prompt has been generated).
  final bool hasPromptBody;

  /// True when `gcs_image_path` is non-null (image has been generated).
  final bool hasImage;

  /// True for assets in the project-level `assets/` subcollection.
  /// False for assets in `scenes/{n}/assets/` subcollections.
  final bool isGlobal;

  /// Scene number for scene-local assets; null for global assets.
  final int? sceneNumber;

  /// GCS object path for the generated image. Non-null when [hasImage] is true.
  final String? gcsImagePath;

  /// True while an `/image-prompt` job for this asset is in progress (from
  /// [JobsCubit]). Drives the prompt dot's [GenerationStepState.running] state.
  final bool isGeneratingPrompt;

  /// True while an `/image` job for this asset is in progress (from
  /// [JobsCubit]). Drives the image dot's [GenerationStepState.running] state.
  final bool isGeneratingImage;

  /// How this asset document was created (FEAT-033–037 / docs/ArkMask/schema.md):
  /// 'extracted' (default, from /assets story extraction), 'manual_image'
  /// (FEAT-034), 'manual_text' (FEAT-035), 'manual_reference' (FEAT-036).
  /// Informational only — shown as a source badge in the Asset Editor and
  /// file browser (FEAT-010). Assumed 'extracted' if absent on legacy docs.
  final String source;

  /// Only meaningful when [source] is 'manual_image'. true = the uploaded
  /// image was used only as a conditioning reference and [gcsImagePath]
  /// holds a newly generated, style-adapted image. false = the uploaded
  /// image was kept as-is. Null for all other source values.
  final bool? styleAdapted;

  /// GCS path of the originally uploaded image, retained for provenance.
  /// Set only when [source] is 'manual_image' and [styleAdapted] is true.
  final String? originalUploadGcsPath;

  /// True for a scene-local pass-through reference (name starts with @,
  /// description is empty). Pass-through assets reuse the referenced global
  /// asset image — they have no independent image or prompt of their own.
  bool get isPassThrough => !isGlobal && name.startsWith('@') && description.isEmpty;
}

/// Represents a single scene document in the Firestore scenes subcollection.
class SceneNode {
  const SceneNode({
    required this.id,
    required this.sceneNumber,
    required this.hasStoryboard,
    required this.hasVideo,
    required this.assets,
    this.gcsVideoPath,
    this.isGeneratingStoryboard = false,
    this.isGeneratingVideo = false,
  });

  /// Firestore document ID for this scene (typically the scene number as a string).
  final String id;

  /// 1-based scene number from the `scene_number` Firestore field.
  final int sceneNumber;

  /// True when `storyboard_body` is non-empty (storyboard has been generated).
  final bool hasStoryboard;

  /// True when `gcs_video_path` is non-null (video has been generated).
  final bool hasVideo;

  /// Scene-local assets from the `scenes/{id}/assets` subcollection.
  final List<AssetNode> assets;

  /// GCS object path for the generated scene video. Non-null when [hasVideo] is true.
  final String? gcsVideoPath;

  /// True while a `/video-prompt` job for this scene is in progress (from
  /// [JobsCubit]). Drives the storyboard dot's running state.
  final bool isGeneratingStoryboard;

  /// True while a `/video` job for this scene is in progress (from
  /// [JobsCubit]). Drives the video dot's running state.
  final bool isGeneratingVideo;
}
