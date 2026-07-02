import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/job_registry_service.dart';
import '../../../core/models/models.dart';
import 'asset_editor_state.dart';

/// Cubit for the Asset MDX Editor Screen (FEAT-010, FEAT-011, FEAT-012, FEAT-013).
///
/// Manages real-time Firestore state for a single asset document. Field edits
/// are written directly to Firestore; the real-time listener delivers updates
/// back to the UI. Image generation is async — the cubit emits
/// [isGeneratingImage] = true immediately and clears it when the Firestore
/// listener fires with a non-null [gcs_image_path].
class AssetEditorCubit extends Cubit<AssetEditorState> {
  AssetEditorCubit({
    required this.projectSlug,
    required this.assetFirestorePath,
    required this.apiClient,
    required this.jobRegistryService,
  }) : super(const AssetEditorLoading());

  /// Immutable project slug — Firestore document ID and GCS folder prefix.
  final String projectSlug;

  /// Path segment below the project root:
  /// - Global asset  → `"assets/{assetId}"`
  /// - Scene-local   → `"scenes/{sceneId}/assets/{assetId}"`
  final String assetFirestorePath;

  final ArkMaskApiClient apiClient;
  final JobRegistryService jobRegistryService;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;

  /// Tracks the job_id of the most recent in-flight image generation job so
  /// the registry can be updated to 'success' when the Firestore listener
  /// delivers [gcs_image_path].
  String? _currentImageJobId;

  /// Tracks the job_id of the most recent in-flight prompt generation job so
  /// the registry can be updated to 'success' when the Firestore listener
  /// delivers [prompt_body].
  String? _currentPromptJobId;

  // ── Firestore helpers ──────────────────────────────────────────────────────

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Full Firestore path to the asset document.
  String get _docPath => 'users/$_uid/projects/$projectSlug/$assetFirestorePath';

  DocumentReference<Map<String, dynamic>> get _docRef =>
      FirebaseFirestore.instance.doc(_docPath);

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Opens a real-time listener on the Firestore asset document.
  ///
  /// Emits [AssetEditorLoading] immediately, then [AssetEditorLoaded] on each
  /// snapshot update, or [AssetEditorError] if the stream errors.
  void load() {
    emit(const AssetEditorLoading());
    // Derive isGlobal from the path prefix once — it never changes for this
    // asset instance.
    final isGlobal = assetFirestorePath.startsWith('assets/');

    _docSub?.cancel();
    _docSub = _docRef
        .snapshots()
        .listen(
          (snap) => _onSnapshot(snap, isGlobal),
          onError: (Object e) => emit(AssetEditorError(message: e.toString())),
        );
  }

