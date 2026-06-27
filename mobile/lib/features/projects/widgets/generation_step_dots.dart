import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';

/// Generation pipeline state for a single step dot.
/// Named [GenerationStepState] to avoid conflict with Flutter's `StepState`
/// from `material.dart` (do not import both without a hide clause).
enum GenerationStepState {
  pending,
  running,
  done,
  failed,
}

/// Compact inline indicator showing the generation pipeline state for an
/// asset or scene node in the file browser.
///
/// Asset rows: 2 dots (prompt, image).
/// Scene rows: 2 dots (storyboard, video).
///
/// Dot colors per state:
/// - pending: statePending (grey)
/// - running: stateRunning (blue, animated pulse)
/// - done:    stateDone (green)
/// - failed:  stateFailed (red)
class GenerationStepDots extends StatefulWidget {
  const GenerationStepDots({super.key, required this.steps});

  /// The state of each pipeline step (in display order).
  final List<GenerationStepState> steps;

  @override
  State<GenerationStepDots> createState() => _GenerationStepDotsState();
}

class _GenerationStepDotsState extends State<GenerationStepDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  bool get _hasRunning => widget.steps.contains(GenerationStepState.running);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (_hasRunning) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(GenerationStepDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_hasRunning && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!_hasRunning && _pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: widget.steps.asMap().entries.map((entry) {
        final index = entry.key;
        final step = entry.value;
        final color = _colorForStep(step, isDark);
        final dot = Container(
          width: 6.0,
          height: 6.0,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );

        return Padding(
          padding: EdgeInsets.only(left: index == 0 ? 0 : AppSpacing.s1),
          child: step == GenerationStepState.running
              ? AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, _) => Transform.scale(
                    scale: _pulseAnim.value,
                    child: dot,
                  ),
                )
              : dot,
        );
      }).toList(),
    );
  }

  Color _colorForStep(GenerationStepState step, bool isDark) {
    switch (step) {
      case GenerationStepState.pending:
        return isDark ? AppColors.statePendingDark : AppColors.statePendingLight;
      case GenerationStepState.running:
        return isDark ? AppColors.stateRunningDark : AppColors.stateRunningLight;
      case GenerationStepState.done:
        return isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight;
      case GenerationStepState.failed:
        return isDark ? AppColors.stateFailedDark : AppColors.stateFailedLight;
    }
  }
}
