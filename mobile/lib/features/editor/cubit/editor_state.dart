import '../../../core/models/models.dart';

// ── ClipEntry ────────────────────────────────────────────────────────────────

/// In-memory representation of one scene's video clip in the editor.
///
/// [gcsVideoPath] is null when the scene has no generated video yet.
/// [presignedUrl] is null until the URL has been fetched from the API.
/// [totalDuration] is 0.0 for clips without video or before the duration probe
/// completes.
/// [isGenerating] is true when the Hive CE job registry has an active video
/// generation job for this scene.
class ClipEntry {
  const ClipEntry({
    required this.sceneNumber,
    this.gcsVideoPath,
    this.presignedUrl,
    required this.totalDuration,
    required this.trimState,
    this.isGenerating = false,
  });

  final int sceneNumber;

  /// GCS object path from Firestore `gcs_video_path`. Null = no video yet.
  final String? gcsVideoPath;

  /// Cached presigned URL. Null until fetched; refreshed on expiry via
  /// [EditorCubit.refreshPresignedUrl].
  final String? presignedUrl;

  /// Clip total duration in seconds. 0.0 when there is no video or the
  /// duration probe has not yet completed.
  final double totalDuration;

  final ClipTrimState trimState;

  /// True when the Hive CE job registry has an active `'video'` job for this
  /// scene — shows the pulsing "Generating…" overlay on the clip block.
  final bool isGenerating;

  bool get hasVideo => gcsVideoPath != null;
  double get trimmedDuration => trimState.trimmedDuration;

  ClipEntry copyWith({
    Object? gcsVideoPath = _sentinel,
    Object? presignedUrl = _sentinel,
    double? totalDuration,
    ClipTrimState? trimState,
    bool? isGenerating,
  }) =>
      ClipEntry(
        sceneNumber: sceneNumber,
        gcsVideoPath: identical(gcsVideoPath, _sentinel)
            ? this.gcsVideoPath
            : gcsVideoPath as String?,
        presignedUrl: identical(presignedUrl, _sentinel)
            ? this.presignedUrl
            : presignedUrl as String?,
        totalDuration: totalDuration ?? this.totalDuration,
        trimState: trimState ?? this.trimState,
        isGenerating: isGenerating ?? this.isGenerating,
      );
}

// ── States ───────────────────────────────────────────────────────────────────

sealed class EditorState {}

class EditorLoading extends EditorState {}

class EditorError extends EditorState {
  EditorError({required this.message});
  final String message;
}

class EditorLoaded extends EditorState {
  EditorLoaded({
    required this.projectSlug,
    required this.clips,
    this.selectedClipIndex,
    this.isMerging = false,
    this.isDownloading = false,
    this.downloadProgress = 0.0,
    this.mergeError,
    this.exportError,
    this.gcsExportPath,
    Map<int, TransitionType>? transitions,
  }) : transitions = transitions ?? const {};

  final String projectSlug;
  final List<ClipEntry> clips;
  final int? selectedClipIndex;

  /// True while the `POST /merge` cloud job is in progress.
  /// Cleared when the Firestore `gcs_final_path` listener fires.
  final bool isMerging;

  /// True while the final.mp4 is being downloaded to the device gallery.
  final bool isDownloading;

  final double downloadProgress;

  /// Non-null when the merge call or download fails.
  /// The sentinel value `'__credits__'` means insufficient credits → show
  /// [CreditsExhaustedDialog] instead of a generic error dialog.
  final String? mergeError;

  /// Non-merge export errors (e.g. "No video clips to export.").
  final String? exportError;

  /// GCS path for the merged `final.mp4`. Non-null once a merge job completes
  /// and the Firestore `gcs_final_path` listener fires.
  final String? gcsExportPath;

  /// Maps gap index → transition type. Gap 0 is between clips[0] and clips[1].
  /// Absent entries default to [TransitionType.hardCut].
  /// At Phase 3 launch this map is always empty (all gaps implicitly hardCut).
  final Map<int, TransitionType> transitions;

  ClipEntry? get selectedClip =>
      selectedClipIndex != null ? clips[selectedClipIndex!] : null;

  double get totalTrimmedDuration =>
      clips.fold(0.0, (sum, c) => sum + c.trimmedDuration);

  bool get hasAnyVideo => clips.any((c) => c.hasVideo);

  bool get isExportReady => gcsExportPath != null;

  /// Returns the transition for gap [gapIndex], defaulting to hard cut.
  TransitionType transitionAt(int gapIndex) =>
      transitions[gapIndex] ?? TransitionType.hardCut;

  EditorLoaded copyWith({
    List<ClipEntry>? clips,
    Object? selectedClipIndex = _sentinel,
    bool? isMerging,
    bool? isDownloading,
    double? downloadProgress,
    Object? mergeError = _sentinel,
    Object? exportError = _sentinel,
    Object? gcsExportPath = _sentinel,
    Map<int, TransitionType>? transitions,
  }) =>
      EditorLoaded(
        projectSlug: projectSlug,
        clips: clips ?? this.clips,
        selectedClipIndex: identical(selectedClipIndex, _sentinel)
            ? this.selectedClipIndex
            : selectedClipIndex as int?,
        isMerging: isMerging ?? this.isMerging,
        isDownloading: isDownloading ?? this.isDownloading,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        mergeError: identical(mergeError, _sentinel)
            ? this.mergeError
            : mergeError as String?,
        exportError: identical(exportError, _sentinel)
            ? this.exportError
            : exportError as String?,
        gcsExportPath: identical(gcsExportPath, _sentinel)
            ? this.gcsExportPath
            : gcsExportPath as String?,
        transitions: transitions ?? this.transitions,
      );
}

// Sentinel object for nullable copyWith parameters.
const Object _sentinel = Object();
