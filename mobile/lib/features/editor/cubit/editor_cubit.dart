import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/job_registry_service.dart';
import '../../../core/models/models.dart';
import 'editor_state.dart';

/// Cubit for the Video Editor Screen (FEAT-018, FEAT-019, FEAT-021).
///
/// Phase 3 cloud-first rewrite:
/// - Reads scene clips from Firestore `scenes/` subcollection real-time listener.
/// - Streams video via presigned URLs (no local file downloads during editing).
/// - Export sends `POST /merge` to cloud worker; listens for `gcs_final_path`
///   on the Firestore project root document to know when the job completes.
/// - Download to gallery fetches the final presigned URL and saves bytes to a
///   temp file, then hands it to [Gal.putVideo].
///
/// No FFmpeg runs on-device. No [ProjectFileService] dependency.
class EditorCubit extends Cubit<EditorState> {
  EditorCubit({
    required this.projectSlug,
    required this.apiClient,
    required this.jobRegistryService,
  }) : super(EditorLoading());

  final String projectSlug;
  final ArkMaskApiClient apiClient;
  final JobRegistryService jobRegistryService;

  /// [VideoPlayerController]s keyed by scene number. Created lazily when the
  /// clip is selected or played; disposed on [close].
  final Map<int, VideoPlayerController> _controllers = {};

  /// Active Firestore subscriptions — cancelled in [close].
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _projectSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _scenesSub;

  /// Returns the [VideoPlayerController] for [sceneNumber], or null if the
  /// scene has no presigned URL yet or the controller failed to initialise.
  VideoPlayerController? controllerFor(int sceneNumber) =>
      _controllers[sceneNumber];

  // ── Load ───────────────────────────────────────────────────────────────────

  /// Opens two Firestore real-time listeners (project root + scenes
  /// subcollection) and emits [EditorLoaded] immediately with whatever data is
  /// already available, patching clips as presigned URLs and durations resolve.
  Future<void> load() async {
    emit(EditorLoading());

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(EditorError(message: 'Not signed in.'));
      return;
    }

    final firestore = FirebaseFirestore.instance;
    final projectRef = firestore
        .collection('users')
        .doc(uid)
        .collection('projects')
        .doc(projectSlug);

    // ── 1. Project root listener — watches gcs_final_path ──────────────────
    _projectSub = projectRef.snapshots().listen((snap) {
      if (isClosed) return;
      final data = snap.data();
      final gcsPath = data?['gcs_final_path'] as String?;

      final s = state;
      if (s is EditorLoaded) {
        final wasMerging = s.isMerging;
        if (wasMerging && gcsPath != null) {
          // Merge completed — clear the merging flag and update the job entry.
          _resolveActiveMergeJob();
        }
        if (s.gcsExportPath != gcsPath) {
          emit(s.copyWith(
            isMerging: gcsPath != null ? false : s.isMerging,
            gcsExportPath: gcsPath,
          ));
        }
      }
    });

