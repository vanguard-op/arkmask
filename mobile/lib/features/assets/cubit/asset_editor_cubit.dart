import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/filesystem/project_file_service.dart';
import '../../../core/jobs/generation_job_manager.dart';
import '../../../core/models/models.dart';
import 'asset_editor_state.dart';

/// Cubit for the Asset MDX Editor Screen (FEAT-010, FEAT-011, FEAT-012, FEAT-013).
///
/// Owns the read/write lifecycle for a single `prompt.mdx` file.
/// Generation calls update the [GenerationJobManager] for cross-screen
/// status visibility (FEAT-017).
///
/// [conditioningDirPath] is the directory of the referenced (global or prior-
/// scene) asset whose `image.png` is sent as a visual conditioning input when
/// generating an image for a variant asset. Null for global and local assets.
class AssetEditorCubit extends Cubit<AssetEditorState> {
  AssetEditorCubit({
    required this.assetDirPath,
    required this.fileService,
    required this.apiClient,
    required this.jobManager,
    this.conditioningDirPath,
  }) : super(const AssetEditorLoading());

  final String assetDirPath;

  /// Path to the referenced asset directory used as a conditioning image source
  /// for variant generation. Null when not a variant.
  final String? conditioningDirPath;

  final ProjectFileService fileService;
  final ArkMaskApiClient apiClient;
  final GenerationJobManager jobManager;

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Determines whether this asset is global or scene-local, then reads
  /// `prompt.mdx` and checks for `image.png`.
  Future<void> load() async {
    emit(const AssetEditorLoading());
    try {
      final prompt = await fileService.readAssetPrompt(assetDirPath);
      final hasImage = await fileService.imageFileForAsset(assetDirPath).exists();
      // A path containing 'scenes' means it's a scene-local asset.
      final isGlobal = !assetDirPath.contains('${p.separator}scenes${p.separator}');
      emit(AssetEditorLoaded(
        prompt: prompt,
        hasImage: hasImage,
        isGlobal: isGlobal,
      ));
    } catch (e) {
      emit(AssetEditorError(message: e.toString()));
    }
  }

  // ── Frontmatter edits ─────────────────────────────────────────────────────

  /// Called when the asset type selector changes.
  void onTypeChanged(AssetType type) {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    final updated = s.copyWith(prompt: s.prompt.copyWith(type: type));
    emit(updated);
    _save(updated.prompt);
  }

  /// Called when the description field blurs.
  void onDescriptionChanged(String description) {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    final updated = s.copyWith(prompt: s.prompt.copyWith(description: description));
    emit(updated);
    _save(updated.prompt);
  }

  /// Called when the prompt body `TextField` blurs.
  void onPromptBodyChanged(String body) {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    final updated = s.copyWith(prompt: s.prompt.copyWith(promptBody: body));
    emit(updated);
    _save(updated.prompt);
  }

  Future<void> _save(AssetPrompt prompt) async {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    emit(s.copyWith(isSaving: true));
    try {
      await fileService.writeAssetPrompt(assetDirPath, prompt);
    } finally {
      final current = state;
      if (current is AssetEditorLoaded) emit(current.copyWith(isSaving: false));
    }
  }

  // ── Generate Image Prompt ─────────────────────────────────────────────────

