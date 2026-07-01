import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:video_player/video_player.dart';

import '../../../app.dart';
import '../../../core/models/models.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';
import '../cubit/editor_cubit.dart';
import '../cubit/editor_state.dart';

// ── Entry point ───────────────────────────────────────────────────────────────

class VideoEditorScreen extends StatelessWidget {
  const VideoEditorScreen({super.key, required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => EditorCubit(
        projectSlug: projectName,
        apiClient: services.apiClient,
        jobRegistryService: services.jobRegistryService,
      )..load(),
      child: _VideoEditorView(projectName: projectName),
    );
  }
}

// ── Main view ─────────────────────────────────────────────────────────────────

class _VideoEditorView extends StatefulWidget {
  const _VideoEditorView({required this.projectName});
  final String projectName;

  @override
  State<_VideoEditorView> createState() => _VideoEditorViewState();
}

class _VideoEditorViewState extends State<_VideoEditorView> {
  final _timelineScrollController = ScrollController();

  // Tracks the previous gcsExportPath to detect "merge just completed".
  String? _lastExportPath;

  @override
  void dispose() {
    context.read<EditorCubit>().persistCurrentTrimState();
    _timelineScrollController.dispose();
    super.dispose();
  }

  // ── Side-effects ──────────────────────────────────────────────────────────