    // ── 2. Scenes subcollection listener ────────────────────────────────────
    _scenesSub = projectRef
        .collection('scenes')
        .snapshots()
        .listen((snap) async {
      if (isClosed) return;

      // Parse documents → SceneDocument list sorted by scene_number.
      final sceneDocs = snap.docs
          .map((d) => SceneDocument.fromFirestore(d.id, d.data()))
          .toList()
        ..sort((a, b) => a.sceneNumber.compareTo(b.sceneNumber));

      final savedTrims = await _loadSavedTrims(projectSlug);
      final savedTransitions = await _loadSavedTransitions(projectSlug);

      // Preserve gcsExportPath from project listener if already loaded.
      final currentExportPath = state is EditorLoaded
          ? (state as EditorLoaded).gcsExportPath
          : null;
      final currentIsMerging = state is EditorLoaded
          ? (state as EditorLoaded).isMerging
          : false;

      // Build the clip list. Presigned URL and duration may not yet be known;
      // emit immediately with nulls and patch each clip asynchronously.
      final clips = <ClipEntry>[];
      for (final scene in sceneDocs) {
        // Use 0.0 as the duration placeholder until the probe resolves.
        // Saved trim is applied in _fetchAndPatchClip after the duration is known.
        const placeholder = 0.0;
        final trimState = ClipTrimState(
          sceneNumber: scene.sceneNumber,
          inPoint: 0,
          outPoint: placeholder,
          totalDuration: placeholder,
        );

        // Determine if a video generation job is active for this scene.
        final isGenerating = jobRegistryService
            .activeForProject(projectSlug)
            .any((j) => j.sceneIndex == scene.sceneNumber && j.type == 'video');

        clips.add(ClipEntry(
          sceneNumber: scene.sceneNumber,
          gcsVideoPath: scene.gcsVideoPath,
          presignedUrl: null, // filled in below asynchronously
          totalDuration: placeholder,
          trimState: trimState,
          isGenerating: isGenerating,
        ));
      }

      if (isClosed) return;
      emit(EditorLoaded(
        projectSlug: projectSlug,
        clips: clips,
        gcsExportPath: currentExportPath,
        isMerging: currentIsMerging,
        transitions: savedTransitions,
      ));

      // ── 3. Async URL fetch + duration probe per clip ─────────────────────
      // Each clip is resolved independently so the UI updates incrementally.
      for (var i = 0; i < sceneDocs.length; i++) {
        final scene = sceneDocs[i];
        if (scene.gcsVideoPath == null) continue;

        // Kick off URL fetch without blocking other clips.
        _fetchAndPatchClip(
          clipIndex: i,
          scene: scene,
          savedTrims: savedTrims,
        );
      }
    });
  }

  /// Fetches a presigned URL for [scene] and probes the clip duration, then
  /// patches the clip in state at [clipIndex].
  Future<void> _fetchAndPatchClip({
    required int clipIndex,
    required SceneDocument scene,
    required Map<int, ClipTrimState> savedTrims,
  }) async {
    if (scene.gcsVideoPath == null) return;

    String presignedUrl;
    try {
      presignedUrl =
          await apiClient.getPresignedUrl(gcsPath: scene.gcsVideoPath!);
    } catch (_) {
      // URL fetch failed — leave clip as no-video placeholder for now.
      return;
    }

    if (isClosed) return;

    // Probe duration by initialising a network player controller briefly.
    final duration = await _probeDuration(presignedUrl);

    if (isClosed) return;

    // Restore saved trim state if the duration matches within 100ms.
    final saved = savedTrims[scene.sceneNumber];
    final trimState = (saved != null &&
            (saved.totalDuration - duration).abs() < 0.1 &&
            duration > 0)
        ? saved
        : ClipTrimState(
            sceneNumber: scene.sceneNumber,
            inPoint: 0,
            outPoint: duration,
            totalDuration: duration,
          );

    final s = state;
    if (s is! EditorLoaded) return;
    if (clipIndex >= s.clips.length) return;

    final updatedClips = List<ClipEntry>.from(s.clips);
    updatedClips[clipIndex] = updatedClips[clipIndex].copyWith(
      presignedUrl: presignedUrl,
      totalDuration: duration,
      trimState: trimState,
    );
    emit(s.copyWith(clips: updatedClips));

    // Lazily create a VideoPlayerController for this clip (for thumbnail +
    // playback). We create it after the URL is known so we don't spin up
    // controllers for clips that are still being generated.
    await _ensureController(scene.sceneNumber, presignedUrl);
  }

  /// Creates and initialises a [VideoPlayerController] for [sceneNumber] if
  /// one does not already exist. Safe to call multiple times.
  Future<void> _ensureController(int sceneNumber, String presignedUrl) async {
    if (_controllers.containsKey(sceneNumber)) return;
    final ctrl =
        VideoPlayerController.networkUrl(Uri.parse(presignedUrl));
    _controllers[sceneNumber] = ctrl;
    try {
      await ctrl.initialize();
      // Seek to frame 0 so the thumbnail shows the first frame.
      await ctrl.seekTo(Duration.zero);
    } catch (_) {
      // Non-fatal: thumbnail will be absent but playback can be retried.
    }
    // Trigger a rebuild so the thumbnail appears.
    if (!isClosed && state is EditorLoaded) {
      emit(state); // same state, new identity → rebuilds video thumbnail
    }
  }

  /// Probes the duration of a presigned-URL video clip.
  ///
  /// Creates a [VideoPlayerController], initialises it (which fetches just the
  /// media headers from GCS), reads the duration, then disposes immediately.
  Future<double> _probeDuration(String presignedUrl) async {
    final ctrl =
        VideoPlayerController.networkUrl(Uri.parse(presignedUrl));
    try {
      await ctrl.initialize();
      return ctrl.value.duration.inMilliseconds / 1000.0;
    } catch (_) {
      return 0.0;
    } finally {
      await ctrl.dispose();
    }
  }

  /// Marks the active merge job as succeeded in the job registry.
  void _resolveActiveMergeJob() {
    final mergeJob = jobRegistryService
        .all
        .where((e) =>
            e.projectId == projectSlug &&
            e.type == 'merge' &&
            e.isPending)
        .firstOrNull;
    if (mergeJob != null) {
      jobRegistryService.updateStatus(
        mergeJob.jobId,
        'success',
        resolvedAt: DateTime.now(),
      );
    }
  }

  // ── Selection ──────────────────────────────────────────────────────────────

  void selectClip(int? index) {
    final s = state;
    if (s is! EditorLoaded) return;
    // Tapping the already-selected clip deselects it.
    final next = s.selectedClipIndex == index ? null : index;
    emit(s.copyWith(selectedClipIndex: next));

    // Lazily create a controller when the clip is first selected.
    if (next != null) {
      final clip = s.clips[next];
      if (clip.presignedUrl != null &&
          !_controllers.containsKey(clip.sceneNumber)) {
        _ensureController(clip.sceneNumber, clip.presignedUrl!);
      }
    }
  }

  // ── Trim ───────────────────────────────────────────────────────────────────

  /// Moves the **in-point** of the clip at [clipIndex] by [pixelDelta] pixels.
  /// 1 pixel = 1/24 second on the timeline ruler.
  void updateInPoint(int clipIndex, double pixelDelta) {
    final s = state;
    if (s is! EditorLoaded) return;

    final clip = s.clips[clipIndex];
    final delta = pixelDelta / 24.0;
    final maxIn = clip.trimState.outPoint - ClipTrimState.minDuration;
    var newIn = (clip.trimState.inPoint + delta).clamp(0.0, maxIn);

    // Snap to start if within 50ms.
    if (newIn < 0.05) newIn = 0.0;

    _hapticIfAtMin(
      oldDuration: clip.trimState.outPoint - clip.trimState.inPoint,
      newDuration: clip.trimState.outPoint - newIn,
    );

    final updated =
        _updateClipTrim(s.clips, clipIndex, clip.trimState.copyWith(inPoint: newIn));
    emit(s.copyWith(clips: updated));

    _controllers[clip.sceneNumber]
        ?.seekTo(Duration(milliseconds: (newIn * 1000).round()));
  }

  /// Moves the **out-point** of the clip at [clipIndex] by [pixelDelta] pixels.
  void updateOutPoint(int clipIndex, double pixelDelta) {
    final s = state;
    if (s is! EditorLoaded) return;

    final clip = s.clips[clipIndex];
    final delta = pixelDelta / 24.0;
    final minOut = clip.trimState.inPoint + ClipTrimState.minDuration;
    var newOut =
        (clip.trimState.outPoint + delta).clamp(minOut, clip.totalDuration);

    // Snap to end if within 50ms.
    if ((clip.totalDuration - newOut) < 0.05) newOut = clip.totalDuration;

    _hapticIfAtMin(
      oldDuration: clip.trimState.outPoint - clip.trimState.inPoint,
      newDuration: newOut - clip.trimState.inPoint,
    );

    final updated =
        _updateClipTrim(s.clips, clipIndex, clip.trimState.copyWith(outPoint: newOut));
    emit(s.copyWith(clips: updated));

    _controllers[clip.sceneNumber]
        ?.seekTo(Duration(milliseconds: (newOut * 1000).round()));
  }

  /// Resets the trim of [clipIndex] back to the full clip duration.
  void resetTrim(int clipIndex) {
    final s = state;
    if (s is! EditorLoaded) return;
    final clip = s.clips[clipIndex];
    final reset = ClipTrimState(
      sceneNumber: clip.sceneNumber,
      inPoint: 0,
      outPoint: clip.totalDuration,
      totalDuration: clip.totalDuration,
    );
    final updated = _updateClipTrim(s.clips, clipIndex, reset);
    emit(s.copyWith(clips: updated));
    _persistEditorState(projectSlug, updated, s.transitions);
  }

  /// Called when a trim drag ends — persists the current trim + transition state.
  void onTrimDragEnd() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistEditorState(s.projectSlug, s.clips, s.transitions);
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  void togglePlayPause(int clipIndex) {
    final s = state;
    if (s is! EditorLoaded) return;
    final clip = s.clips[clipIndex];
    final ctrl = _controllers[clip.sceneNumber];
    if (ctrl == null) return;

    if (ctrl.value.isPlaying) {
      ctrl.pause();
    } else {
      final outMs = (clip.trimState.outPoint * 1000).round();
      if (ctrl.value.position.inMilliseconds >= outMs) {
        ctrl.seekTo(
            Duration(milliseconds: (clip.trimState.inPoint * 1000).round()));
      }
      ctrl.play();
    }
  }

  void seekPreview(int clipIndex, double seconds) {
    final s = state;
    if (s is! EditorLoaded) return;
    final clip = s.clips[clipIndex];
    _controllers[clip.sceneNumber]
        ?.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  // ── Presigned URL refresh ──────────────────────────────────────────────────

  /// Re-fetches the presigned URL for [clipIndex] (called when an `Image.network`
  /// thumbnail fails to load — the URL may have expired after 2 hours).
  Future<void> refreshPresignedUrl(int clipIndex) async {
    final s = state;
    if (s is! EditorLoaded) return;
    if (clipIndex >= s.clips.length) return;

    final clip = s.clips[clipIndex];
    if (clip.gcsVideoPath == null) return;

    try {
      final freshUrl =
          await apiClient.getPresignedUrl(gcsPath: clip.gcsVideoPath!);
      if (isClosed) return;
      final updated = List<ClipEntry>.from((state as EditorLoaded).clips);
      updated[clipIndex] = updated[clipIndex].copyWith(presignedUrl: freshUrl);
      emit((state as EditorLoaded).copyWith(clips: updated));

      // Recreate the player controller with the fresh URL.
      final old = _controllers.remove(clip.sceneNumber);
      await old?.dispose();
      await _ensureController(clip.sceneNumber, freshUrl);
    } catch (_) {
      // Non-fatal — thumbnail stays blank until the user retries.
    }
  }

  // ── Export (cloud merge) ───────────────────────────────────────────────────

  /// Sends `POST /merge` to the cloud worker.
  ///
  /// Guards: at least one clip must have a video. If [gcsExportPath] is already
  /// set the screen shows a confirmation dialog before calling this method.
  Future<void> export() async {
    final s = state;
    if (s is! EditorLoaded) return;

    // Guard: need at least one clip with video.
    final validClips =
        s.clips.where((c) => c.hasVideo).toList();
    if (validClips.isEmpty) {
      emit(s.copyWith(exportError: 'No video clips to export.'));
      return;
    }

    // Pause any playing controllers before export.
    for (final ctrl in _controllers.values) {
      if (ctrl.value.isPlaying) ctrl.pause();
    }

    emit(s.copyWith(isMerging: true, mergeError: null));

    // Build the scenes payload for POST /merge.
    final scenes = <Map<String, dynamic>>[];
    for (var i = 0; i < validClips.length; i++) {
      final clip = validClips[i];
      // Gap index: the transition after clip[i] is at gap i (not used at Phase 3
      // launch, all gaps default to hardCut, but we still send the value so the
      // cloud worker can apply them in Phase 4 without a client update).
      final gapIndex = i; // transition_to_next is ignored for the last scene
      scenes.add({
        'scene_index': clip.sceneNumber,
        'trim_in': clip.trimState.inPoint,
        'trim_out': clip.trimState.outPoint,
        'transition_to_next': s.transitionAt(gapIndex).apiValue,
      });
    }

    try {
      final jobId = await apiClient.mergeClips(
        projectSlug: projectSlug,
        scenes: scenes,
      );

      // Write a Hive CE entry so the job survives app restarts.
      await jobRegistryService.register(JobRegistryEntry(
        jobId: jobId,
        type: 'merge',
        projectId: projectSlug,
        status: 'pending',
        createdAt: DateTime.now(),
      ));

      // Keep isMerging = true — the Firestore gcs_final_path listener clears it.
    } on ApiInsufficientCredits {
      // Signal the screen to show CreditsExhaustedDialog.
      final cur = state;
      if (cur is EditorLoaded) {
        emit(cur.copyWith(isMerging: false, mergeError: '__credits__'));
      }
    } catch (e) {
      final cur = state;
      if (cur is EditorLoaded) {
        emit(cur.copyWith(isMerging: false, mergeError: e.toString()));
      }
    }
  }

  // ── Download to gallery ────────────────────────────────────────────────────

  /// Downloads `final.mp4` from GCS via presigned URL and saves it to the
  /// device camera roll / gallery using [Gal.putVideo].
  Future<void> downloadToGallery() async {
    final s = state;
    if (s is! EditorLoaded) return;
    if (s.gcsExportPath == null) return;

    emit(s.copyWith(isDownloading: true, downloadProgress: 0.0));

    try {
      // 1. Obtain a fresh presigned URL for the final.mp4.
      final url =
          await apiClient.getPresignedUrl(gcsPath: s.gcsExportPath!);

      if (isClosed) return;

      // 2. Download the bytes.
      final bytes = await apiClient.downloadBytes(url);

      if (isClosed) return;

      // Update progress to 80% after download (remaining 20% = gallery save).
      final cur = state;
      if (cur is EditorLoaded) {
        emit(cur.copyWith(downloadProgress: 0.8));
      }

      // 3. Write bytes to a temporary file — Gal.putVideo requires a path.
      final tmpDir = await getTemporaryDirectory();
      final tmpPath = p.join(tmpDir.path, 'arkmask_final_$projectSlug.mp4');
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsBytes(bytes);

      // 4. Save to the device gallery.
      await Gal.putVideo(tmpPath);

      // 5. Clean up the temp file.
      try {
        await tmpFile.delete();
      } catch (_) {}

      if (isClosed) return;
      final done = state;
      if (done is EditorLoaded) {
        emit(done.copyWith(isDownloading: false, downloadProgress: 1.0));
      }
    } catch (e) {
      if (isClosed) return;
      final err = state;
      if (err is EditorLoaded) {
        emit(err.copyWith(isDownloading: false, mergeError: e.toString()));
      }
    }
  }

  // ── Error clearing ─────────────────────────────────────────────────────────

  void clearMergeError() {
    final s = state;
    if (s is EditorLoaded) {
      emit(s.copyWith(mergeError: null));
    }
  }

  void clearExportError() {
    final s = state;
    if (s is EditorLoaded) {
      emit(s.copyWith(exportError: null));
    }
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Persists the current trim and transition state.
  /// Useful when the user navigates away (called from PopScope).
  void persistCurrentTrimState() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistEditorState(s.projectSlug, s.clips, s.transitions);
  }

  /// Saves trim states and transition selections to [SharedPreferences].
  Future<void> _persistEditorState(
    String slug,
    List<ClipEntry> clips,
    Map<int, TransitionType> transitions,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'trim_state_$slug',
        jsonEncode(clips.map((c) => c.trimState.toJson()).toList()),
      );
      // Persist transitions as {gapIndex: typeName} map.
      await prefs.setString(
        'transition_state_$slug',
        jsonEncode(transitions.map((k, v) => MapEntry(k.toString(), v.name))),
      );
    } catch (_) {
      // Non-fatal — state resets to defaults on next load.
    }
  }

  Future<Map<int, ClipTrimState>> _loadSavedTrims(String slug) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('trim_state_$slug');
      if (raw == null) return {};
      final list = jsonDecode(raw) as List<dynamic>;
      return {
        for (final item in list)
          (item as Map<String, dynamic>)['sceneNumber'] as int:
              ClipTrimState.fromJson(item),
      };
    } catch (_) {
      return {};
    }
  }

  Future<Map<int, TransitionType>> _loadSavedTransitions(String slug) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('transition_state_$slug');
      if (raw == null) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final entry in map.entries)
          int.parse(entry.key):
              TransitionType.values.byName(entry.value as String),
      };
    } catch (_) {
      return {};
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<ClipEntry> _updateClipTrim(
      List<ClipEntry> clips, int index, ClipTrimState newTrim) {
    final updated = List<ClipEntry>.from(clips);
    updated[index] = clips[index].copyWith(trimState: newTrim);
    return updated;
  }

  void _hapticIfAtMin(
      {required double oldDuration, required double newDuration}) {
    const min = ClipTrimState.minDuration;
    if (oldDuration > min + 0.01 && newDuration <= min + 0.01) {
      HapticFeedback.selectionClick();
    }
  }

  @override
  Future<void> close() async {
    await _projectSub?.cancel();
    await _scenesSub?.cancel();
    for (final ctrl in _controllers.values) {
      await ctrl.dispose();
    }
    _controllers.clear();
    return super.close();
  }
}
