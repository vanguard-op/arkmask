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

  /// True when there are no global assets and no scenes yet (blank new project).
  bool get isBlank => globalAssets.isEmpty && scenes.isEmpty;
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
    this.isGenerating = false,
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

  /// True while a generation job for this asset is in progress (from
  /// [JobRegistryService]). Drives the [GenerationStepState.running] dot.
  final bool isGenerating;

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
    this.isGenerating = false,
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

  /// True while a video generation job for this scene is in progress.
  final bool isGenerating;
}
