import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/filesystem/project_file_service.dart';
import '../../../core/models/models.dart';
import 'story_state.dart';

/// Cubit for the Story Editor Screen (FEAT-008, FEAT-009).
///
/// Responsibilities:
/// - Load `story.mdx`, parse `# N` headings into [StoryScene] blocks.
/// - Track per-scene body edits and auto-save on a debounce timer.
/// - Trigger `/assets` extraction and delegate directory creation to
///   [ProjectFileService].
class StoryCubit extends Cubit<StoryState> {
  StoryCubit({
    required this.projectName,
    required this.fileService,
    required this.apiClient,
  }) : super(const StoryLoading());

  final String projectName;
  final ProjectFileService fileService;
  final ArkMaskApiClient apiClient;

  Timer? _saveTimer;

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Reads `story.mdx` from device and emits [StoryLoaded] with parsed scenes.
  Future<void> load() async {
    emit(const StoryLoading());
    try {
      final raw = await fileService.readStory(projectName);
      emit(StoryLoaded(scenes: _parseScenes(raw)));
    } catch (e) {
      emit(StoryError(message: e.toString()));
    }
  }

  // ── Scene edits ───────────────────────────────────────────────────────────

  /// Called when the body of scene [sceneNumber] changes in the editor.
  ///
  /// Updates the in-memory state immediately and schedules a debounced save
  /// (1.5 s idle time triggers a write to `story.mdx`).
  ///
  /// If the scene doesn't exist yet (e.g. typing into the empty-state
  /// placeholder for scene 1), it is appended and then sorted.
  void onSceneBodyChanged(int sceneNumber, String body) {
    final current = state;
    if (current is! StoryLoaded) return;

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

  /// Saves immediately (e.g. on back gesture before pop).
  Future<void> saveNow() async {
    _saveTimer?.cancel();
    await _save();
  }

  Future<void> _save() async {
    final current = state;
    if (current is! StoryLoaded) return;
    // Capture scenes NOW before emitting isSaving (which triggers a rebuild).
    final scenesToWrite = List<StoryScene>.from(current.scenes);
    emit(current.copyWith(isSaving: true));
    try {
      await fileService.writeStory(projectName, _serializeScenes(scenesToWrite));
      emit((state as StoryLoaded).copyWith(isSaving: false, savedRecently: true));
      // Auto-clear "Saved ✓" indicator after 2 s.
      Timer(const Duration(seconds: 2), () {
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

  /// Sends the story content to `/assets` and creates directories on device.
  ///
  /// If assets already exist, the caller is expected to show a confirmation
  /// dialog before calling this method (the cubit does not check — it always
  /// proceeds).
  Future<void> extractAssets() async {
    final current = state;
    if (current is! StoryLoaded) return;
    if (current.sceneCount == 0) {
      emit(current.copyWith(
          extractError: 'Write at least one scene before extracting assets.'));
      return;
    }

    // Save first so the API receives the latest content.
    _saveTimer?.cancel();
    await _save();

    final s = state;
    if (s is! StoryLoaded) return;
    emit(s.copyWith(isExtracting: true, clearExtractError: true));

    try {
      final storyContent = _serializeScenes(s.scenes);
      final assets = await apiClient.extractAssets(storyContent: storyContent);
      final extractedList = (assets['assets'] as List<dynamic>)
          .map((e) => ExtractedAsset.fromJson(e as Map<String, dynamic>))
          .toList();

      await fileService.createAssetDirectories(
        projectName: projectName,
        assets: extractedList,
      );

      emit((state as StoryLoaded).copyWith(isExtracting: false));
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

  void clearExtractError() {
    final s = state;
    if (s is StoryLoaded) emit(s.copyWith(clearExtractError: true));
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
      // No headings: treat the whole file as scene 1.
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
    return super.close();
  }
}