  /// Calls `/image-prompt` with the asset's name, type, and description.
  /// Writes the response to the prompt body of `prompt.mdx`.
  Future<void> generatePrompt() async {
    final s = state;
    if (s is! AssetEditorLoaded) return;

    final key = GenerationJobManager.promptKey(assetDirPath);
    jobManager.markRunning(key);
    emit(s.copyWith(
      isGeneratingPrompt: true,
      clearPromptError: true,
    ));

    try {
      final promptText = await apiClient.generateImagePrompt(
        name: s.prompt.name,
        type: s.prompt.type.value,
        description: s.prompt.description,
      );

      final updatedPrompt = s.prompt.copyWith(promptBody: promptText);
      await fileService.writeAssetPrompt(assetDirPath, updatedPrompt);
      jobManager.markDone(key);
      emit((state as AssetEditorLoaded).copyWith(
        prompt: updatedPrompt,
        isGeneratingPrompt: false,
      ));
    } on ApiInsufficientCredits {
      jobManager.markFailed(key, 'Insufficient credits');
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingPrompt: false,
        promptError: '__credits__',
      ));
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      jobManager.markFailed(key, msg);
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingPrompt: false,
        promptError: msg,
      ));
    } catch (e) {
      jobManager.markFailed(key, e.toString());
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingPrompt: false,
        promptError: e.toString(),
      ));
    }
  }

  void clearPromptError() {
    final s = state;
    if (s is AssetEditorLoaded) emit(s.copyWith(clearPromptError: true));
  }

  // ── Generate Asset Image ──────────────────────────────────────────────────

  /// Calls `/image` with the prompt body, downloads from the GCS presigned URL,
  /// and saves `image.png` into the asset directory.
  Future<void> generateImage() async {
    final s = state;
    if (s is! AssetEditorLoaded || s.prompt.promptBody.isEmpty) return;

    final key = GenerationJobManager.imageKey(assetDirPath);
    jobManager.markRunning(key);
    emit(s.copyWith(
      isGeneratingImage: true,
      clearImageError: true,
    ));

    try {
      // For variant assets, load the conditioning image bytes from the
      // referenced asset directory and attach them as visual reference inputs.
      final refImageBytes = <List<int>>[];
      if (conditioningDirPath != null) {
        final condFile = File(p.join(conditioningDirPath!, 'image.png'));
        if (await condFile.exists()) {
          refImageBytes.add(await condFile.readAsBytes());
        }
      }

      final gcsUrl = await apiClient.generateImage(
        promptBody: s.prompt.promptBody,
        refImageBytes: refImageBytes,
      );
      final bytes = await apiClient.downloadBytes(gcsUrl);
      await fileService.saveImageToAssetDir(assetDirPath, bytes);
      jobManager.markDone(key);
      final current = state as AssetEditorLoaded;
      emit(current.copyWith(
        hasImage: true,
        isGeneratingImage: false,
        // Bump imageVersion so Image.file gets a new key and bypasses the
        // Flutter file-image cache, showing the freshly written image.
        imageVersion: current.imageVersion + 1,
      ));
    } on ApiInsufficientCredits {
      jobManager.markFailed(key, 'Insufficient credits');
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingImage: false,
        imageError: '__credits__',
      ));
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      jobManager.markFailed(key, msg);
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingImage: false,
        imageError: msg,
      ));
    } catch (e) {
      jobManager.markFailed(key, e.toString());
      emit((state as AssetEditorLoaded).copyWith(
        isGeneratingImage: false,
        imageError: e.toString(),
      ));
    }
  }

  void clearImageError() {
    final s = state;
    if (s is AssetEditorLoaded) emit(s.copyWith(clearImageError: true));
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Extracts a human-readable message from a sealed [ApiError] subtype.
  ///
  /// Strips any residual SDK wrapper text (e.g. "Error code: 400 - {...}")
  /// so only the clean provider message is shown to the user.
  static String _apiErrorMessage(ApiError e) {
    final raw = switch (e) {
      ApiConflict(:final message) => message,
      ApiValidationError(:final detail) => detail,
      ApiServerError(:final message) => message,
      ApiNetworkError(:final message) => message,
      ApiUnknownError(:final message) => message,
      ApiInsufficientCredits() => 'Insufficient credits',
      ApiUnauthorized() => 'Unauthorized',
    };
    return _cleanProviderMessage(raw);
  }

  /// Strips SDK error wrappers like "Error code: 400 - {'error': {'message': '...'}}"
  /// returning just the inner message string.
  static String _cleanProviderMessage(String raw) {
    // If the string looks like "Error code: NNN - ..." try to pull out just
    // the inner "message" value so JSON/dict braces never reach the UI.
    final dashIdx = raw.indexOf(' - ');
    if (dashIdx != -1) {
      final after = raw.substring(dashIdx + 3).trim();
      // Simple regex extract of "message": "..." or 'message': '...'
      final match = RegExp(r"""['"]message['"]\s*:\s*['"](.+?)['"]""", dotAll: true)
          .firstMatch(after);
      if (match != null) return match.group(1)!;
    }
    return raw;
  }
}
