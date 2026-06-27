import 'package:equatable/equatable.dart';

/// A single scene block parsed from `story.mdx`.
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
    this.isSaving = false,
    this.savedRecently = false,
    this.isExtracting = false,
    this.extractError,
  });

  /// Ordered list of scenes parsed from `# N` headings.
  final List<StoryScene> scenes;

  /// True while the debounced auto-save write is in progress.
  final bool isSaving;

  /// Briefly true after a save completes (drives "Saved ✓" indicator).
  final bool savedRecently;

  /// True while the `/assets` API call and directory creation are running.
  final bool isExtracting;

  /// Non-null when the last asset extraction attempt failed.
  final String? extractError;

  int get sceneCount => scenes.length;

  StoryLoaded copyWith({
    List<StoryScene>? scenes,
    bool? isSaving,
    bool? savedRecently,
    bool? isExtracting,
    String? extractError,
    bool clearExtractError = false,
  }) {
    return StoryLoaded(
      scenes: scenes ?? this.scenes,
      isSaving: isSaving ?? this.isSaving,
      savedRecently: savedRecently ?? this.savedRecently,
      isExtracting: isExtracting ?? this.isExtracting,
      extractError: clearExtractError ? null : (extractError ?? this.extractError),
    );
  }

  @override
  List<Object?> get props =>
      [scenes, isSaving, savedRecently, isExtracting, extractError];
}
