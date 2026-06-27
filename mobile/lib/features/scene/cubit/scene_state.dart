import '../../../core/models/models.dart';

/// A single asset as presented on the Scene Detail screen.
class SceneAsset {
  const SceneAsset({
    required this.name,
    required this.dirPath,
    required this.hasImage,
    required this.isGlobal,
    required this.isPassThrough,
    required this.type,
    required this.description,
  });

  /// Display name (from prompt.mdx frontmatter; may start with `@/`).
  final String name;

  /// Absolute path to the asset directory on device.
  final String dirPath;

  /// Whether the *resolved* image file exists (global for pass-through,
  /// local for variant).
  final bool hasImage;

  /// True when this is a global-scope asset.
  final bool isGlobal;

  /// True when this is a scene-local asset with empty description — meaning
  /// it delegates its image to the corresponding global asset.
  final bool isPassThrough;

  final AssetType? type;
  final String description;
}

// ── States ─────────────────────────────────────────────────────────────────────

sealed class SceneState {}

/// Shown while the scene directory is being read from disk.
class SceneLoading extends SceneState {}

/// Full scene detail is available and the screen is interactive.
class SceneLoaded extends SceneState {
  SceneLoaded({
    required this.storyboard,
    required this.assets,
    required this.sceneText,
    required this.hasVideo,
    required this.sceneDirPath,
    required this.sceneNumber,
    this.selectedTabIndex = 0,
    this.isGeneratingStoryboard = false,
    this.isGeneratingVideo = false,
    this.storyboardError,
    this.videoError,
  });

  final SceneStoryboard storyboard;
  final List<SceneAsset> assets;

  /// Raw content of `story.mdx` shown in the "Scene Text" expansion tile.
  final String sceneText;

  final bool hasVideo;
  final String sceneDirPath;
  final int sceneNumber;

  /// 0 = Assets tab, 1 = Storyboard tab.
  final int selectedTabIndex;

  final bool isGeneratingStoryboard;
  final bool isGeneratingVideo;

  /// Non-null when a storyboard error should be surfaced. `'__credits__'` is
  /// a sentinel for the credit-exhaustion dialog.
  final String? storyboardError;

  /// Non-null when a video error should be surfaced. `'__credits__'` is a
  /// sentinel for the credit-exhaustion dialog.
  final String? videoError;

  /// Number of variant assets (non-empty description) that are missing an image.
  List<SceneAsset> get missingVariantAssets =>
      assets.where((a) => !a.isPassThrough && !a.hasImage).toList();

  SceneLoaded copyWith({
    SceneStoryboard? storyboard,
    List<SceneAsset>? assets,
    String? sceneText,
    bool? hasVideo,
    String? sceneDirPath,
    int? sceneNumber,
    int? selectedTabIndex,
    bool? isGeneratingStoryboard,
    bool? isGeneratingVideo,
    Object? storyboardError = _sentinel,
    Object? videoError = _sentinel,
  }) {
    return SceneLoaded(
      storyboard: storyboard ?? this.storyboard,
      assets: assets ?? this.assets,
      sceneText: sceneText ?? this.sceneText,
      hasVideo: hasVideo ?? this.hasVideo,
      sceneDirPath: sceneDirPath ?? this.sceneDirPath,
      sceneNumber: sceneNumber ?? this.sceneNumber,
      selectedTabIndex: selectedTabIndex ?? this.selectedTabIndex,
      isGeneratingStoryboard:
          isGeneratingStoryboard ?? this.isGeneratingStoryboard,
      isGeneratingVideo: isGeneratingVideo ?? this.isGeneratingVideo,
      storyboardError:
          storyboardError == _sentinel ? this.storyboardError : storyboardError as String?,
      videoError:
          videoError == _sentinel ? this.videoError : videoError as String?,
    );
  }

  static const Object _sentinel = Object();
}

/// Shown when the scene directory cannot be read.
class SceneError extends SceneState {
  SceneError({required this.message});
  final String message;
}
