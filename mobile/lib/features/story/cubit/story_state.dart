import 'package:equatable/equatable.dart';

import '../../../core/models/models.dart';

/// A single scene block parsed from `story_content` MDX.
class StoryScene extends Equatable {
  const StoryScene({required this.number, required this.body});

  final int number;
  final String body;

  StoryScene copyWith({int? number, String? body}) =>
      StoryScene(number: number ?? this.number, body: body ?? this.body);

  @override
  List<Object?> get props => [number, body];
}

sealed class StoryState extends Equatable {
  const StoryState();

  @override
  List<Object?> get props => [];
}

class StoryLoading extends StoryState {
  const StoryLoading();
}

class StoryError extends StoryState {
  const StoryError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}

class StoryLoaded extends StoryState {
  const StoryLoaded({
    required this.scenes,
    this.generationSettings = const GenerationSettings(),
    this.isSaving = false,
    this.savedRecently = false,
    this.isExtracting = false,
    this.extractError,
    this.hasExistingAssets = false,
  });

  /// Ordered list of scenes parsed from `# N` headings.
  final List<StoryScene> scenes;

  /// Project-level generation settings (art style + subtitle preference).
  /// Read from the Firestore project document and kept in sync with remote updates.
  final GenerationSettings generationSettings;

  /// True while the debounced auto-save Firestore write is in progress.
  final bool isSaving;

  /// Briefly true after a save completes (drives "Saved ✓" indicator).
  final bool savedRecently;

  /// True while the `/assets` API call and Firestore writes are running.
  final bool isExtracting;

  /// Non-null when the last asset extraction attempt failed.
  final String? extractError;

  /// True when Firestore already has asset documents for this project.
  ///
  /// When true the screen shows a confirmation dialog before re-extracting,
  /// so the user must explicitly call `extractAssets(force: true)`.
  final bool hasExistingAssets;

  int get sceneCount => scenes.length;

  StoryLoaded copyWith({
    List<StoryScene>? scenes,
    GenerationSettings? generationSettings,
    bool? isSaving,
    bool? savedRecently,
    bool? isExtracting,
    String? extractError,
    bool clearExtractError = false,
    bool? hasExistingAssets,
  }) {
    return StoryLoaded(
      scenes: scenes ?? this.scenes,
      generationSettings: generationSettings ?? this.generationSettings,
      isSaving: isSaving ?? this.isSaving,
      savedRecently: savedRecently ?? this.savedRecently,
      isExtracting: isExtracting ?? this.isExtracting,
      extractError: clearExtractError ? null : (extractError ?? this.extractError),
      hasExistingAssets: hasExistingAssets ?? this.hasExistingAssets,
    );
  }

  @override
  List<Object?> get props =>
      [scenes, generationSettings, isSaving, savedRecently, isExtracting, extractError, hasExistingAssets];
}
