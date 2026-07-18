import 'package:equatable/equatable.dart';

import '../../../core/models/models.dart';

/// A single scene asset resolved for UI display and generation use.
///
/// Pass-through assets (description.isEmpty) delegate their image to the
/// global asset with the same base name. [gcsImagePath] for a pass-through is
/// already resolved to the referenced global asset's GCS path by [SceneCubit].
class SceneAsset extends Equatable {
  const SceneAsset({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    this.promptBody,
    this.gcsImagePath,
    this.isPassThrough = false,
  });

  /// Firestore document ID.
  final String id;

  /// Raw name from Firestore (may start with `@/scenes/N/` for pass-throughs).
  final String name;

  final AssetType type;
  final String description;

  /// Generated image prompt text. Null until the backend writes it.
  final String? promptBody;

  /// GCS object path for the generated image. For pass-throughs this is the
  /// *referenced* global asset's gcs_image_path. Null until generated.
  final String? gcsImagePath;

  /// True when description.isEmpty — the asset delegates its image to the
  /// global asset with the same base name.
  final bool isPassThrough;

  /// Short display name — strips the `@/scenes/N/` prefix for references.
  String get displayName =>
      name.contains('/') ? name.split('/').last : name;

  @override
  List<Object?> get props => [
        id,
        name,
        type,
        description,
        promptBody,
        gcsImagePath,
        isPassThrough,
      ];
}

// ── States ─────────────────────────────────────────────────────────────────────

sealed class SceneState extends Equatable {}

/// Shown while Firestore listeners are being set up.
class SceneLoading extends SceneState {
  @override
  List<Object?> get props => [];
}

/// Shown when a Firestore listener fails or the user is not authenticated.
class SceneError extends SceneState {
  SceneError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}

/// Full scene detail is available and the screen is interactive.
class SceneLoaded extends SceneState {
  SceneLoaded({
    required this.sceneNumber,
    this.sceneText,
    this.storyboardBody,
    this.gcsVideoPath,
    required this.assets,
    this.isGeneratingStoryboard = false,
    this.isGeneratingVideo = false,
    this.storyboardError,
    this.videoError,
    this.selectedTabIndex = 0,
    this.isSavingStoryboard = false,
  });

  final int sceneNumber;

  /// Raw scene text from the Firestore `scene_text` field.
  final String? sceneText;

  /// Generated storyboard prompt from `storyboard_body`. Null until generated.
  final String? storyboardBody;

  /// GCS path for the generated video. Null until the video worker completes.
  final String? gcsVideoPath;

  /// All scene assets, pass-through GCS paths already resolved. Sorted by type
  /// priority (background → character → object).
  final List<SceneAsset> assets;

  final bool isGeneratingStoryboard;

  /// True from when POST /video is sent until gcs_video_path is set in Firestore.
  final bool isGeneratingVideo;

  /// Non-null when a storyboard error should be surfaced. `'__credits__'` is a
  /// sentinel for the credit-exhaustion dialog.
  final String? storyboardError;

  /// Non-null when a video error should be surfaced. `'__credits__'` is a
  /// sentinel for the credit-exhaustion dialog.
  final String? videoError;

  /// 0 = Assets tab, 1 = Storyboard tab.
  final int selectedTabIndex;

  /// True while a manual edit to `storyboard_body` is being written to
  /// Firestore (FEAT-015 — same manual-edit pattern as an asset's
  /// description/prompt fields). Does not overlap with
  /// [isGeneratingStoryboard], which tracks the async `/video-prompt` job.
  final bool isSavingStoryboard;

  bool get hasStoryboard =>
      storyboardBody != null && storyboardBody!.isNotEmpty;
  bool get hasVideo => gcsVideoPath != null;

  /// True when every asset has a GCS image path — prerequisite for storyboard
  /// generation.
  bool get allAssetsHaveImages =>
      assets.isNotEmpty && assets.every((a) => a.gcsImagePath != null);

  SceneLoaded copyWith({
    int? sceneNumber,
    String? sceneText,
    String? storyboardBody,
    String? gcsVideoPath,
    List<SceneAsset>? assets,
    bool? isGeneratingStoryboard,
    bool? isGeneratingVideo,
    Object? storyboardError = _sentinel,
    Object? videoError = _sentinel,
    int? selectedTabIndex,
    bool? isSavingStoryboard,
  }) {
    return SceneLoaded(
      sceneNumber: sceneNumber ?? this.sceneNumber,
      sceneText: sceneText ?? this.sceneText,
      storyboardBody: storyboardBody ?? this.storyboardBody,
      gcsVideoPath: gcsVideoPath ?? this.gcsVideoPath,
      assets: assets ?? this.assets,
      isGeneratingStoryboard:
          isGeneratingStoryboard ?? this.isGeneratingStoryboard,
      isGeneratingVideo: isGeneratingVideo ?? this.isGeneratingVideo,
      storyboardError: storyboardError == _sentinel
          ? this.storyboardError
          : storyboardError as String?,
      videoError:
          videoError == _sentinel ? this.videoError : videoError as String?,
      selectedTabIndex: selectedTabIndex ?? this.selectedTabIndex,
      isSavingStoryboard: isSavingStoryboard ?? this.isSavingStoryboard,
    );
  }

  static const Object _sentinel = Object();

  @override
  List<Object?> get props => [
        sceneNumber,
        sceneText,
        storyboardBody,
        gcsVideoPath,
        assets,
        isGeneratingStoryboard,
        isGeneratingVideo,
        storyboardError,
        videoError,
        selectedTabIndex,
        isSavingStoryboard,
      ];
}
