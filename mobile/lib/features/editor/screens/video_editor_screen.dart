import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:video_player/video_player.dart';

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/models/models.dart';
import '../cubit/editor_cubit.dart';
import '../cubit/editor_state.dart';

// ── Entry point ───────────────────────────────────────────────────────────────

class VideoEditorScreen extends StatelessWidget {
  const VideoEditorScreen({super.key, required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    final fileService = ArkMaskServices.of(context).fileService;
    return BlocProvider(
      create: (_) => EditorCubit(fileService: fileService)..load(projectName),
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

  @override
  void dispose() {
    // Persist trim on navigate-away.
    context.read<EditorCubit>().persistCurrentTrimState();
    _timelineScrollController.dispose();
    super.dispose();
  }

  // ── Side-effects ──────────────────────────────────────────────────────────

  void _handleStateChange(BuildContext context, EditorState state) {
    if (state is! EditorLoaded) return;

    // Export success
    if (state.exportedFilePath != null && !state.isExporting) {
      final path = state.exportedFilePath!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Export complete. Saved to your gallery.'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Play',
            onPressed: () => context.push(
              Routes.videoPlayer,
              extra: {'videoPath': path},
            ),
          ),
        ),
      );
    }

    // Export error
    if (state.exportError != null) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Export Failed'),
          content: SingleChildScrollView(
            child: Text(
              state.exportError!,
              style: AppTextStyles.monoSmall(context).copyWith(fontSize: 11),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dismiss'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                context.read<EditorCubit>()
                  ..clearExportError()
                  ..export();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
  }

  // ── AppBar helpers ────────────────────────────────────────────────────────

  Future<void> _onExportTapped(
      BuildContext context, EditorLoaded state) async {
    final cubit = context.read<EditorCubit>();
    if (state.isExporting) return;

    final exists = await cubit.exportFileExists();
    if (!context.mounted) return;

    if (exists) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Overwrite Export?'),
          content: const Text(
              'final.mp4 already exists in this project. Overwrite it?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
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
              onPressed: state.isExporting
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
        if (trailing != null) ...[trailing, const SizedBox(width: AppSpacing.s3)],
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
                onPressed: () => context
                    .read<EditorCubit>()
                    .load(widget.projectName),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final loaded = state as EditorLoaded;
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
        // Export overlay
        if (loaded.isExporting) _ExportOverlay(state: loaded),
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
                borderRadius:
                    BorderRadius.circular(AppSizing.radiusMd),
              ),
              clipBehavior: Clip.hardEdge,
              child: controller != null && controller.value.isInitialized
                  ? _VideoPreviewFrame(controller: controller)
                  : Center(
                      child: Text(
                        'Select a clip to preview',
                        style: AppTextStyles.body(context).copyWith(
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiaryLight,
                        ),
                      ),
                    ),
            ),
          ),

          // Playback controls row
          if (selectedIndex != null && controller != null)
            _PlaybackControls(
              clipIndex: selectedIndex,
              clip: state.clips[selectedIndex],
              controller: controller,
            ),

          const SizedBox(height: AppSpacing.s2),
        ],
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
            // Exported file play icon overlay
            // (shown when export is complete via exportedFilePath check
            // at higher level — kept simple here)
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
                constraints: const BoxConstraints(
                    minWidth: 36, minHeight: 36),
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
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12),
                  ),
                  child: Slider(
                    value: total > 0 ? (position / total).clamp(0.0, 1.0) : 0.0,
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
            // Scale ruler
            _ScaleRuler(clips: state.clips, pxPerSec: _pxPerSec),
            const SizedBox(height: 2),
            // Clip track
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
        // Gap index = i - 1 (gap 0 is between clips 0 and 1).
        final gapIndex = i - 1;
        children.add(_TransitionIndicator(
          width: _transitionWidth,
          gapIndex: gapIndex,
          currentType: state.transitionAt(gapIndex),
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
    // Add some space for transition indicators
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

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    // Draw tick every 5 seconds
    const tickInterval = 5.0;
    var t = 0.0;
    while (t <= totalDuration + 0.1) {
      final x = t * pxPerSec;
      canvas.drawLine(Offset(x, 8), Offset(x, 20), paint);

      final label = '${t.toInt()}s';
      textPainter.text = TextSpan(
        text: label,
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
    final width = (clip.trimmedDuration * pxPerSec).clamp(24.0, double.infinity);

    if (!clip.hasVideo) {
      return _NoVideoPlaceholder(
          sceneNumber: clip.sceneNumber,
          width: width,
          height: trackHeight);
    }

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
            // Thumbnail: first-frame via VideoPlayer (paused, muted)
            if (controller != null && controller.value.isInitialized)
              _ClipThumbnail(controller: controller),

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
                        color: Colors.black.withAlpha(180),
                        blurRadius: 3)
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
                        color: Colors.black.withAlpha(180),
                        blurRadius: 3)
                  ],
                ),
              ),
            ),

            // Left trim handle (in-point)
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

            // Right trim handle (out-point)
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
            // 50% opacity tint overlay
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
    // and the scroll view defers — allowing the drag to register correctly.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      child: Container(
        // 24 px gives a finger-sized touch target even though the visual bar
        // is only 4 px wide.
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
        color:
            isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
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
    final isDark = _isDark(context);
    final color = isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;
    final activeColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final isActive = currentType != TransitionType.hardCut;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showTransitionPicker(context),
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? LucideIcons.blend : LucideIcons.scissors,
              size: 12,
              color: isActive ? activeColor : color,
            ),
            Text(
              currentType.shortLabel,
              style: AppTextStyles.caption(context).copyWith(
                fontSize: 8,
                color: isActive ? activeColor : color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTransitionPicker(BuildContext context) async {
    final cubit = context.read<EditorCubit>();
    final isDark = _isDark(context);

    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4, AppSpacing.s4, AppSpacing.s4, AppSpacing.s2),
              child: Text(
                'Transition',
                style: AppTextStyles.h3(context),
              ),
            ),
            ...TransitionType.values.map((type) {
              final isSelected = currentType == type;
              return ListTile(
                leading: Icon(
                  _iconFor(type),
                  size: AppSizing.iconMd,
                  color: isSelected
                      ? (isDark ? AppColors.primaryDark : AppColors.primaryLight)
                      : null,
                ),
                title: Text(
                  type.label,
                  style: AppTextStyles.body(context).copyWith(
                    color: isSelected
                        ? (isDark ? AppColors.primaryDark : AppColors.primaryLight)
                        : null,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                trailing: isSelected
                    ? Icon(LucideIcons.check,
                        size: AppSizing.iconSm,
                        color: isDark
                            ? AppColors.primaryDark
                            : AppColors.primaryLight)
                    : null,
                onTap: () {
                  cubit.setTransition(gapIndex, type);
                  Navigator.pop(context);
                },
              );
            }),
            const SizedBox(height: AppSpacing.s2),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(TransitionType type) => switch (type) {
        TransitionType.hardCut => LucideIcons.scissors,
        TransitionType.fadeBlack => LucideIcons.moon,
        TransitionType.dissolve => LucideIcons.blend,
      };
}

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
        color: isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
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

// ── Export Overlay ────────────────────────────────────────────────────────────

class _ExportOverlay extends StatelessWidget {
  const _ExportOverlay({required this.state});
  final EditorLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final percent = (state.exportProgress * 100).round();
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.scrim,
        child: Center(
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(AppSpacing.s6),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.surfaceRaisedDark
                  : AppColors.surfaceRaisedLight,
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Merging clips…', style: AppTextStyles.h3(context)),
                const SizedBox(height: AppSpacing.s3),
                LinearProgressIndicator(
                  value: state.exportProgress,
                  backgroundColor: isDark
                      ? AppColors.surfaceOverlayDark
                      : AppColors.surfaceOverlayLight,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(primaryColor),
                  borderRadius:
                      BorderRadius.circular(AppSizing.radiusFull),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  '$percent%',
                  style: AppTextStyles.monoSmall(context).copyWith(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                TextButton(
                  onPressed: () =>
                      context.read<EditorCubit>().cancelExport(),
                  style: TextButton.styleFrom(
                    foregroundColor: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondaryLight,
                  ),
                  child: const Text('Cancel'),
                ),
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

/// "1:05" total-time format for AppBar.
String _formatTotal(double seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toInt();
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// "5.2s" format for clip duration / trim point labels.
String _formatSec(double seconds) => '${seconds.toStringAsFixed(1)}s';

/// "0:05.3" format for playback scrub position.
String _formatPlayback(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  final tenth = (d.inMilliseconds % 1000) ~/ 100;
  return '$m:${s.toString().padLeft(2, '0')}.$tenth';
}
