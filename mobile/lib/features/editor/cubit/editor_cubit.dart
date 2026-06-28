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
  /// trim and transition states, and emits [EditorLoaded].
  Future<void> load(String projectName) async {
    emit(EditorLoading());
    try {
      final tree = await fileService.readProjectTree(projectName);
      final savedTrims = await _loadSavedTrims(projectName);
      final savedTransitions = await _loadSavedTransitions(projectName);

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
          transitions: savedTransitions,
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
    _persistEditorState(s.projectName, updated, s.transitions);
  }

  /// Called when a trim drag ends — persists the current trim state.
  void onTrimDragEnd() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistEditorState(s.projectName, s.clips, s.transitions);
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

  // ── Transitions ───────────────────────────────────────────────────────────

  /// Sets the transition type for the gap at [gapIndex] (0 = between clips 0
  /// and 1). Persists the selection alongside trim state.
  void setTransition(int gapIndex, TransitionType type) {
    final s = state;
    if (s is! EditorLoaded) return;
    final updated = Map<int, TransitionType>.from(s.transitions)
      ..[gapIndex] = type;
    emit(s.copyWith(transitions: updated));
    _persistEditorState(s.projectName, s.clips, updated);
  }

  // ── Export ────────────────────────────────────────────────────────────────

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

    final command = _buildFfmpegCommand(validClips, outputPath, s.transitions);

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

  /// Persists the current trim and transition state immediately.
  /// Useful when the user navigates away (called from PopScope / dispose).
  void persistCurrentTrimState() {
    final s = state;
    if (s is! EditorLoaded) return;
    _persistEditorState(s.projectName, s.clips, s.transitions);
  }

  /// Saves trim states and transition selections to [SharedPreferences].
  Future<void> _persistEditorState(
    String projectName,
    List<ClipEntry> clips,
    Map<int, TransitionType> transitions,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'trim_state_$projectName',
        jsonEncode(clips.map((c) => c.trimState.toJson()).toList()),
      );
      // Persist transitions as {gapIndex: typeName} map.
      await prefs.setString(
        'transition_state_$projectName',
        jsonEncode(transitions.map((k, v) => MapEntry(k.toString(), v.name))),
      );
    } catch (_) {
      // Non-fatal — state will reset to defaults on next load.
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

  Future<Map<int, TransitionType>> _loadSavedTransitions(
      String projectName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('transition_state_$projectName');
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

  // ── FFmpeg ────────────────────────────────────────────────────────────────

  /// Builds the FFmpeg command for the export.
  ///
  /// All three transition types work without xfade (which silently outputs
  /// black frames on AI-generated VFR clips):
  ///
  /// - **Hard Cut** — trim + concat, no filters.
  /// - **Fade to Black** — `fade=out` on clip A tail + `fade=in` on clip B
  ///   head, then concat.
  /// - **Dissolve** — the tail of clip A and the head of clip B are trimmed
  ///   into a separate overlap segment. Clip B's head is converted to RGBA and
  ///   faded in from transparent, then overlaid on top of clip A's tail with
  ///   `overlay`. The result is concatenated between clip A's body and clip B's
  ///   body, giving a true simultaneous cross-dissolve without xfade.
  String _buildFfmpegCommand(
    List<ClipEntry> clips,
    String outputPath,
    Map<int, TransitionType> transitions,
  ) {
    // Pre-compute the transition duration for every gap.
    // Clamped to 40 % of each adjacent clip so we never exceed clip length.
    final gapFd = <int, double>{};
    for (var g = 0; g < clips.length - 1; g++) {
      final type = transitions[g] ?? TransitionType.hardCut;
      if (type == TransitionType.hardCut) {
        gapFd[g] = 0.0;
      } else {
        const desired = 0.5;
        final dA = clips[g].trimmedDuration;
        final dB = clips[g + 1].trimmedDuration;
        gapFd[g] =
            [desired, dA * 0.4, dB * 0.4].reduce((a, b) => a < b ? a : b);
      }
    }

    final sb = StringBuffer();
    for (final clip in clips) {
      sb.write('-i "${clip.videoPath}" ');
    }
    sb.write('-filter_complex "');

    // Output segment labels collected for the final concat.
    final vLabels = <String>[];
    final aLabels = <String>[];
    var seg = 0; // increments for every output segment

    for (var i = 0; i < clips.length; i++) {
      final trim   = clips[i].trimState;
      final inPt   = trim.inPoint;
      final outPt  = trim.outPoint;

      final prevType = i > 0             ? (transitions[i - 1] ?? TransitionType.hardCut) : TransitionType.hardCut;
      final nextType = i < clips.length - 1 ? (transitions[i]   ?? TransitionType.hardCut) : TransitionType.hardCut;

      final prevFd = i > 0             ? gapFd[i - 1]! : 0.0;
      final nextFd = i < clips.length - 1 ? gapFd[i]!   : 0.0;

      // Body of this clip. Dissolve overlaps "consume" the ends, so shrink.
      final bodyIn  = inPt  + (prevType == TransitionType.dissolve ? prevFd : 0.0);
      final bodyOut = outPt - (nextType == TransitionType.dissolve ? nextFd : 0.0);

      // Fade-to-black fades on the body (dissolve fades live in the blend seg).
      final fadeInDur  = prevType == TransitionType.fadeBlack ? prevFd : 0.0;
      final fadeOutDur = nextType == TransitionType.fadeBlack ? nextFd : 0.0;

      // ── Body segment ──────────────────────────────────────────────────────
      if (bodyOut > bodyIn + 0.001) {
        final bodyDur = bodyOut - bodyIn;
        final vl = 's${seg}v';
        final al = 's${seg}a';
        final inS  = bodyIn.toStringAsFixed(4);
        final outS = bodyOut.toStringAsFixed(4);

        final vFadeIn  = fadeInDur > 0
            ? ',fade=t=in:st=0:d=${fadeInDur.toStringAsFixed(4)}'   : '';
        final foSt     = (bodyDur - fadeOutDur).toStringAsFixed(4);
        final vFadeOut = fadeOutDur > 0
            ? ',fade=t=out:st=$foSt:d=${fadeOutDur.toStringAsFixed(4)}' : '';

        sb.write('[$i:v]trim=start=$inS:end=$outS,setpts=PTS-STARTPTS'
            '$vFadeIn$vFadeOut,format=yuv420p[$vl];');

        final aFadeIn  = fadeInDur > 0
            ? ',afade=t=in:st=0:d=${fadeInDur.toStringAsFixed(4)}'   : '';
        final aFadeOut = fadeOutDur > 0
            ? ',afade=t=out:st=$foSt:d=${fadeOutDur.toStringAsFixed(4)}' : '';

        sb.write('[$i:a]atrim=start=$inS:end=$outS,asetpts=PTS-STARTPTS'
            '$aFadeIn$aFadeOut[$al];');

        vLabels.add('[$vl]');
        aLabels.add('[$al]');
        seg++;
      }

      // ── Dissolve segment (inserted between clip[i] body and clip[i+1] body) ─
      // Overlay B (fading in from transparent) on top of A for the overlap
      // duration — a true simultaneous cross-dissolve without xfade.
      if (nextType == TransitionType.dissolve && i < clips.length - 1) {
        final fd          = nextFd;
        final fdS         = fd.toStringAsFixed(4);
        final nextTrimSt  = clips[i + 1].trimState;
        final tailInS     = (outPt - fd).toStringAsFixed(4);
        final tailOutS    = outPt.toStringAsFixed(4);
        final headInS     = nextTrimSt.inPoint.toStringAsFixed(4);
        final headOutS    = (nextTrimSt.inPoint + fd).toStringAsFixed(4);
        final vl = 's${seg}v';
        final al = 's${seg}a';

        // Video: A_tail at yuv420p (base) + B_head fading in as rgba (overlay).
        // fps=30 normalises both streams to the same frame rate so overlay
        // receives matching frame counts over the overlap duration.
        sb.write('[$i:v]trim=start=$tailInS:end=$tailOutS,setpts=PTS-STARTPTS,'
            'fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p[dv${seg}base];');
        sb.write('[${i + 1}:v]trim=start=$headInS:end=$headOutS,setpts=PTS-STARTPTS,'
            'fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=rgba,'
            'fade=t=in:st=0:d=$fdS:alpha=1[dv${seg}top];');
        sb.write('[dv${seg}base][dv${seg}top]overlay=format=auto,format=yuv420p[$vl];');

        // Audio: A_tail fades out, B_head fades in, amix combines them.
        sb.write('[$i:a]atrim=start=$tailInS:end=$tailOutS,asetpts=PTS-STARTPTS,'
            'afade=t=out:st=0:d=$fdS[da${seg}a];');
        sb.write('[${i + 1}:a]atrim=start=$headInS:end=$headOutS,asetpts=PTS-STARTPTS,'
            'afade=t=in:st=0:d=$fdS[da${seg}b];');
        sb.write('[da${seg}a][da${seg}b]amix=inputs=2:normalize=0:duration=longest[$al];');

        vLabels.add('[$vl]');
        aLabels.add('[$al]');
        seg++;
      }
    }

    // Concat all collected segments — same proven path as hard-cut export.
    final n     = vLabels.length;
    final pairs = List.generate(n, (k) => '${vLabels[k]}${aLabels[k]}').join('');
    sb.write('${pairs}concat=n=$n:v=1:a=1[vout][aout]" ');
    // CRF 18 — near-source quality (default CRF 23 is noticeably softer than
    // the high-bitrate clips produced by AI video generators).
    // preset=fast balances encode speed vs compression on mobile hardware.
    sb.write('-map [vout] -map [aout] '
        '-c:v libx264 -crf 18 -preset fast '
        '-c:a aac -b:a 192k '
        '-movflags +faststart ');
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
