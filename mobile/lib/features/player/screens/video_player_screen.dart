import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Fullscreen in-app video player (FEAT-026).
///
/// Accepts a [videoPath] (absolute filesystem path) and renders standard
/// playback controls: play/pause, scrub bar, and current/total time display.
/// Supports both scene `video.mp4` files and the exported `final.mp4`.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    this.title,
  });

  /// Absolute path to the video file on device.
  final String videoPath;

  /// Optional title shown in the AppBar (e.g. "Scene 3" or "final.mp4").
  final String? title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _controlsVisible = true;

  // Auto-hide controls after 3 seconds of inactivity.
  static const _controlsHideDuration = Duration(seconds: 3);
  DateTime _lastInteraction = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initController();
    // Keep screen awake while video player is open.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _initController() async {
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (mounted) setState(() => _hasError = true);
      return;
    }

    _controller = VideoPlayerController.file(file);
    try {
      await _controller.initialize();
      _controller.addListener(_onVideoUpdate);
      if (mounted) {
        setState(() => _isInitialized = true);
        _controller.play();
        _scheduleControlsHide();
      }
    } catch (_) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  void _onVideoUpdate() {
    if (mounted) setState(() {});

    // Loop: replay from start when video reaches the end.
    if (_controller.value.position >= _controller.value.duration &&
        _controller.value.duration > Duration.zero) {
      _controller.seekTo(Duration.zero);
      _controller.pause();
    }
  }

  /// Resets the auto-hide timer whenever the user interacts.
  void _onUserInteraction() {
    _lastInteraction = DateTime.now();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      _scheduleControlsHide();
    }
  }

  void _scheduleControlsHide() {
    Future.delayed(_controlsHideDuration, () {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(_lastInteraction);
      if (elapsed >= _controlsHideDuration && _controller.value.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _togglePlayPause() {
    _onUserInteraction();
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
      _scheduleControlsHide();
    }
  }

  @override
  void dispose() {
    if (_isInitialized) {
      _controller.removeListener(_onVideoUpdate);
      _controller.dispose();
    }
    // Restore system UI when leaving the player.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Video surface ──────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!_isInitialized) return;
              if (_controlsVisible) {
                _togglePlayPause();
              } else {
                _onUserInteraction();
              }
            },
            child: Center(
              child: _isInitialized
                  ? AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    )
                  : _hasError
                      ? _ErrorView(videoPath: widget.videoPath)
                      : const _LoadingView(),
            ),
          ),

          // ── Controls overlay ───────────────────────────────────────────────
          if (_isInitialized)
            AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _ControlsOverlay(
                  controller: _controller,
                  title: widget.title,
                  isDark: isDark,
                  onPlayPause: _togglePlayPause,
                  onSeek: (pos) {
                    _onUserInteraction();
                    _controller.seekTo(pos);
                  },
                  onBack: () => Navigator.of(context).pop(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Controls overlay ──────────────────────────────────────────────────────────

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.title,
    required this.isDark,
    required this.onPlayPause,
    required this.onSeek,
    required this.onBack,
  });

  final VideoPlayerController controller;
  final String? title;
  final bool isDark;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final position = value.position;
    final duration = value.duration;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0xCC000000),
          ],
          stops: [0.0, 0.25, 0.75, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────────────
            Row(
              children: [
                IconButton(
                  icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
                  onPressed: onBack,
                ),
                if (title != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      title!,
                      style: AppTextStyles.body(context)
                          .copyWith(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            const Spacer(),
            // ── Bottom bar ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Time labels
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(position),
                        style: AppTextStyles.caption(context)
                            .copyWith(color: Colors.white70),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: AppTextStyles.caption(context)
                            .copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
                  // Scrub bar
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.0,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      value: duration.inMilliseconds > 0
                          ? position.inMilliseconds /
                              duration.inMilliseconds
                          : 0.0,
                      onChanged: duration.inMilliseconds > 0
                          ? (v) => onSeek(
                                Duration(
                                  milliseconds:
                                      (v * duration.inMilliseconds).round(),
                                ),
                              )
                          : null,
                    ),
                  ),
                  // Play/pause button (centred row)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(
                            value.isPlaying
                                ? LucideIcons.pause
                                : LucideIcons.play,
                            color: Colors.white,
                            size: AppSizing.iconLg,
                          ),
                          onPressed: onPlayPause,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── Supporting views ──────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: Colors.white54),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.videoPath});
  final String videoPath;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.videoOff, color: Colors.white54, size: 48),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Unable to play video',
            style: AppTextStyles.h2(context).copyWith(color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'The file may be missing or corrupted.',
            style: AppTextStyles.body(context).copyWith(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
