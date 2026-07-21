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
    this.ref,
    this.promptBody,
    this.gcsImagePath,
    this.isSaving = false,
    this.isGeneratingPrompt = false,
    this.isGeneratingImage = false,
    this.promptError,
    this.imageError,
    this.source = 'extracted',
    this.isDeleting = false,
    this.deleteBlockedBy,
    this.styleAdapted = false,
    this.originalUploadGcsPath,
    this.refChainError,
  });

  /// Firestore document ID for this asset (the last path segment).
  final String assetId;

  /// From Firestore `name` field. Read-only — set by the backend on creation.
  final String name;

  /// From Firestore `type` field. User-editable.
  final AssetType type;

  /// From Firestore `description` field. User-editable.
  final String description;

  /// From Firestore `ref` field (FEAT-013). Non-null means this asset
  /// references another one (`'assets/<slug>'` or
  /// `'scenes/<N>/assets/<slug>'`) — replaces the old
  /// `"@/scenes/N/<name>"` `name`-string convention.
  final String? ref;

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

  /// How this asset document was created — see [AssetNode.source] for the
  /// full contract. Drives the informational source badge (FEAT-010).
  final String source;

  /// True while `DELETE /assets` is in flight (FEAT-037).
  final bool isDeleting;

  /// Names of dependent assets that blocked the last delete attempt
  /// (FEAT-037 — backend returned 409). Null when no delete is blocked.
  final List<String>? deleteBlockedBy;

  /// From Firestore `style_adapted` field (FEAT-034). True when this asset
  /// was created from an uploaded photo with "Adapt to story asset style"
  /// switched on — its image must be generated using
  /// [originalUploadGcsPath] as the conditioning reference so the art style
  /// adaptation actually has the source photo to work from.
  final bool styleAdapted;

  /// From Firestore `original_upload_gcs_path` field (FEAT-034). The GCS
  /// path of the originally uploaded photo for a style-adapted asset. Null
  /// for every other asset source.
  final String? originalUploadGcsPath;

  /// Set when following this asset's own `ref` chain (see
  /// core/models/asset_ref_resolver.dart) hit a cycle or exceeded the max
  /// hop depth — the "not ready" state (FEAT-013). Exact text: "Reference
  /// cycle detected — this asset's reference chain is broken."
  final String? refChainError;

  /// True when [ref] is non-null — this asset references another one,
  /// as opposed to a brand-new, independent asset with its own plain name.
  /// Only reference assets ever show the reference-indicator banner — see
  /// [isPassThrough]/[isVariant].
  bool get isReference => ref != null;

  /// A scene-local reference asset with an empty description uses the
  /// referenced asset's image as-is and does not need its own prompt or
  /// image generated.
  bool get isPassThrough => isReference && description.isEmpty;

  /// A scene-local reference asset whose description is non-empty — the
  /// story calls for a visually-modified copy of the referenced asset (e.g.
  /// a different outfit), so it gets its own generated prompt/image instead
  /// of reusing the referenced asset's. Not to be confused with a brand-new,
  /// non-reference scene-local asset, which also has a non-empty
  /// description but [isReference] is false for it.
  bool get isVariant => isReference && !isPassThrough;

  bool get hasImage => gcsImagePath != null;
  bool get hasPromptBody => promptBody != null && promptBody!.isNotEmpty;

  AssetEditorLoaded copyWith({
    String? assetId,
    String? name,
    AssetType? type,
    String? description,
    String? ref,
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
    String? source,
    bool? isDeleting,
    List<String>? deleteBlockedBy,
    bool clearDeleteBlockedBy = false,
    bool? styleAdapted,
    String? originalUploadGcsPath,
    String? refChainError,
    bool clearRefChainError = false,
  }) {
    return AssetEditorLoaded(
      assetId: assetId ?? this.assetId,
      name: name ?? this.name,
      type: type ?? this.type,
      description: description ?? this.description,
      ref: ref ?? this.ref,
      promptBody: promptBody ?? this.promptBody,
      gcsImagePath: clearGcsImagePath ? null : (gcsImagePath ?? this.gcsImagePath),
      isGlobal: isGlobal ?? this.isGlobal,
      isSaving: isSaving ?? this.isSaving,
      isGeneratingPrompt: isGeneratingPrompt ?? this.isGeneratingPrompt,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      promptError: clearPromptError ? null : (promptError ?? this.promptError),
      imageError: clearImageError ? null : (imageError ?? this.imageError),
      source: source ?? this.source,
      isDeleting: isDeleting ?? this.isDeleting,
      deleteBlockedBy:
          clearDeleteBlockedBy ? null : (deleteBlockedBy ?? this.deleteBlockedBy),
      styleAdapted: styleAdapted ?? this.styleAdapted,
      originalUploadGcsPath: originalUploadGcsPath ?? this.originalUploadGcsPath,
      refChainError:
          clearRefChainError ? null : (refChainError ?? this.refChainError),
    );
  }

  @override
  List<Object?> get props => [
        assetId,
        name,
        type,
        description,
        ref,
        promptBody,
        gcsImagePath,
        isGlobal,
        isSaving,
        isGeneratingPrompt,
        isGeneratingImage,
        promptError,
        imageError,
        source,
        isDeleting,
        deleteBlockedBy,
        styleAdapted,
        originalUploadGcsPath,
        refChainError,
      ];
}
