import 'package:equatable/equatable.dart';

import '../../../core/models/models.dart';

sealed class AssetEditorState extends Equatable {
  const AssetEditorState();

  @override
  List<Object?> get props => [];
}

class AssetEditorLoading extends AssetEditorState {
  const AssetEditorLoading();
}

class AssetEditorError extends AssetEditorState {
  const AssetEditorError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}

class AssetEditorLoaded extends AssetEditorState {
  const AssetEditorLoaded({
    required this.prompt,
    required this.hasImage,
    required this.isGlobal,
    this.isSaving = false,
    this.isGeneratingPrompt = false,
    this.isGeneratingImage = false,
    this.promptError,
    this.imageError,
  });

  /// Parsed data from `prompt.mdx` (frontmatter + body).
  final AssetPrompt prompt;

  /// Whether `image.png` exists in the asset directory.
  final bool hasImage;

  /// True for assets directly under `assets/` (global scope).
  /// False for assets under `scenes/N/assets/` (scene-local).
  final bool isGlobal;

  /// True while a file save is in progress.
  final bool isSaving;

  /// True while the `/image-prompt` API call is running.
  final bool isGeneratingPrompt;

  /// True while the `/image` API call + GCS download are running.
  final bool isGeneratingImage;

  /// Inline error from the last `/image-prompt` call.
  final String? promptError;

  /// Inline error from the last `/image` call.
  final String? imageError;

  /// A scene-local asset with an empty description uses the global image
  /// and does not need its own prompt or image generated.
  bool get isPassThrough => !isGlobal && prompt.description.isEmpty;

  AssetEditorLoaded copyWith({
    AssetPrompt? prompt,
    bool? hasImage,
    bool? isGlobal,
    bool? isSaving,
    bool? isGeneratingPrompt,
    bool? isGeneratingImage,
    String? promptError,
    String? imageError,
    bool clearPromptError = false,
    bool clearImageError = false,
  }) {
    return AssetEditorLoaded(
      prompt: prompt ?? this.prompt,
      hasImage: hasImage ?? this.hasImage,
      isGlobal: isGlobal ?? this.isGlobal,
      isSaving: isSaving ?? this.isSaving,
      isGeneratingPrompt: isGeneratingPrompt ?? this.isGeneratingPrompt,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      promptError: clearPromptError ? null : (promptError ?? this.promptError),
      imageError: clearImageError ? null : (imageError ?? this.imageError),
    );
  }

  @override
  List<Object?> get props => [
        prompt,
        hasImage,
        isGlobal,
        isSaving,
        isGeneratingPrompt,
        isGeneratingImage,
        promptError,
        imageError,
      ];
}