  void _onSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap,
    bool isGlobal,
  ) {
    if (!snap.exists || snap.data() == null) {
      emit(const AssetEditorError(message: 'Asset not found.'));
      return;
    }

    final data = snap.data()!;
    final newGcsImagePath = data['gcs_image_path'] as String?;
    final newPromptBody = data['prompt_body'] as String?;
    final current = state;

    // When an image job is in-flight and the worker has now written
    // gcs_image_path, clear the generating flag and update the job registry.
    bool clearGeneratingImage = false;
    if (current is AssetEditorLoaded &&
        current.isGeneratingImage &&
        newGcsImagePath != null &&
        newGcsImagePath != current.gcsImagePath) {
      clearGeneratingImage = true;
      // Update the registry entry to 'success' now that the image is ready.
      if (_currentImageJobId != null) {
        jobRegistryService.updateStatus(_currentImageJobId!, 'success',
            resolvedAt: DateTime.now());
        _currentImageJobId = null;
      }
    }

    // Same pattern for prompt generation — clear isGeneratingPrompt when the
    // worker writes prompt_body (async /image-prompt job, see
    // AssetEditorCubit.generatePrompt).
    bool clearGeneratingPrompt = false;
    if (current is AssetEditorLoaded &&
        current.isGeneratingPrompt &&
        newPromptBody != null &&
        newPromptBody != current.promptBody) {
      clearGeneratingPrompt = true;
      if (_currentPromptJobId != null) {
        jobRegistryService.updateStatus(_currentPromptJobId!, 'success',
            resolvedAt: DateTime.now());
        _currentPromptJobId = null;
      }
    }

    emit(AssetEditorLoaded(
      assetId: snap.id,
      name: data['name'] as String? ?? snap.id,
      type: AssetType.fromString(data['type'] as String? ?? 'character'),
      description: data['description'] as String? ?? '',
      promptBody: newPromptBody,
      gcsImagePath: newGcsImagePath,
      isGlobal: isGlobal,
      // Preserve transient UI flags from the current state where relevant.
      isSaving: current is AssetEditorLoaded ? current.isSaving : false,
      isGeneratingPrompt: clearGeneratingPrompt
          ? false
          : (current is AssetEditorLoaded ? current.isGeneratingPrompt : false),
      isGeneratingImage: clearGeneratingImage
          ? false
          : (current is AssetEditorLoaded ? current.isGeneratingImage : false),
      // Preserve errors until the user dismisses them.
      promptError:
          current is AssetEditorLoaded ? current.promptError : null,
      imageError: current is AssetEditorLoaded ? current.imageError : null,
    ));
  }

  // ── Field saves ────────────────────────────────────────────────────────────

  /// Called when the asset type selector changes.
  Future<void> onTypeChanged(AssetType type) async {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    emit(s.copyWith(isSaving: true));
    try {
      await _docRef.update({'type': type.value});
    } catch (e) {
      // The Firestore listener will not fire on a failed write; restore flag.
      final current = state;
      if (current is AssetEditorLoaded) emit(current.copyWith(isSaving: false));
    }
  }

  /// Called when the description field loses focus.
  Future<void> onDescriptionChanged(String description) async {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    emit(s.copyWith(isSaving: true));
    try {
      await _docRef.update({'description': description});
    } catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) emit(current.copyWith(isSaving: false));
    }
  }

  /// Called when the prompt body `TextField` loses focus.
  Future<void> onPromptBodyChanged(String body) async {
    final s = state;
    if (s is! AssetEditorLoaded) return;
    emit(s.copyWith(isSaving: true));
    try {
      await _docRef.update({'prompt_body': body});
    } catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) emit(current.copyWith(isSaving: false));
    }
  }

  // ── Generate Image Prompt ─────────────────────────────────────────────────

  /// Calls POST /image-prompt to enqueue an async prompt generation job.
  ///
  /// Registers the job so the app can recover state after a restart. Emits
  /// [isGeneratingPrompt] = true; the flag is cleared when the Firestore
  /// listener fires with a non-null (changed) [prompt_body] — see
  /// [_onSnapshot]. This mirrors [generateImage] below.
  Future<void> generatePrompt() async {
    final s = state;
    if (s is! AssetEditorLoaded || s.description.isEmpty) return;

    emit(s.copyWith(isGeneratingPrompt: true, clearPromptError: true));

    try {
      final jobId = await apiClient.generateImagePrompt(
        projectSlug: projectSlug,
        assetFirestorePath: assetFirestorePath,
        name: s.name,
        type: s.type.value,
        description: s.description,
      );

      await jobRegistryService.register(JobRegistryEntry(
        jobId: jobId,
        type: 'image_prompt',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        assetName: s.name,
      ));

      // Store the job_id so the Firestore listener can mark it 'success' when
      // prompt_body appears.
      _currentPromptJobId = jobId;

      // Leave isGeneratingPrompt = true — the Firestore listener clears it
      // when prompt_body is set by the worker.
    } on ApiInsufficientCredits {
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(
          isGeneratingPrompt: false,
          promptError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(isGeneratingPrompt: false, promptError: msg));
      }
    } catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(
            isGeneratingPrompt: false, promptError: e.toString()));
      }
    }
  }

  void clearPromptError() {
    final s = state;
    if (s is AssetEditorLoaded) emit(s.copyWith(clearPromptError: true));
  }

  // ── Generate Asset Image ──────────────────────────────────────────────────

  /// Calls POST /image to enqueue an async image generation job.
  ///
  /// Resolves a conditioning GCS path for variant assets (name starts with
  /// `@`): reads the referenced asset document once from Firestore to get its
  /// `gcs_image_path`. Emits [isGeneratingImage] = true; the flag is cleared
  /// when the Firestore listener fires with a non-null [gcs_image_path].
  Future<void> generateImage() async {
    final s = state;
    if (s is! AssetEditorLoaded || !s.hasPromptBody) return;
    // Pass-through assets have no independent image; the button is hidden so
    // this guard is a defensive double-check.
    if (s.isPassThrough) return;

    // Resolve conditioning GCS path for variant assets.
    String? conditioningGcsPath;
    if (s.name.startsWith('@')) {
      conditioningGcsPath = await _resolveConditioningGcsPath(s.name);
    }

    emit(s.copyWith(isGeneratingImage: true, clearImageError: true));

    try {
      final jobId = await apiClient.generateImage(
        projectSlug: projectSlug,
        assetFirestorePath: assetFirestorePath,
        conditioningGcsPath: conditioningGcsPath,
      );

      // Register the job so the app can recover state after a restart and
      // show status in the project browser.
      await jobRegistryService.register(JobRegistryEntry(
        jobId: jobId,
        type: 'image',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        assetName: s.name,
      ));

      // Store the job_id so the Firestore listener can mark it 'success' when
      // gcs_image_path appears.
      _currentImageJobId = jobId;

      // Leave isGeneratingImage = true — the Firestore listener clears it
      // when gcs_image_path is set by the worker.
    } on ApiInsufficientCredits {
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(
          isGeneratingImage: false,
          imageError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(isGeneratingImage: false, imageError: msg));
      }
    } catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(
            isGeneratingImage: false, imageError: e.toString()));
      }
    }
  }

  /// Resolves the GCS image path of the referenced asset for variant assets.
  ///
  /// The [name] field uses the format `@/scenes/0/{assetId}` (references a
  /// global asset) or `@/scenes/N/{assetId}` (references a scene-local asset
  /// in scene N). Scene number 0 maps to the global `assets/` collection.
  Future<String?> _resolveConditioningGcsPath(String name) async {
    try {
      // Example: "@/scenes/0/hero" or "@/scenes/2/dragon"
      final parts = name.split('/');
      // Expected: ['@', 'scenes', '<sceneNum>', '<assetId>']
      if (parts.length < 4) return null;
      final sceneNum = int.tryParse(parts[2]);
      final assetId = parts[3];

      final String refSubPath;
      if (sceneNum == null || sceneNum == 0) {
        // Scene 0 → global asset collection
        refSubPath = 'assets/$assetId';
      } else {
        refSubPath = 'scenes/$sceneNum/assets/$assetId';
      }

      final refPath = 'users/$_uid/projects/$projectSlug/$refSubPath';
      final refSnap = await FirebaseFirestore.instance.doc(refPath).get();
      if (!refSnap.exists) return null;
      return refSnap.data()?['gcs_image_path'] as String?;
    } catch (_) {
      // If resolution fails, proceed without conditioning — image is still
      // generated, just without the reference style input.
      return null;
    }
  }

  void clearImageError() {
    final s = state;
    if (s is AssetEditorLoaded) emit(s.copyWith(clearImageError: true));
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    await _docSub?.cancel();
    return super.close();
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Extracts a human-readable message from a sealed [ApiError] subtype.
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

  /// Strips SDK error wrappers like "Error code: 400 - {'error': {'message': '...'}}".
  static String _cleanProviderMessage(String raw) {
    final dashIdx = raw.indexOf(' - ');
    if (dashIdx != -1) {
      final after = raw.substring(dashIdx + 3).trim();
      final match = RegExp(r"""['"]message['"]\s*:\s*['"](.+?)['"]""",
              dotAll: true)
          .firstMatch(after);
      if (match != null) return match.group(1)!;
    }
    return raw;
  }
}
