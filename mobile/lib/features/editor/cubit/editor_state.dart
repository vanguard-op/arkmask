import '../../../core/models/models.dart';

// ── ClipEntry ────────────────────────────────────────────────────────────────

/// In-memory representation of one scene's video clip in the editor.
///
/// [videoPath] is null when the scene has no `video.mp4` yet.
/// [totalDuration] is 0.0 for clips without video.
class ClipEntry {
  ClipEntry({
    required this.sceneNumber,
    this.videoPath,
    required this.totalDuration,
    required this.trimState,
  });

  final int sceneNumber;
  final String? videoPath;
  final double totalDuration;
  final ClipTrimState trimState;

  bool get hasVideo => videoPath != null && totalDuration > 0;
  double get trimmedDuration => trimState.trimmedDuration;

  ClipEntry copyWith({ClipTrimState? trimState}) => ClipEntry(
        sceneNumber: sceneNumber,
        videoPath: videoPath,
        totalDuration: totalDuration,
        trimState: trimState ?? this.trimState,
      );
}

// ── States ───────────────────────────────────────────────────────────────────

sealed class EditorState {}

class EditorLoading extends EditorState {}

class EditorLoaded extends EditorState {
  EditorLoaded({
    required this.clips,
    required this.projectDir,
    required this.projectName,
    this.selectedClipIndex,
    this.isExporting = false,
    this.exportProgress = 0.0,
    this.exportError,
    this.exportedFilePath,
  });

  final List<ClipEntry> clips;
  final String projectDir;
  final String projectName;
  final int? selectedClipIndex;
  final bool isExporting;
  final double exportProgress;
  final String? exportError;
  final String? exportedFilePath;

  ClipEntry? get selectedClip =>
      selectedClipIndex != null ? clips[selectedClipIndex!] : null;

  double get totalTrimmedDuration =>
      clips.fold(0.0, (sum, c) => sum + c.trimmedDuration);

  EditorLoaded copyWith({
    List<ClipEntry>? clips,
    Object? selectedClipIndex = _sentinel,
    bool? isExporting,
    double? exportProgress,
    Object? exportError = _sentinel,
    Object? exportedFilePath = _sentinel,
  }) =>
      EditorLoaded(
        clips: clips ?? this.clips,
        projectDir: projectDir,
        projectName: projectName,
        selectedClipIndex: identical(selectedClipIndex, _sentinel)
            ? this.selectedClipIndex
            : selectedClipIndex as int?,
        isExporting: isExporting ?? this.isExporting,
        exportProgress: exportProgress ?? this.exportProgress,
        exportError: identical(exportError, _sentinel)
            ? this.exportError
            : exportError as String?,
        exportedFilePath: identical(exportedFilePath, _sentinel)
            ? this.exportedFilePath
            : exportedFilePath as String?,
      );
}

class EditorError extends EditorState {
  EditorError({required this.message});
  final String message;
}

// Sentinel object for nullable copyWith parameters.
const Object _sentinel = Object();
