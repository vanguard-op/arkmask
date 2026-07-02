import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import 'story_state.dart';

/// Cubit for the Story Editor Screen (FEAT-008, FEAT-009).
///
/// Responsibilities:
/// - Subscribe to the Firestore project document and parse `story_content`
///   (a `# N` headed MDX string) into [StoryScene] blocks.
/// - Track per-scene body edits and auto-save on a debounce timer.
/// - Trigger `/assets` extraction (async job) and track completion via the
///   job document's status field — the worker writes the extracted asset
///   documents directly to Firestore (see app.services.asset_writer on the
///   backend), so this cubit no longer parses or writes them itself.
///
/// [isExtracting] is derived live from [JobsCubit] (see
/// [_syncExtractingFlag]) rather than a plain local flag, so returning to
/// this screen mid-extraction correctly restores the indicator, and it
/// clears even if the job resolves via FCM/poll while another screen is on
/// top. The direct job-document listener below remains as a fast path while
/// this screen happens to be open.
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
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _assetsJobSub;
  StreamSubscription<JobsState>? _jobsSub;

  /// True while a project-level `/assets` extraction job is pending/running.
  bool get _isExtracting => jobsCubit.activeJob(
        type: 'assets',
        projectId: projectSlug,
      ) != null;

  /// Recomputes [StoryLoaded.isExtracting] from [jobsCubit] and re-emits.
  void _syncExtractingFlag() {
    final current = state;
    if (current is! StoryLoaded) return;
    emit(current.copyWith(isExtracting: _isExtracting));
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

  DocumentReference<Map<String, dynamic>> _jobDoc(String jobId) =>
      FirebaseFirestore.instance.collection('users').doc(_uid).collection('jobs').doc(jobId);

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Subscribes to the Firestore project document and emits [StoryLoaded] on
  /// the first snapshot. Subsequent snapshots only update state when the user
  /// is NOT mid-edit (to avoid clobbering in-flight changes).
  void load() {
    _docSub?.cancel();
    emit(const StoryLoading());

    // Re-sync isExtracting on every job-state change — keeps the indicator
    // correct even if extraction resolves via FCM/poll while this screen
    // isn't mounted, and restores it correctly if the screen is re-created
    // mid-extraction.
    _jobsSub?.cancel();
    _jobsSub = jobsCubit.stream.listen((_) => _syncExtractingFlag());

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

        if (state is StoryLoading) {
          // First snapshot — always emit loaded state, checking whether an
          // extraction job is already in flight (e.g. the user navigated
          // away and back while it was running).
          emit(StoryLoaded(
            scenes: scenes,
            generationSettings: settings,
            isExtracting: _isExtracting,
          ));
        } else if (!_isEditing) {
          // Subsequent remote update while the user is not typing.
          final current = state;
          if (current is StoryLoaded) {
            emit(current.copyWith(scenes: scenes, generationSettings: settings));
          }
        }
        // If _isEditing is true we intentionally drop the remote snapshot so
        // the user's in-progress text is not replaced by the last-saved version.
        // Generation settings updates are applied even while editing since they
        // are written by a separate code path.
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

    emit(current.copyWith(scenes: updated, savedRecently: false, clearExtractError: true));
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

  // ── Asset extraction ──────────────────────────────────────────────────────

  /// Enqueues `/assets` extraction (async job) and tracks completion via the
  /// job document's status field.
  ///
  /// The worker writes the extracted asset documents directly to Firestore
  /// (see backend/app/services/asset_writer.py) — this cubit no longer
  /// parses the AI response or writes any documents itself. The existing
  /// Firestore listeners elsewhere in the app (file browser, asset editor)
  /// pick up the new documents automatically once they appear.
  ///
  /// Pass [force] = true to skip the existing-assets guard (the screen shows
  /// a confirmation dialog when `state.hasExistingAssets == true` and calls
  /// this method with `force: true` on user confirmation).
  Future<void> extractAssets({bool force = false}) async {
    final current = state;
    if (current is! StoryLoaded) return;

    if (current.sceneCount == 0) {
      emit(current.copyWith(
          extractError: 'Write at least one scene before extracting assets.'));
      return;
    }

    if (!force) {
      // Check whether any asset documents already exist in Firestore.
      final existing = await _globalAssetsCol.limit(1).get();
      if (existing.docs.isNotEmpty) {
        // Signal the screen to show a confirmation dialog.
        emit(current.copyWith(hasExistingAssets: true));
        return;
      }
    }

    // Flush any pending debounce before sending content to the API.
    _saveTimer?.cancel();
    await _save();

    final s = state;
    if (s is! StoryLoaded) return;
    emit(s.copyWith(isExtracting: true, clearExtractError: true, hasExistingAssets: false));

    try {
      final storyContent = _serializeScenes(s.scenes);
      final jobId = await apiClient.extractAssets(
        projectSlug: projectSlug,
        storyContent: storyContent,
      );

      await jobsCubit.enqueue(JobRegistryEntry(
        jobId: jobId,
        type: 'assets',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
      ));

      _listenForAssetsJobCompletion(jobId);
      // isExtracting stays true — cleared via jobsCubit once the worker
      // finishes (success or failed), either through the fast-path listener
      // below or through FCM/poll if this screen is no longer mounted.
    } on ApiInsufficientCredits {
      emit((state as StoryLoaded)
          .copyWith(isExtracting: false, extractError: '__credits__'));
    } on ApiError catch (e) {
      emit((state as StoryLoaded)
          .copyWith(isExtracting: false, extractError: _apiErrorMessage(e)));
    } catch (e) {
      emit((state as StoryLoaded)
          .copyWith(isExtracting: false, extractError: e.toString()));
    }
  }

  /// Listens to the job document for [jobId] until it reaches a terminal
  /// state (success/failed), then clears [isExtracting] and updates the job
  /// registry. There's no single Firestore field to watch for this job type
  /// (extraction creates multiple new documents), unlike image/video/merge
  /// which each have one field to watch — so this cubit watches the job
  /// document directly instead.
  void _listenForAssetsJobCompletion(String jobId) {
    _assetsJobSub?.cancel();
    _assetsJobSub = _jobDoc(jobId).snapshots().listen((snap) {
      final jobStatus = snap.data()?['status'] as String?;
      if (jobStatus != 'success' && jobStatus != 'failed') return;

      _assetsJobSub?.cancel();
      _assetsJobSub = null;

      jobsCubit.resolve(jobId, jobStatus!);

      final current = state;
      if (current is! StoryLoaded) return;
      if (jobStatus == 'failed') {
        final errorMessage = snap.data()?['error_message'] as String?;
        emit(current.copyWith(
          isExtracting: false,
          extractError: errorMessage ?? 'Asset extraction failed.',
        ));
      } else {
        emit(current.copyWith(isExtracting: false));
      }
    });
  }

  void clearExtractError() {
    final s = state;
    if (s is StoryLoaded) emit(s.copyWith(clearExtractError: true));
  }

  // ── Generation settings ───────────────────────────────────────────────────

  /// Persist updated [settings] to the Firestore project document and optimistically
  /// update the local state.
  ///
  /// The backend reads these values when `/image-prompt` and `/video-prompt` are
  /// called — the mobile request bodies are unchanged.
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
    _assetsJobSub?.cancel();
    _jobsSub?.cancel();
    return super.close();
  }
}
