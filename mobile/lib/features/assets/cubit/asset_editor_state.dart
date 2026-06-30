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
    required this.assetId,
    required this.name,
    required this.type,
    required this.description,
    required this.isGlobal,
    this.promptBody,
    this.gcsImagePath,
    this.isSaving = false,
    this.isGeneratingPrompt = false,
    this.isGeneratingImage = false,
    this.promptError,
    this.imageError,
  });

  /// Firestore document ID for this asset (the last path segment).
  final String assetId;

  /// From Firestore `name` field. Read-only — set by the backend on creation.
  final String name;

  /// From Firestore `type` field. User-editable.
  final AssetType type;

  /// From Firestore `description` field. User-editable.
  final String description;

  /// From Firestore `prompt_body` field. Null until generated. User-editable.
  final String? promptBody;

  /// From Firestore `gcs_image_path` field. Set by the image worker on
  /// completion. Null until the worker writes it.
  final String? gcsImagePath;

  /// True for assets directly under `assets/` (global scope).
  /// False for assets under `scenes/{id}/assets/` (scene-local).
  final bool isGlobal;

  /// True while a Firestore field write is in progress.
  final bool isSaving;

  /// True while the `/image-prompt` API call is running.
  final bool isGeneratingPrompt;

  /// True from the moment POST /image returns a job_id until the Firestore
  /// listener fires with a non-null `gcs_image_path`.
  final bool isGeneratingImage;

  /// Inline error from the last `/image-prompt` call.
  /// `'__credits__'` means insufficient credits — show paywall dialog.
  final String? promptError;

  /// Inline error from the last `/image` call.
  /// `'__credits__'` means insufficient credits — show paywall dialog.
  final String? imageError;

  /// A scene-local asset with an empty description uses the global asset's
  /// image and does not need its own prompt or image generated.
  bool get isPassThrough => !isGlobal && description.isEmpty;

  bool get hasImage => gcsImagePath != null;
  bool get hasPromptBody => promptBody != null && promptBody!.isNotEmpty;

  AssetEditorLoaded copyWith({
    String? assetId,
    String? name,
    AssetType? type,
    String? description,
    String? promptBody,
    String? gcsImagePath,
    bool? isGlobal,
    bool? isSaving,
    bool? isGeneratingPrompt,
    bool? isGeneratingImage,
    String? promptError,
    String? imageError,
    bool clearPromptError = false,
    bool clearImageError = false,
    bool clearGcsImagePath = false,
  }) {
    return AssetEditorLoaded(
      assetId: assetId ?? this.assetId,
      name: name ?? this.name,
      type: type ?? this.type,
      description: description ?? this.description,
      promptBody: promptBody ?? this.promptBody,
      gcsImagePath: clearGcsImagePath ? null : (gcsImagePath ?? this.gcsImagePath),
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
        assetId,
        name,
        type,
        description,
        promptBody,
        gcsImagePath,
        isGlobal,
        isSaving,
        isGeneratingPrompt,
        isGeneratingImage,
        promptError,
        imageError,
      ];
}
