import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import 'story_state.dart';

/// Cubit for the Story Editor Screen (FEAT-008, FEAT-038).
///
/// Responsibilities:
/// - Subscribe to the Firestore project document and parse `story_content`
///   (a `# N` headed MDX string) into [StoryScene] blocks.
/// - Track per-scene body edits and auto-save on a debounce timer.
/// - Trigger `/refine-story` (async job) and track completion via the job
///   document's status field — the worker writes the rewritten story to the
///   project document's `refined_story_preview` field (never `story_content`
///   directly), so this cubit just relays the Firestore listener's view of
///   that field to the Refine Ready banner.
///
/// Asset extraction (FEAT-009) no longer lives on this screen as of
/// FEAT-038 — it moved to the Project File Browser (see
/// `FileBrowserCubit.extractAssets`). This screen's former "Extract Assets"
/// toolbar slot is now "Refine Story".
///
/// [isRefining] is derived live from [JobsCubit] (mirrors how extraction
/// used to be tracked) rather than a plain local flag, so returning to this
/// screen mid-refine correctly restores the indicator, and it clears even if
/// the job resolves via FCM/poll while another screen is on top.
class StoryCubit extends Cubit<StoryState> {
  StoryCubit({
    required this.projectSlug,
    required this.apiClient,
    required this.jobsCubit,
  }) : super(const StoryLoading());

  final String projectSlug;
  final ArkMaskApiClient apiClient;
  final JobsCubit jobsCubit;

  Timer? _saveTimer;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _refineJobSub;
  StreamSubscription<JobsState>? _jobsSub;

  /// True while a project-level `/refine-story` job is pending/running.
  bool get _isRefining => jobsCubit.activeJob(
        type: 'refine',
        projectId: projectSlug,
      ) != null;

  /// Recomputes [StoryLoaded.isRefining] from [jobsCubit] and re-emits.
  void _syncRefiningFlag() {
    final current = state;
    if (current is! StoryLoaded) return;
    emit(current.copyWith(isRefining: _isRefining));
  }

  /// True while the user has uncommitted edits that should not be clobbered
  /// by incoming Firestore snapshots.
  bool _isEditing = false;

  // ── Firestore helpers ────────────────────────────────────────────────────────

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> get _projectDoc =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .collection('projects')
          .doc(projectSlug);

  CollectionReference<Map<String, dynamic>> get _globalAssetsCol =>
      _projectDoc.collection('assets');

  CollectionReference<Map<String, dynamic>> get _scenesCol =>
      _projectDoc.collection('scenes');

  DocumentReference<Map<String, dynamic>> _jobDoc(String jobId) =>
      FirebaseFirestore.instance.collection('users').doc(_uid).collection('jobs').doc(jobId);

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Subscribes to the Firestore project document and emits [StoryLoaded] on
  /// the first snapshot. Subsequent snapshots only update scene text when the
  /// user is NOT mid-edit (to avoid clobbering in-flight changes); the refine
  /// preview fields and generation settings are always applied live.
  void load() {
    _docSub?.cancel();
    emit(const StoryLoading());

    // Re-sync isRefining on every job-state change — keeps the indicator
    // correct even if refine resolves via FCM/poll while this screen isn't
    // mounted, and restores it correctly if the screen is re-created
    // mid-refine.
    _jobsSub?.cancel();
    _jobsSub = jobsCubit.stream.listen((_) => _syncRefiningFlag());

    _docSub = _projectDoc.snapshots().listen(
      (snap) {
        final data = snap.data() ?? {};
        final raw = data['story_content'] as String? ?? '';
        final scenes = _parseScenes(raw);

        // Parse generation_settings from the snapshot so the UI always
        // reflects the current server-side values (including remote updates).
        final settingsRaw = data['generation_settings'] as Map<String, dynamic>?;
        final settings = settingsRaw != null
            ? GenerationSettings.fromFirestore(settingsRaw)
            : const GenerationSettings();

        final refinedPreview = data['refined_story_preview'] as String?;
        final refinedAtTs = data['refined_story_generated_at'] as Timestamp?;

        if (state is StoryLoading) {
          // First snapshot — always emit loaded state, checking whether a
          // refine job is already in flight (e.g. the user navigated away
          // and back while it was running).
          emit(StoryLoaded(
            scenes: scenes,
            generationSettings: settings,
            isRefining: _isRefining,
            refinedStoryPreview: refinedPreview,
            refinedStoryGeneratedAt: refinedAtTs?.toDate(),
          ));
        } else {
          final current = state;
          if (current is! StoryLoaded) return;
          emit(current.copyWith(
            // Scene text is only replaced when the user isn't mid-edit — same
            // guard as before. Generation settings and the refine preview
            // fields are always applied, since they're written by separate
            // code paths (settings sheet / worker), never by this screen's
            // own typing.
            scenes: _isEditing ? current.scenes : scenes,
            generationSettings: settings,
            refinedStoryPreview: refinedPreview,
            clearRefinedStoryPreview: refinedPreview == null,
            refinedStoryGeneratedAt: refinedAtTs?.toDate(),
          ));
        }
      },
      onError: (Object e) => emit(StoryError(message: e.toString())),
    );
  }

