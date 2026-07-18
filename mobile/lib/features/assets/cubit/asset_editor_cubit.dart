import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import 'asset_editor_state.dart';

/// Cubit for the Asset MDX Editor Screen (FEAT-010, FEAT-011, FEAT-012, FEAT-013).
///
/// Manages real-time Firestore state for a single asset document. Field edits
/// are written directly to Firestore; the real-time listener delivers updates
/// back to the UI.
///
/// Generation is async — [isGeneratingPrompt] / [isGeneratingImage] are no
/// longer local booleans owned by this Cubit's lifetime. They are derived
/// live from [JobsCubit], the app-lifetime job orchestrator, via
/// [_syncGeneratingFlags]. This means:
///  - Re-opening this screen mid-generation correctly shows the spinner
///    again (checked on [load] once the asset name is known).
///  - The flag clears the instant the job resolves, even if it resolves via
///    FCM / poll while a *different* screen is on top.
/// The Firestore listener is still used as a fast, low-latency completion
/// signal while this screen happens to be open — it now calls
/// [JobsCubit.resolve] instead of writing to the registry directly.
class AssetEditorCubit extends Cubit<AssetEditorState> {
  AssetEditorCubit({
    required this.projectSlug,
    required this.assetFirestorePath,
    required this.apiClient,
    required this.jobsCubit,
  }) : super(const AssetEditorLoading());

  /// Immutable project slug — Firestore document ID and GCS folder prefix.
  final String projectSlug;

  /// Path segment below the project root:
  /// - Global asset  → `"assets/{assetId}"`
  /// - Scene-local   → `"scenes/{sceneId}/assets/{assetId}"`
  final String assetFirestorePath;

  final ArkMaskApiClient apiClient;
  final JobsCubit jobsCubit;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<JobsState>? _jobsSub;

  /// Scene index this asset belongs to, or null for a global asset. Derived
  /// once from [assetFirestorePath] — used to match this screen's jobs in
  /// the registry (mirrors the FCM payload's routing fields).
  late final int? _sceneIndex = _deriveSceneIndex(assetFirestorePath);

  // ── Firestore helpers ──────────────────────────────────────────────────────

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Full Firestore path to the asset document.
  String get _docPath => 'users/$_uid/projects/$projectSlug/$assetFirestorePath';

  DocumentReference<Map<String, dynamic>> get _docRef =>
      FirebaseFirestore.instance.doc(_docPath);

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Opens a real-time listener on the Firestore asset document and
  /// subscribes to [jobsCubit] so the generation flags stay live regardless
  /// of navigation.
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

    // Re-sync the generating flags on every job-state change — this is what
    // makes the spinner clear even when a job resolves while this screen
    // isn't the one that receives the Firestore update (or resolves purely
    // via FCM/poll before Firestore's own listener fires).
    _jobsSub?.cancel();
    _jobsSub = jobsCubit.stream.listen((_) => _syncGeneratingFlags());
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
    final name = data['name'] as String? ?? snap.id;
    final current = state;

    // When the worker has written gcs_image_path / prompt_body, resolve the
    // matching job immediately (fast path — FCM/poll would eventually catch
    // this too, but Firestore is typically faster while this screen is open).
    if (current is AssetEditorLoaded &&
        newGcsImagePath != null &&
        newGcsImagePath != current.gcsImagePath) {
      final job = jobsCubit.activeJob(
        type: 'image',
        projectId: projectSlug,
        sceneIndex: _sceneIndex,
        assetName: name,
      );
      if (job != null) jobsCubit.resolve(job.jobId, 'success');
    }
    if (current is AssetEditorLoaded &&
        newPromptBody != null &&
        newPromptBody != current.promptBody) {
      final job = jobsCubit.activeJob(
        type: 'image_prompt',
        projectId: projectSlug,
        sceneIndex: _sceneIndex,
        assetName: name,
      );
      if (job != null) jobsCubit.resolve(job.jobId, 'success');
    }

