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
    this.isRefining = false,
    this.refineError,
    this.refinedStoryPreview,
    this.refinedStoryGeneratedAt,
    this.showExistingAssetsWarning = false,
    this.showUnreviewedRerunWarning = false,
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

  /// True while the `/refine-story` API call and worker job are running
  /// (FEAT-038). Note: asset extraction (FEAT-009) no longer lives on this
  /// screen — see FileBrowserCubit/FileBrowserState for that flow, which now
  /// occupies the Project File Browser instead.
  final bool isRefining;

  /// Non-null when the last `/refine-story` attempt failed. `'__credits__'`
  /// signals a 402 credit-exhaustion response (shows the paywall dialog
  /// instead of a plain error message).
  final String? refineError;

  /// The project document's `refined_story_preview` field — non-null once a
  /// `/refine-story` job completes and until the user Applies or Discards it
  /// on the Refine Story Preview screen (or Discards directly from the
  /// banner here).
  final String? refinedStoryPreview;

  /// The project document's `refined_story_generated_at` field, paired with
  /// [refinedStoryPreview].
  final DateTime? refinedStoryGeneratedAt;

  /// True when "Refine Story" was tapped and the project already has
  /// extracted assets or generated scenes/videos (R-027) — the screen shows
  /// a warning confirmation dialog before proceeding; calling
  /// `refineStory(force: true)` on confirm bypasses this check.
  final bool showExistingAssetsWarning;

  /// True when "Refine Story" was tapped again while a previous
  /// `refined_story_preview` is still unreviewed — the screen shows a
  /// confirmation before replacing it; calling `refineStory(force: true)`
  /// on confirm bypasses this check.
  final bool showUnreviewedRerunWarning;

  int get sceneCount => scenes.length;

  StoryLoaded copyWith({
    List<StoryScene>? scenes,
    GenerationSettings? generationSettings,
    bool? isSaving,
    bool? savedRecently,
    bool? isRefining,
    String? refineError,
    bool clearRefineError = false,
    String? refinedStoryPreview,
    bool clearRefinedStoryPreview = false,
    DateTime? refinedStoryGeneratedAt,
    bool showExistingAssetsWarning = false,
    bool showUnreviewedRerunWarning = false,
  }) {
    // The two warning flags are one-shot dialog triggers, not persisted
    // state — every copyWith call defaults them back to false unless the
    // caller explicitly sets one true for this exact emission (mirrors how
    // the screen's BlocConsumer listener reacts to a single state change,
    // then the cubit clears it on the very next emit).
    return StoryLoaded(
      scenes: scenes ?? this.scenes,
      generationSettings: generationSettings ?? this.generationSettings,
      isSaving: isSaving ?? this.isSaving,
      savedRecently: savedRecently ?? this.savedRecently,
      isRefining: isRefining ?? this.isRefining,
      refineError: clearRefineError ? null : (refineError ?? this.refineError),
      refinedStoryPreview: clearRefinedStoryPreview
          ? null
          : (refinedStoryPreview ?? this.refinedStoryPreview),
      refinedStoryGeneratedAt:
          clearRefinedStoryPreview ? null : (refinedStoryGeneratedAt ?? this.refinedStoryGeneratedAt),
      showExistingAssetsWarning: showExistingAssetsWarning,
      showUnreviewedRerunWarning: showUnreviewedRerunWarning,
    );
  }

  @override
  List<Object?> get props => [
        scenes,
        generationSettings,
        isSaving,
        savedRecently,
        isRefining,
        refineError,
        refinedStoryPreview,
        refinedStoryGeneratedAt,
        showExistingAssetsWarning,
        showUnreviewedRerunWarning,
      ];
}