  // ── Scene edits ───────────────────────────────────────────────────────────

  /// Called on the first keystroke and on every subsequent character change.
  ///
  /// Sets [_isEditing] = true so remote snapshots do not overwrite the user's
  /// work until auto-save completes.
  void onSceneBodyChanged(int sceneNumber, String body) {
    final current = state;
    if (current is! StoryLoaded) return;

    _isEditing = true;

    final List<StoryScene> updated;
    if (current.scenes.any((s) => s.number == sceneNumber)) {
      updated = current.scenes
          .map((s) => s.number == sceneNumber ? s.copyWith(body: body) : s)
          .toList();
    } else {
      // Scene doesn't exist yet — add it (handles the empty-project case
      // where the placeholder scene 1 is not yet in the scenes list).
      updated = [...current.scenes, StoryScene(number: sceneNumber, body: body)]
        ..sort((a, b) => a.number.compareTo(b.number));
    }

    emit(current.copyWith(scenes: updated, savedRecently: false));
    _scheduleAutoSave();
  }

  /// Appends a new blank scene after all existing scenes.
  void addScene() {
    final current = state;
    if (current is! StoryLoaded) return;
    final nextNumber = current.scenes.isEmpty ? 2 : current.scenes.length + 1;
    final updated = _reindex([
      ...current.scenes,
      StoryScene(number: nextNumber, body: ''),
    ]);
    emit(current.copyWith(scenes: updated));
  }

  /// Inserts a blank scene immediately before the scene at [index] (0-based).
  /// All scene numbers are re-assigned sequentially after the insertion.
  void insertSceneBefore(int index) {
    final current = state;
    if (current is! StoryLoaded) return;
    final list = List<StoryScene>.from(current.scenes);
    list.insert(index, const StoryScene(number: 0, body: ''));
    emit(current.copyWith(scenes: _reindex(list)));
    _scheduleAutoSave();
  }

  /// Inserts a blank scene immediately after the scene at [index] (0-based).
  void insertSceneAfter(int index) {
    final current = state;
    if (current is! StoryLoaded) return;
    final list = List<StoryScene>.from(current.scenes);
    list.insert(index + 1, const StoryScene(number: 0, body: ''));
    emit(current.copyWith(scenes: _reindex(list)));
    _scheduleAutoSave();
  }

  /// Deletes the scene at [index] (0-based) and re-indexes remaining scenes.
  /// No-op if only one scene remains (minimum 1 scene enforced).
  void deleteScene(int index) {
    final current = state;
    if (current is! StoryLoaded) return;
    if (current.scenes.length <= 1) return; // cannot delete the last scene
    final list = List<StoryScene>.from(current.scenes)..removeAt(index);
    emit(current.copyWith(scenes: _reindex(list)));
    _scheduleAutoSave();
  }

  /// Re-assigns 1-based sequential numbers to scenes in their current order.
  static List<StoryScene> _reindex(List<StoryScene> scenes) {
    return [
      for (var i = 0; i < scenes.length; i++)
        scenes[i].copyWith(number: i + 1),
    ];
  }