    emit(AssetEditorLoaded(
      assetId: snap.id,
      name: name,
      type: AssetType.fromString(data['type'] as String? ?? 'character'),
      description: data['description'] as String? ?? '',
      promptBody: newPromptBody,
      gcsImagePath: newGcsImagePath,
      isGlobal: isGlobal,
      // Preserve transient UI flags from the current state where relevant.
      isSaving: current is AssetEditorLoaded ? current.isSaving : false,
      isGeneratingPrompt: _isPromptGenerating(name),
      isGeneratingImage: _isImageGenerating(name),
      // Preserve errors until the user dismisses them.
      promptError:
          current is AssetEditorLoaded ? current.promptError : null,
      imageError: current is AssetEditorLoaded ? current.imageError : null,
      source: data['source'] as String? ?? 'extracted',
    ));
  }

  /// Recomputes [AssetEditorLoaded.isGeneratingPrompt] /
  /// [AssetEditorLoaded.isGeneratingImage] from [jobsCubit] and re-emits if
  /// the current state is loaded. No-ops before the first snapshot arrives.
  void _syncGeneratingFlags() {
    final current = state;
    if (current is! AssetEditorLoaded) return;
    emit(current.copyWith(
      isGeneratingPrompt: _isPromptGenerating(current.name),
      isGeneratingImage: _isImageGenerating(current.name),
    ));
  }

  bool _isPromptGenerating(String name) => jobsCubit.activeJob(
        type: 'image_prompt',
        projectId: projectSlug,
        sceneIndex: _sceneIndex,
        assetName: name,
      ) != null;

  bool _isImageGenerating(String name) => jobsCubit.activeJob(
        type: 'image',
        projectId: projectSlug,
        sceneIndex: _sceneIndex,
        assetName: name,
      ) != null;

  /// Parses the scene index out of [assetFirestorePath].
  ///
  /// `"assets/{id}"` → null (global). `"scenes/{n}/assets/{id}"` → `n`.
  static int? _deriveSceneIndex(String path) {
    final parts = path.split('/');
    if (parts.length >= 2 && parts[0] == 'scenes') {
      return int.tryParse(parts[1]);
    }
    return null;
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
  /// Registers the job with [jobsCubit] so it survives navigation and app
  /// restarts. [isGeneratingPrompt] is derived from [jobsCubit] (see
  /// [_syncGeneratingFlags]) — no local flag to lose track of.
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

      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'image_prompt',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: _sceneIndex,
        assetName: s.name,
      ));

      // isGeneratingPrompt stays true — cleared via jobsCubit once the
      // worker resolves the job (Firestore fast path or FCM/poll fallback).
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
  /// `gcs_image_path`. [isGeneratingImage] is derived from [jobsCubit] (see
  /// [_syncGeneratingFlags]).
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
      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'image',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
        sceneIndex: _sceneIndex,
        assetName: s.name,
      ));

      // isGeneratingImage stays true — cleared via jobsCubit once the
      // worker resolves the job.
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

  // ── Delete Asset (FEAT-037) ──────────────────────────────────────────────────

  /// Calls `DELETE /assets`. Returns `true` on success.
  ///
  /// When [force] is false (default) and other assets reference this one via
  /// the `@` naming convention, the backend responds 409; this sets
  /// [AssetEditorLoaded.deleteBlockedBy] with the dependent names so the UI
  /// can show them and offer a force-delete retry, and returns `false`.
  Future<bool> deleteAsset({bool force = false}) async {
    final s = state;
    if (s is! AssetEditorLoaded) return false;
    emit(s.copyWith(isDeleting: true, clearDeleteBlockedBy: true));

    try {
      await apiClient.deleteAsset(
        projectSlug: projectSlug,
        assetFirestorePath: assetFirestorePath,
        force: force,
      );
      return true;
    } on AssetDeleteBlockedException catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) {
        emit(current.copyWith(
          isDeleting: false,
          deleteBlockedBy: e.dependents.map((d) => d.name).toList(),
        ));
      }
      return false;
    } catch (e) {
      final current = state;
      if (current is AssetEditorLoaded) emit(current.copyWith(isDeleting: false));
      return false;
    }
  }

  void clearDeleteBlocked() {
    final s = state;
    if (s is AssetEditorLoaded) emit(s.copyWith(clearDeleteBlockedBy: true));
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    await _docSub?.cancel();
    await _jobsSub?.cancel();
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
      // Forward-compat notice that RegExp will become `final` in a future
      // Dart release (implement `Pattern` instead of `RegExp`); constructing
      // one via `RegExp(pattern)` remains the supported API and has no
      // replacement.
      // ignore: deprecated_member_use
      final match = RegExp(r"""['"]message['"]\s*:\s*['"](.+?)['"]""",
              dotAll: true)
          .firstMatch(after);
      if (match != null) return match.group(1)!;
    }
    return raw;
  }
}
