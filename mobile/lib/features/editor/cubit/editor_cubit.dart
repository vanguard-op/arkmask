import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../../core/filesystem/project_file_service.dart';
import '../../../core/models/models.dart';
import 'editor_state.dart';

/// Cubit for the Video Editor Screen (FEAT-018, FEAT-019, FEAT-021).
///
/// Responsibilities:
/// - Read project tree and initialize [VideoPlayerController]s for each clip.
/// - Persist and restore trim state via [SharedPreferences].
/// - Run FFmpeg filter_complex concat for multi-clip export.
/// - Save exported video to the device gallery via [Gal].
///
/// [VideoPlayerController]s are stored as an instance field (not in state)
/// because they are mutable, disposable, and not serializable.
class EditorCubit extends Cubit<EditorState> {
  EditorCubit({required this.fileService}) : super(EditorLoading());

  final ProjectFileService fileService;

  /// Keyed by scene number. Populated during [load]; disposed on [close].
  final Map<int, VideoPlayerController> _controllers = {};

  /// Returns the [VideoPlayerController] for the given [sceneNumber], or null
  /// if the scene has no video or the controller failed to initialize.
  VideoPlayerController? controllerFor(int sceneNumber) =>
      _controllers[sceneNumber];

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Reads the project tree, initialises video controllers, restores persisted
  /// trim states, and emits [EditorLoaded].
  Future<void> load(String projectName) async {
    emit(EditorLoading());
    try {
      final tree = await fileService.readProjectTree(projectName);
      final savedTrims = await _loadSavedTrims(projectName);

      final clips = <ClipEntry>[];

      for (final scene in tree.scenes) {
        final videoFile = fileService.videoFileForScene(scene.directoryPath);
        final hasVideo = await videoFile.exists();

        double duration = 0.0;
        if (hasVideo) {
          final ctrl = VideoPlayerController.file(videoFile);
          try {
            await ctrl.initialize();
            await ctrl.seekTo(Duration.zero);
            await ctrl.setVolume(0);
            duration = ctrl.value.duration.inMilliseconds / 1000.0;
            _controllers[scene.sceneNumber] = ctrl;
          } catch (_) {
            // Controller failed (corrupt file, unsupported codec, etc.).
            // The clip will appear without a thumbnail.
            await ctrl.dispose();
          }
        }

        // Restore saved trim if the total duration matches; otherwise default.
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

        clips.add(ClipEntry(
          sceneNumber: scene.sceneNumber,
          videoPath: hasVideo ? videoFile.path : null,
          totalDuration: duration,
          trimState: trimState,
        ));
      }

      if (!isClosed) {
        emit(EditorLoaded(
          clips: clips,
          projectDir: tree.directoryPath,
          projectName: projectName,
        ));
      }
    } catch (e) {
      if (!isClosed) emit(EditorError(message: e.toString()));
    }
  }

  // ── Selection ──────────────────────────────────────────────────────────────

  void selectClip(int? index) {
    final s = state;
    if (s is! EditorLoaded) return;
    // Deselect if tapping the already-selected clip.
    final next = s.selectedClipIndex == index ? null : index;
    emit(s.copyWith(selectedClipIndex: next));
  }

  // ── Trim ──────────────────────────────────────────────────────────────────

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

    // Haptic feedback when reaching minimum clip duration.
    _hapticIfAtMin(
      oldDuration: clip.trimState.outPoint - clip.trimState.inPoint,
      newDuration: clip.trimState.outPoint - newIn,
    );

    final updated = _updateClipTrim(s.clips, clipIndex,
        clip.trimState.copyWith(inPoint: newIn));
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