  void _scheduleAutoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _save);
  }

  /// Cancels the debounce timer and saves immediately (called on back gesture).
  Future<void> saveNow() async {
    _saveTimer?.cancel();
    await _save();
  }

  Future<void> _save() async {
    final current = state;
    if (current is! StoryLoaded) return;

    // Capture scenes before the isSaving emit so the serialized content
    // matches exactly what is displayed in the editor at this moment.
    final scenesToWrite = List<StoryScene>.from(current.scenes);
    emit(current.copyWith(isSaving: true));

    try {
      await _projectDoc.update({
        'story_content': _serializeScenes(scenesToWrite),
        'scene_count': scenesToWrite.length,
        'updated_at': FieldValue.serverTimestamp(),
      });

      // Clear editing flag after a successful save so subsequent Firestore
      // snapshots are no longer suppressed.
      _isEditing = false;

      emit((state as StoryLoaded).copyWith(isSaving: false, savedRecently: true));

      // Auto-clear "Saved ✓" indicator after 2 s. Guard isClosed in case the
      // user navigates away before the timer fires.
      Timer(const Duration(seconds: 2), () {
        if (isClosed) return;
        final s = state;
        if (s is StoryLoaded && s.savedRecently) {
          emit(s.copyWith(savedRecently: false));
        }
      });
    } catch (_) {
      emit((state as StoryLoaded).copyWith(isSaving: false));
    }
  }

  // ── Story refinement (FEAT-038) ───────────────────────────────────────────

  /// Enqueues `/refine-story` (async job) and tracks completion via the job
  /// document's status field.
  ///
  /// The worker writes the rewritten story to the project document's
  /// `refined_story_preview` field — this cubit never touches `story_content`
  /// itself as a result of this call; the existing Firestore listener above
  /// picks up the preview field once the worker writes it.
  ///
  /// Pass [force] = true to bypass both guard dialogs (existing
  /// assets/scenes — R-027; and an already-unreviewed preview) after the
  /// screen has shown the corresponding confirmation and the user confirmed.
  Future<void> refineStory({bool force = false}) async {
    final current = state;
    if (current is! StoryLoaded) return;
    if (current.sceneCount == 0) return; // button is disabled in this case

    // Flush any pending debounce so the refine call reads the latest text —
    // the backend itself re-reads story_content from Firestore, so this just
    // ensures that read isn't stale by up to 1.5s.
    _saveTimer?.cancel();
    await _save();

    if (!force) {
      if (current.refinedStoryPreview != null) {
        emit(current.copyWith(showUnreviewedRerunWarning: true));
        return;
      }
      if (await _hasExistingAssetsOrScenes()) {
        emit(current.copyWith(showExistingAssetsWarning: true));
        return;
      }
    }

    final s = state;
    if (s is! StoryLoaded) return;
    emit(s.copyWith(clearRefineError: true));

    try {
      final jobId = await apiClient.refineStory(projectSlug: projectSlug);

      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'refine',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
      ));

      _listenForRefineJobCompletion(jobId);
      // isRefining stays derived from jobsCubit — no explicit "start"
      // emission needed; _syncRefiningFlag picks it up on the next
      // jobsCubit state change (which `enqueue` above triggers).
    } on ApiInsufficientCredits {
      emit((state as StoryLoaded).copyWith(refineError: '__credits__'));
    } on ApiError catch (e) {
      emit((state as StoryLoaded).copyWith(refineError: _apiErrorMessage(e)));
    } catch (e) {
      emit((state as StoryLoaded).copyWith(refineError: e.toString()));
    }
  }

  /// True if the project already has any extracted assets (global or
  /// scene-local) or any scene with a generated storyboard/video — the
  /// condition that triggers the R-027 "scene numbering may change" warning
  /// before a refine request is sent.
  Future<bool> _hasExistingAssetsOrScenes() async {
    final globalAssets = await _globalAssetsCol.limit(1).get();
    if (globalAssets.docs.isNotEmpty) return true;

    // Any scenes/{n} document existing at all implies extraction has
    // touched this project (scene docs are otherwise only created manually
    // or by /assets — see FileBrowserCubit._CreateSceneSheet) — checked
    // together with each scene's own storyboard/video fields and any
    // scene-local asset documents to cover the full "assets or generated
    // scenes/videos" condition from FEAT-038's acceptance criteria without
    // an expensive per-scene subcollection fan-out query.
    final scenes = await _scenesCol.get();
    for (final doc in scenes.docs) {
      final data = doc.data();
      if ((data['storyboard_body'] as String?)?.isNotEmpty == true) return true;
      if (data['gcs_video_path'] != null) return true;
      final sceneAssets = await doc.reference.collection('assets').limit(1).get();
      if (sceneAssets.docs.isNotEmpty) return true;
    }
    return false;
  }

  /// Listens to the job document for [jobId] until it reaches a terminal
  /// state (success/failed), then clears [isRefining] and updates the job
  /// registry. There's no single Firestore field to watch for "job started"
  /// on this job type the way image/video/merge jobs do — the field it
  /// writes (`refined_story_preview`) is already covered by the project doc
  /// listener in [load], so this listener exists purely to surface failures
  /// and resolve the job registry promptly.
  void _listenForRefineJobCompletion(String jobId) {
    _refineJobSub?.cancel();
    _refineJobSub = _jobDoc(jobId).snapshots().listen((snap) {
      final jobStatus = snap.data()?['status'] as String?;
      if (jobStatus != 'success' && jobStatus != 'failed') return;

      _refineJobSub?.cancel();
      _refineJobSub = null;

      jobsCubit.resolve(jobId, jobStatus!);

      final current = state;
      if (current is! StoryLoaded) return;
      if (jobStatus == 'failed') {
        final errorMessage = snap.data()?['error_message'] as String?;
        emit(current.copyWith(
          isRefining: false,
          refineError: errorMessage ?? 'Story refinement failed.',
        ));
      } else {
        emit(current.copyWith(isRefining: false));
      }
    });
  }

  void clearRefineError() {
    final s = state;
    if (s is StoryLoaded) emit(s.copyWith(clearRefineError: true));
  }

  /// Writes `null` to `refined_story_preview` (and its timestamp) directly —
  /// used by the Refine Ready banner's "Discard" action. `story_content` is
  /// not touched. The Refine Story Preview screen (Screen 8a) performs this
  /// same write itself rather than going through this cubit, since it isn't
  /// guaranteed to be mounted while that screen is open.
  Future<void> discardRefinedPreview() async {
    try {
      await _projectDoc.update({
        'refined_story_preview': null,
        'refined_story_generated_at': null,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Non-fatal — banner stays visible and the user can retry.
    }
  }

  // ── Generation settings ───────────────────────────────────────────────────

  /// Persist updated [settings] to the Firestore project document and optimistically
  /// update the local state.
  ///
  /// The backend reads these values when `/image-prompt`, `/video-prompt`,
  /// and `/refine-story` are called — the mobile request bodies are unchanged.
  Future<void> updateGenerationSettings(GenerationSettings settings) async {
    final current = state;
    if (current is! StoryLoaded) return;

    // Optimistic update so the UI reflects the change immediately.
    emit(current.copyWith(generationSettings: settings));

    try {
      await _projectDoc.update({
        'generation_settings': settings.toFirestore(),
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Roll back to the previous settings on failure.
      emit((state as StoryLoaded).copyWith(generationSettings: current.generationSettings));
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  static String _apiErrorMessage(ApiError e) => switch (e) {
        ApiConflict(:final message) => message,
        ApiValidationError(:final detail) => detail,
        ApiServerError(:final message) => message,
        ApiNetworkError(:final message) => message,
        ApiUnknownError(:final message) => message,
        ApiInsufficientCredits() => 'Insufficient credits',
        ApiUnauthorized() => 'Unauthorized',
      };

  // ── MDX parsing & serialization ───────────────────────────────────────────

  /// Parses `# N` headings from raw MDX into an ordered list of [StoryScene].
  static List<StoryScene> _parseScenes(String raw) {
    if (raw.trim().isEmpty) return [];

    // Match `# <digit(s)>` at the start of a line.
    // Forward-compat notice that RegExp will become `final` in a future Dart
    // release (implement `Pattern` instead of `RegExp`); constructing one via
    // `RegExp(pattern)` remains the supported API and has no replacement.
    // ignore: deprecated_member_use
    final headingPattern = RegExp(r'^# (\d+)\s*$', multiLine: true);
    final matches = headingPattern.allMatches(raw).toList();

    if (matches.isEmpty) {
      // No headings: treat the whole content as scene 1.
      return [StoryScene(number: 1, body: raw.trim())];
    }

    final scenes = <StoryScene>[];
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final number = int.parse(match.group(1)!);
      final bodyStart = match.end;
      final bodyEnd = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      final body = raw.substring(bodyStart, bodyEnd).trim();
      scenes.add(StoryScene(number: number, body: body));
    }
    return scenes;
  }

  /// Serializes [scenes] back to the MDX format `# N\n<body>\n\n`.
  static String _serializeScenes(List<StoryScene> scenes) {
    if (scenes.isEmpty) return '';
    final buf = StringBuffer();
    for (final scene in scenes) {
      buf.write('# ${scene.number}\n${scene.body}\n\n');
    }
    return buf.toString().trimRight();
  }

  @override
  Future<void> close() {
    _saveTimer?.cancel();
    _docSub?.cancel();
    _refineJobSub?.cancel();
    _jobsSub?.cancel();
    return super.close();
  }
}