  void _handleStateChange(BuildContext context, EditorState state) {
    if (state is! EditorLoaded) return;

    // ── Merge just completed (gcs_final_path became non-null) ───────────────
    if (state.gcsExportPath != null &&
        !state.isMerging &&
        _lastExportPath != state.gcsExportPath) {
      _lastExportPath = state.gcsExportPath;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Export ready.'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Download to Camera Roll',
            onPressed: () => context.read<EditorCubit>().downloadToGallery(),
          ),
        ),
      );
    }

    // ── Download completed ───────────────────────────────────────────────────
    if (!state.isDownloading && state.downloadProgress >= 1.0) {
      final exportPath = state.gcsExportPath;
      if (exportPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Saved to your gallery.'),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Play',
              onPressed: () async {
                // Fetch a presigned URL for the player.
                final cubit = context.read<EditorCubit>();
                try {
                  final url = await cubit.apiClient
                      .getPresignedUrl(gcsPath: exportPath);
                  if (context.mounted) {
                    context.push(Routes.videoPlayer, extra: {'videoPath': url});
                  }
                } catch (_) {}
              },
            ),
          ),
        );
      }
    }

    // ── Merge error ──────────────────────────────────────────────────────────
    if (state.mergeError != null) {
      final error = state.mergeError!;
      context.read<EditorCubit>().clearMergeError();

      if (error == '__credits__') {
        showCreditsExhaustedDialog(context);
      } else {
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Export Failed'),
            content: SingleChildScrollView(
              child: Text(
                error,
                style: AppTextStyles.monoSmall(context)
                    .copyWith(fontSize: 11),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.read<EditorCubit>().export();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
    }

    // ── Non-merge export error (e.g. "No video clips") ───────────────────────
    if (state.exportError != null) {
      final error = state.exportError!;
      context.read<EditorCubit>().clearExportError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Export button handler ─────────────────────────────────────────────────

  Future<void> _onExportTapped(
      BuildContext context, EditorLoaded state) async {
    final cubit = context.read<EditorCubit>();
    if (state.isMerging) return;

    // If a previous export exists, ask for confirmation before overwriting.
    if (state.isExportReady) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Replace existing export?'),
          content: const Text(
              'A merged video already exists in GCS. Replace it?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    cubit.export();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, _) =>
          context.read<EditorCubit>().persistCurrentTrimState(),
      child: BlocConsumer<EditorCubit, EditorState>(
        listener: _handleStateChange,
        builder: (context, state) {
          return Scaffold(
            backgroundColor: _surfaceBase(context),
            appBar: _buildAppBar(context, state),
            body: _buildBody(context, state),
          );
        },
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context, EditorState state) {
    final isDark = _isDark(context);

    Widget? trailing;
    if (state is EditorLoaded) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_formatTotal(state.totalTrimmedDuration)} total',
            style: AppTextStyles.caption(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          SizedBox(
            height: AppSizing.buttonSm,
            child: ElevatedButton(
              onPressed: (!state.hasAnyVideo || state.isMerging)
                  ? null
                  : () => _onExportTapped(context, state),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s3, vertical: 0),
                textStyle: AppTextStyles.caption(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              child: const Text('Export'),
            ),
          ),
        ],
      );
    }

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () => context.pop(),
      ),
      title: Text('Video Editor', style: AppTextStyles.h2(context)),
      actions: [
        if (trailing != null) ...[
          trailing,
          const SizedBox(width: AppSpacing.s3),
        ],
      ],
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, EditorState state) {
    if (state is EditorLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state is EditorError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.alertCircle,
                  size: AppSizing.iconLg,
                  color: _isDark(context)
                      ? AppColors.errorDark
                      : AppColors.errorLight),
              const SizedBox(height: AppSpacing.s3),
              Text(state.message, style: AppTextStyles.body(context)),
              const SizedBox(height: AppSpacing.s4),
              ElevatedButton(
                onPressed: () => context.read<EditorCubit>().load(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final loaded = state as EditorLoaded;

    // Empty state — no scenes have video yet.
    if (!loaded.hasAnyVideo && loaded.clips.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.film,
                  size: AppSizing.iconLg,
                  color: _isDark(context)
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiaryLight),
              const SizedBox(height: AppSpacing.s3),
              Text('No scene videos yet.',
                  style: AppTextStyles.h3(context)),
              const SizedBox(height: AppSpacing.s2),
              Text(
                'Generate videos for each scene to begin editing.',
                style: AppTextStyles.body(context).copyWith(
                  color: _isDark(context)
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        Column(
          children: [
            // Zone 1: Preview player (~35% screen height)
            _PreviewZone(state: loaded),
            // Zone 2: Timeline
            _TimelineZone(
              state: loaded,
              scrollController: _timelineScrollController,
            ),
            // Zone 3: Clip detail panel (animated)
            _ClipDetailPanel(state: loaded),
          ],
        ),
        // Full-screen merge overlay while cloud job runs.
        if (loaded.isMerging) const _MergeOverlay(),
      ],
    );
  }
}

// ── Zone 1: Preview Player ────────────────────────────────────────────────────

class _PreviewZone extends StatelessWidget {
  const _PreviewZone({required this.state});
  final EditorLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final selectedIndex = state.selectedClipIndex;
    final selectedClip = state.selectedClip;
    final controller = selectedClip != null
        ? context.read<EditorCubit>().controllerFor(selectedClip.sceneNumber)
        : null;

    return Container(
      color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 16:9 video frame
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              margin: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.surfaceSunkenDark
                    : AppColors.surfaceSunkenLight,
                border: Border.all(
                  color: isDark
                      ? AppColors.borderSubtleDark
                      : AppColors.borderSubtleLight,
                ),
                borderRadius: BorderRadius.circular(AppSizing.radiusMd),
              ),
              clipBehavior: Clip.hardEdge,
              child: _previewContent(context, controller, isDark),
            ),
          ),

          // Playback controls — only when a clip is selected and has a controller.
          if (selectedIndex != null && controller != null)
            _PlaybackControls(
              clipIndex: selectedIndex,
              clip: state.clips[selectedIndex],
              controller: controller,
            ),

          // Download button — shown when export is ready and no clip is selected.
          if (state.isExportReady &&
              !state.isMerging &&
              selectedIndex == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4, 0, AppSpacing.s4, AppSpacing.s3),
              child: state.isDownloading
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          value: state.downloadProgress == 0.0
                              ? null
                              : state.downloadProgress,
                          backgroundColor: isDark
                              ? AppColors.surfaceOverlayDark
                              : AppColors.surfaceOverlayLight,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isDark
                                ? AppColors.primaryDark
                                : AppColors.primaryLight,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        Text(
                          'Saving to gallery…',
                          style: AppTextStyles.caption(context).copyWith(
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () =>
                            context.read<EditorCubit>().downloadToGallery(),
                        icon: const Icon(LucideIcons.download, size: 16),
                        label: const Text('Download to Camera Roll'),
                      ),
                    ),
            ),

          const SizedBox(height: AppSpacing.s2),
        ],
      ),
    );
  }

  Widget _previewContent(
      BuildContext context, VideoPlayerController? controller, bool isDark) {
    if (controller != null && controller.value.isInitialized) {
      return _VideoPreviewFrame(controller: controller);
    }

    // Export ready but no clip selected — show download prompt in the player
    // area as a placeholder (the button is rendered below the player).
    if (state.isExportReady && state.selectedClipIndex == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.checkCircle,
                size: AppSizing.iconLg,
                color: isDark ? AppColors.primaryDark : AppColors.primaryLight),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Export ready',
              style: AppTextStyles.body(context).copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Text(
        'Select a clip to preview',
        style: AppTextStyles.body(context).copyWith(
          color: isDark
              ? AppColors.textTertiaryDark
              : AppColors.textTertiaryLight,
        ),
      ),
    );
  }
}