    final updated = _updateClipTrim(s.clips, clipIndex,
        clip.trimState.copyWith(outPoint: newOut));
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
    _persistTrimState(s.projectName, updated);
  }

  /// Called when a trim drag ends — persists the current trim state.
  void onTrimDragEnd() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistTrimState(s.projectName, s.clips);
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

  // ── Export ────────────────────────────────────────────────────────────────

  /// Returns true if `final.mp4` already exists in the project directory.
  Future<bool> exportFileExists() async {
    final s = state;
    if (s is! EditorLoaded) return false;
    return File(p.join(s.projectDir, 'final.mp4')).exists();
  }

  /// Runs FFmpeg filter_complex concat, saves to gallery, and emits progress.
  ///
  /// Use [checkExportFile] before calling this to ask the user about overwriting.
  Future<void> export() async {
    final s = state;
    if (s is! EditorLoaded) return;

    // Only export clips that have video files.
    final validClips =
        s.clips.where((c) => c.videoPath != null && c.totalDuration > 0).toList();

    if (validClips.isEmpty) {
      emit(s.copyWith(exportError: 'No video clips to export.'));
      return;
    }

    // Pause any playing controllers before export.
    for (final ctrl in _controllers.values) {
      if (ctrl.value.isPlaying) ctrl.pause();
    }

    emit(s.copyWith(
      isExporting: true,
      exportProgress: 0.0,
      exportError: null,
      exportedFilePath: null,
    ));

    final outputPath = p.join(s.projectDir, 'final.mp4');
    // Remove stale file so FFmpeg doesn't prompt for overwrite.
    final outFile = File(outputPath);
    if (await outFile.exists()) await outFile.delete();

    final command = _buildFfmpegCommand(validClips, outputPath);

    // Estimate total frames (30 fps assumption) for progress reporting.
    final totalSec =
        validClips.fold<double>(0.0, (sum, c) => sum + c.trimmedDuration);
    final estimatedFrames = (totalSec * 30.0).round().clamp(1, 999999);

    await FFmpegKit.executeAsync(
      command,
      (session) async {
        if (isClosed) return;
        final code = await session.getReturnCode();
        if (ReturnCode.isSuccess(code)) {
          // Attempt gallery save; non-fatal if it fails (e.g. permission denied).
          try {
            await Gal.putVideo(outputPath);
          } catch (_) {}
          if (!isClosed) {
            emit((state as EditorLoaded).copyWith(
              isExporting: false,
              exportProgress: 1.0,
              exportedFilePath: outputPath,
            ));
          }
        } else {
          final log = await session.getOutput() ?? 'Unknown FFmpeg error.';
          if (!isClosed) {
            emit((state as EditorLoaded).copyWith(
              isExporting: false,
              exportError: log,
            ));
          }
        }
      },
      null, // log callback — not needed; use statistics for progress
      (Statistics stats) {
        if (isClosed) return;
        final current = state;
        if (current is! EditorLoaded || !current.isExporting) return;
        final frames = stats.getVideoFrameNumber();
        final progress = (frames / estimatedFrames).clamp(0.0, 0.99);
        emit(current.copyWith(exportProgress: progress));
      },
    );
  }

  /// Cancels an in-progress export.
  Future<void> cancelExport() async {
    await FFmpegKit.cancel();
    final s = state;
    if (s is EditorLoaded) {
      emit(s.copyWith(isExporting: false, exportProgress: 0.0));
    }
  }

  void clearExportError() {
    final s = state;
    if (s is EditorLoaded) {
      emit(s.copyWith(exportError: null));
    }
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Persists the current trim state immediately. Useful when the user
  /// navigates away (call from PopScope / dispose).
  void persistCurrentTrimState() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistTrimState(s.projectName, s.clips);
  }

  Future<void> _persistTrimState(
      String projectName, List<ClipEntry> clips) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json =
          jsonEncode(clips.map((c) => c.trimState.toJson()).toList());
      await prefs.setString('trim_state_$projectName', json);
    } catch (_) {
      // Non-fatal — trim state will reset to defaults on next load.
    }
  }

  Future<Map<int, ClipTrimState>> _loadSavedTrims(
      String projectName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('trim_state_$projectName');
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

  // ── FFmpeg ────────────────────────────────────────────────────────────────

  String _buildFfmpegCommand(List<ClipEntry> clips, String outputPath) {
    final sb = StringBuffer();

    // Input files
    for (final clip in clips) {
      sb.write('-i "${clip.videoPath}" ');
    }

    sb.write('-filter_complex "');

    // Per-clip trim filters
    for (var i = 0; i < clips.length; i++) {
      final trim = clips[i].trimState;
      final inPt = trim.inPoint.toStringAsFixed(4);
      final outPt = trim.outPoint.toStringAsFixed(4);
      sb.write('[$i:v]trim=start=$inPt:end=$outPt,setpts=PTS-STARTPTS[v$i];');
      sb.write('[$i:a]atrim=start=$inPt:end=$outPt,asetpts=PTS-STARTPTS[a$i];');
    }

    // Concat
    final concatInputs =
        List.generate(clips.length, (i) => '[v$i][a$i]').join('');
    sb.write(
        '${concatInputs}concat=n=${clips.length}:v=1:a=1[vout][aout]" ');

    // Output
    sb.write(
        '-map [vout] -map [aout] -c:v libx264 -c:a aac -movflags +faststart ');
    sb.write('"$outputPath"');

    return sb.toString();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

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
    for (final ctrl in _controllers.values) {
      await ctrl.dispose();
    }
    _controllers.clear();
    return super.close();
  }
}