class _VideoPreviewFrame extends StatelessWidget {
  const _VideoPreviewFrame({required this.controller});
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (_, value, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: value.size.width,
                height: value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.clipIndex,
    required this.clip,
    required this.controller,
  });

  final int clipIndex;
  final ClipEntry clip;
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (_, value, _) {
        final position = value.position.inMilliseconds / 1000.0;
        final total = clip.totalDuration;
        final isPlaying = value.isPlaying;

        return Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3, vertical: AppSpacing.s1),
          child: Row(
            children: [
              // Play/Pause
              IconButton(
                icon: Icon(
                  isPlaying ? LucideIcons.pause : LucideIcons.play,
                  color: primaryColor,
                  size: AppSizing.iconMd,
                ),
                onPressed: () =>
                    context.read<EditorCubit>().togglePlayPause(clipIndex),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
              // Current time
              Text(
                _formatPlayback(value.position),
                style: AppTextStyles.monoSmall(context).copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              // Scrub slider
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: primaryColor,
                    inactiveTrackColor: isDark
                        ? AppColors.surfaceOverlayDark
                        : AppColors.surfaceOverlayLight,
                    thumbColor: primaryColor,
                    overlayColor: primaryColor.withAlpha(30),
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: total > 0
                        ? (position / total).clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: total > 0
                        ? (v) => context
                            .read<EditorCubit>()
                            .seekPreview(clipIndex, v * total)
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              // Total time
              Text(
                _formatPlayback(
                    Duration(milliseconds: (total * 1000).round())),
                style: AppTextStyles.monoSmall(context).copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Zone 2: Timeline ──────────────────────────────────────────────────────────

class _TimelineZone extends StatelessWidget {
  const _TimelineZone({
    required this.state,
    required this.scrollController,
  });

  final EditorLoaded state;
  final ScrollController scrollController;

  static const double _pxPerSec = 24.0;
  static const double _trackHeight = 72.0;
  static const double _rulerHeight = 24.0;
  static const double _transitionWidth = 20.0;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);

    return Container(
      height: _rulerHeight + _trackHeight + AppSpacing.s3 * 2,
      color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
      child: SingleChildScrollView(
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ScaleRuler(clips: state.clips, pxPerSec: _pxPerSec),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildTrackChildren(context),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTrackChildren(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < state.clips.length; i++) {
      if (i > 0) {
        // Transition indicator between clips.
        // Phase 3: always renders as non-interactive "Cut" diamond.
        children.add(_TransitionIndicator(
          width: _transitionWidth,
          gapIndex: i - 1,
          currentType: state.transitionAt(i - 1),
        ));
      }
      children.add(_ClipBlock(
        clip: state.clips[i],
        clipIndex: i,
        isSelected: state.selectedClipIndex == i,
        pxPerSec: _pxPerSec,
        trackHeight: _trackHeight,
      ));
    }
    return children;
  }
}

class _ScaleRuler extends StatelessWidget {
  const _ScaleRuler({required this.clips, required this.pxPerSec});

  final List<ClipEntry> clips;
  final double pxPerSec;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final totalDuration =
        clips.fold<double>(0.0, (sum, c) => sum + c.trimmedDuration);
    final totalWidth = totalDuration * pxPerSec +
        (clips.length > 1 ? (clips.length - 1) * 20.0 : 0);

    return SizedBox(
      height: 20,
      width: totalWidth,
      child: CustomPaint(
        painter: _RulerPainter(
          totalDuration: totalDuration,
          pxPerSec: pxPerSec,
          color: isDark
              ? AppColors.textTertiaryDark
              : AppColors.textTertiaryLight,
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.totalDuration,
    required this.pxPerSec,
    required this.color,
  });

  final double totalDuration;
  final double pxPerSec;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    const tickInterval = 5.0;
    var t = 0.0;
    while (t <= totalDuration + 0.1) {
      final x = t * pxPerSec;
      canvas.drawLine(Offset(x, 8), Offset(x, 20), paint);

      textPainter.text = TextSpan(
        text: '${t.toInt()}s',
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x + 2, 0));

      t += tickInterval;
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.totalDuration != totalDuration || old.color != color;
}

class _ClipBlock extends StatelessWidget {
  const _ClipBlock({
    required this.clip,
    required this.clipIndex,
    required this.isSelected,
    required this.pxPerSec,
    required this.trackHeight,
  });

  final ClipEntry clip;
  final int clipIndex;
  final bool isSelected;
  final double pxPerSec;
  final double trackHeight;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    // Use a minimum of 60px for clips with no duration yet.
    final effectiveDuration = clip.trimmedDuration > 0 ? clip.trimmedDuration : 2.5;
    final width = (effectiveDuration * pxPerSec).clamp(60.0, double.infinity);

    // ── Generating overlay ─────────────────────────────────────────────────
    if (clip.isGenerating) {
      return _GeneratingClipBlock(
        sceneNumber: clip.sceneNumber,
        width: width,
        height: trackHeight,
      );
    }

    // ── No video placeholder ──────────────────────────────────────────────
    if (!clip.hasVideo) {
      return _NoVideoPlaceholder(
          sceneNumber: clip.sceneNumber, width: width, height: trackHeight);
    }

    // ── Video clip block ──────────────────────────────────────────────────
    final controller =
        context.read<EditorCubit>().controllerFor(clip.sceneNumber);
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return GestureDetector(
      onTap: () => context.read<EditorCubit>().selectClip(clipIndex),
      child: Container(
        width: width,
        height: trackHeight,
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? AppColors.primarySubtleDark
                  : AppColors.primarySubtleLight)
              : (isDark
                  ? AppColors.surfaceOverlayDark
                  : AppColors.surfaceOverlayLight),
          border: isSelected
              ? Border.all(
                  color: isDark
                      ? AppColors.borderStrongDark
                      : AppColors.borderStrongLight,
                  width: 2,
                )
              : null,
          borderRadius: BorderRadius.circular(AppSizing.radiusXs),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail: first-frame via VideoPlayer (paused at frame 0).
            if (controller != null && controller.value.isInitialized)
              _ClipThumbnail(controller: controller)
            else if (clip.presignedUrl != null)
              // URL fetched but controller not yet initialised — shimmer.
              _ShimmerPlaceholder(width: width, height: trackHeight)
            else
              // URL still being fetched — shimmer.
              _ShimmerPlaceholder(width: width, height: trackHeight),

            // Top-left: Scene label
            Positioned(
              top: 4,
              left: isSelected ? 9 : 6,
              child: Text(
                'Scene ${clip.sceneNumber}',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                  shadows: [
                    Shadow(
                        color: Colors.black.withAlpha(180), blurRadius: 3)
                  ],
                ),
              ),
            ),

            // Top-right: Duration
            Positioned(
              top: 4,
              right: isSelected ? 9 : 6,
              child: Text(
                _formatSec(clip.trimmedDuration),
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                  shadows: [
                    Shadow(
                        color: Colors.black.withAlpha(180), blurRadius: 3)
                  ],
                ),
              ),
            ),

            // Left trim handle (in-point) — visible when selected.
            if (isSelected)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _TrimHandle(
                  color: primaryColor,
                  onDragUpdate: (details) => context
                      .read<EditorCubit>()
                      .updateInPoint(clipIndex, details.delta.dx),
                  onDragEnd: (_) =>
                      context.read<EditorCubit>().onTrimDragEnd(),
                ),
              ),

            // Right trim handle (out-point) — visible when selected.
            if (isSelected)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _TrimHandle(
                  color: primaryColor,
                  onDragUpdate: (details) => context
                      .read<EditorCubit>()
                      .updateOutPoint(clipIndex, details.delta.dx),
                  onDragEnd: (_) =>
                      context.read<EditorCubit>().onTrimDragEnd(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shimmer-style placeholder shown while the presigned URL is being fetched
/// or while the VideoPlayerController is initialising.
class _ShimmerPlaceholder extends StatelessWidget {
  const _ShimmerPlaceholder({required this.width, required this.height});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    return Container(
      width: width,
      height: height,
      color: isDark
          ? AppColors.surfaceOverlayDark.withAlpha(120)
          : AppColors.surfaceOverlayLight.withAlpha(120),
    );
  }
}

/// Pulsing "Generating…" overlay shown when the scene is being generated.
class _GeneratingClipBlock extends StatefulWidget {
  const _GeneratingClipBlock({
    required this.sceneNumber,
    required this.width,
    required this.height,
  });
  final int sceneNumber;
  final double width;
  final double height;

  @override
  State<_GeneratingClipBlock> createState() => _GeneratingClipBlockState();
}

class _GeneratingClipBlockState extends State<_GeneratingClipBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final blue = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: blue.withAlpha((_pulse.value * 60 + 20).round()),
          borderRadius: BorderRadius.circular(AppSizing.radiusXs),
          border: Border.all(color: blue.withAlpha(120)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.loader, size: 16, color: blue),
            const SizedBox(height: 4),
            Text(
              'Scene ${widget.sceneNumber}',
              style: AppTextStyles.caption(context)
                  .copyWith(color: blue, fontSize: 9),
            ),
            Text(
              'Generating…',
              style: AppTextStyles.caption(context)
                  .copyWith(color: blue, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipThumbnail extends StatelessWidget {
  const _ClipThumbnail({required this.controller});
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (_, value, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: value.size.width,
                height: value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
            // 50% opacity tint overlay per spec.
            ColoredBox(color: Colors.black.withAlpha(128)),
          ],
        );
      },
    );
  }
}

class _TrimHandle extends StatelessWidget {
  const _TrimHandle({
    required this.color,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final Color color;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    // Uses onHorizontalDragUpdate (not onPanUpdate) so this recognizer competes
    // in the same gesture category as the parent SingleChildScrollView. Flutter's
    // arena resolves ties depth-first, so the deeper widget (this handle) wins
    // and the scroll view defers — allowing drag to register correctly.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      child: Container(
        // 24px gives a finger-sized touch target even though the visual bar is 4px.
        width: 24,
        height: double.infinity,
        alignment: Alignment.center,
        child: Container(
          width: 4,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _NoVideoPlaceholder extends StatelessWidget {
  const _NoVideoPlaceholder({
    required this.sceneNumber,
    required this.width,
    required this.height,
  });

  final int sceneNumber;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    return Container(
      width: width.clamp(60.0, double.infinity),
      height: height,
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.surfaceSunkenDark
            : AppColors.surfaceSunkenLight,
        border: Border.all(
          color: (isDark
                  ? AppColors.borderSubtleDark
                  : AppColors.borderSubtleLight)
              .withAlpha(80),
          style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(AppSizing.radiusXs),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.videoOff,
            size: AppSizing.iconSm,
            color: isDark
                ? AppColors.textTertiaryDark
                : AppColors.textTertiaryLight,
          ),
          const SizedBox(height: 2),
          Text(
            'Scene $sceneNumber',
            style: AppTextStyles.caption(context).copyWith(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiaryLight,
              fontSize: 9,
            ),
          ),
          Text(
            'No video',
            style: AppTextStyles.caption(context).copyWith(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable transition indicator between clips (FEAT-020).
///
/// Opens a modal bottom sheet picker on tap. [gapIndex] is the index of the
/// gap: gap between clip[i] and clip[i+1] has gapIndex == i.
class _TransitionIndicator extends StatelessWidget {
  const _TransitionIndicator({
    required this.width,
    required this.gapIndex,
    required this.currentType,
  });

  final double width;
  final int gapIndex;
  final TransitionType currentType;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showTransitionPicker(context, gapIndex, currentType),
      child: _TransitionIndicatorVisual(
        width: width,
        currentType: currentType,
      ),
    );
  }
}

/// Pure-visual part of the transition indicator (icon + short label).
///
/// Non-hardCut transitions are highlighted in primary color to signal
/// that a non-default effect is active.
class _TransitionIndicatorVisual extends StatelessWidget {
  const _TransitionIndicatorVisual({
    required this.width,
    required this.currentType,
  });

  final double width;
  final TransitionType currentType;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);

    // Hard Cut uses a muted tertiary color; any other transition uses primary
    // color to draw the editor's eye to the active effect.
    final isDefault = currentType == TransitionType.hardCut;
    final color = isDefault
        ? (isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight)
        : (isDark ? AppColors.primaryDark : AppColors.primaryLight);

    final icon = switch (currentType) {
      TransitionType.hardCut => LucideIcons.scissors,
      TransitionType.fadeBlack => LucideIcons.sun,
      TransitionType.dissolve => LucideIcons.layers,
    };

    return SizedBox(
      width: width,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: color),
          Text(
            currentType.shortLabel,
            style: AppTextStyles.caption(context).copyWith(
              fontSize: 8,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the transition picker bottom sheet for the gap at [gapIndex].
void _showTransitionPicker(
    BuildContext context, int gapIndex, TransitionType current) {
  // Capture the cubit before the async showModalBottomSheet call so we can
  // call setTransition even if the surrounding widget is unmounted mid-flight.
  final cubit = context.read<EditorCubit>();
  final isDark = _isDark(context);

  showModalBottomSheet<void>(
    context: context,
    backgroundColor:
        isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppSizing.radiusLg),
      ),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4, AppSpacing.s4, AppSpacing.s4, AppSpacing.s2),
              child: Text('Transition', style: AppTextStyles.h3(sheetContext)),
            ),
            // One ListTile per TransitionType value.
            for (final type in TransitionType.values)
              ListTile(
                leading: Icon(_iconForTransition(type)),
                title: Text(type.label),
                // Check mark only on the currently-active transition.
                trailing: type == current
                    ? const Icon(LucideIcons.check)
                    : null,
                onTap: () {
                  cubit.setTransition(gapIndex, type);
                  Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: AppSpacing.s2),
          ],
        ),
      );
    },
  );
}

/// Maps a [TransitionType] to its Lucide icon.
IconData _iconForTransition(TransitionType type) => switch (type) {
      TransitionType.hardCut => LucideIcons.scissors,
      TransitionType.fadeBlack => LucideIcons.sun,
      TransitionType.dissolve => LucideIcons.layers,
    };

// ── Zone 3: Clip Detail Panel ─────────────────────────────────────────────────

class _ClipDetailPanel extends StatelessWidget {
  const _ClipDetailPanel({required this.state});
  final EditorLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final clip = state.selectedClip;
    final isVisible = clip != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      height: isVisible ? 96 : 0,
      decoration: BoxDecoration(
        color:
            isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
        border: Border(
          top: BorderSide(
            color: isDark
                ? AppColors.borderSubtleDark
                : AppColors.borderSubtleLight,
          ),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: isVisible
          ? Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Scene ${clip.sceneNumber}',
                        style: AppTextStyles.h3(context),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => context.read<EditorCubit>().resetTrim(
                              state.selectedClipIndex!,
                            ),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight,
                        ),
                        child: const Text('Reset Trim'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Row(
                    children: [
                      Text(
                        'In: ${_formatSec(clip.trimState.inPoint)}  '
                        'Out: ${_formatSec(clip.trimState.outPoint)}',
                        style: AppTextStyles.monoSmall(context),
                      ),
                      const SizedBox(width: AppSpacing.s4),
                      Text(
                        'Duration: ${_formatSec(clip.trimmedDuration)}',
                        style: AppTextStyles.monoSmall(context).copyWith(
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

// ── Merge Overlay (cloud job in progress) ─────────────────────────────────────

class _MergeOverlay extends StatelessWidget {
  const _MergeOverlay();

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Positioned.fill(
      child: ColoredBox(
        // surface-base at 90% opacity per spec.
        color: (isDark ? AppColors.surfaceBaseDark : AppColors.surfaceBaseLight)
            .withAlpha(229),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Merging in cloud…', style: AppTextStyles.h2(context)),
                const SizedBox(height: AppSpacing.s4),
                LinearProgressIndicator(
                  // Indeterminate — cloud job has no progress stream.
                  backgroundColor: isDark
                      ? AppColors.surfaceOverlayDark
                      : AppColors.surfaceOverlayLight,
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                  borderRadius:
                      BorderRadius.circular(AppSizing.radiusFull),
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(
                  'This may take a few minutes.',
                  style: AppTextStyles.body(context).copyWith(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondaryLight,
                  ),
                ),
                // No cancel button — cloud job cannot be cancelled from client.
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _surfaceBase(BuildContext context) => _isDark(context)
    ? AppColors.surfaceBaseDark
    : AppColors.surfaceBaseLight;

/// "1:05" total-time format for the AppBar duration label.
String _formatTotal(double seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toInt();
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// "5.2s" format for clip duration / trim point labels.
String _formatSec(double seconds) => '${seconds.toStringAsFixed(1)}s';

/// "0:05.3" format for the playback scrub position.
String _formatPlayback(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  final tenth = (d.inMilliseconds % 1000) ~/ 100;
  return '$m:${s.toString().padLeft(2, '0')}.$tenth';
}
