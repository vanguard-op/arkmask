import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';
import '../cubit/story_cubit.dart';
import '../cubit/story_state.dart';
import '../widgets/generation_settings_sheet.dart';

/// Story Editor Screen — FEAT-008, FEAT-009.
///
/// Displays `story.mdx` as a list of numbered scene blocks (one `TextField` per
/// scene). Auto-saves after 1.5 s of idle typing. An "Extract Assets" action
/// in the AppBar and keyboard toolbar sends the story to `/assets`.
class StoryEditorScreen extends StatelessWidget {
  const StoryEditorScreen({super.key, required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => StoryCubit(
        projectSlug: projectName,
        apiClient: services.apiClient,
      )..load(),
      child: _StoryEditorView(projectName: projectName),
    );
  }
}

class _StoryEditorView extends StatelessWidget {
  const _StoryEditorView({required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<StoryCubit, StoryState>(
      listener: (context, state) {
        if (state is StoryLoaded && state.extractError != null) {
          if (state.extractError == '__credits__') {
            showCreditsExhaustedDialog(context);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.extractError!),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => context.read<StoryCubit>().extractAssets(),
                ),
              ),
            );
          }
          context.read<StoryCubit>().clearExtractError();
        }

        // When existing asset documents are detected, show a confirmation
        // dialog before proceeding with re-extraction.
        if (state is StoryLoaded && state.hasExistingAssets) {
          _showReExtractDialog(context);
        }
      },
      builder: (context, state) {
        return PopScope(
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) await context.read<StoryCubit>().saveNow();
          },
          child: Scaffold(
            appBar: _StoryAppBar(projectName: projectName, state: state),
            body: switch (state) {
              StoryLoading() => const _SkeletonBody(),
              StoryError(:final message) => _ErrorBody(
                  message: message,
                  onRetry: () => context.read<StoryCubit>().load(),
                ),
              StoryLoaded() => _SceneList(state: state),
            },
            floatingActionButton: state is StoryLoaded && !state.isExtracting
                ? _AddSceneFab(
                    onPressed: () => context.read<StoryCubit>().addScene(),
                  )
                : null,
          ),
        );
      },
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _StoryAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _StoryAppBar({required this.projectName, required this.state});

  final String projectName;
  final StoryState state;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final loaded = state is StoryLoaded ? state as StoryLoaded : null;

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () async {
          await context.read<StoryCubit>().saveNow();
          if (context.mounted) context.pop();
        },
      ),
      title: Text(
        'story.mdx',
        style: AppTextStyles.body(context).copyWith(
          fontFamily: 'JetBrains Mono',
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
        ),
      ),
      actions: [
        // Scene count badge
        if (loaded != null)
          _SceneCountBadge(count: loaded.sceneCount, primaryColor: primaryColor),
        const SizedBox(width: AppSpacing.s2),
        // Save indicator
        if (loaded != null) _SaveIndicator(loaded: loaded),
        const SizedBox(width: AppSpacing.s2),
        // Generation settings button
        if (loaded != null)
          IconButton(
            icon: const Icon(LucideIcons.sliders),
            tooltip: 'Generation Settings',
            onPressed: () => showGenerationSettingsSheet(context),
          ),
        // Extract Assets button (Generate variant)
        if (loaded != null)
          _ExtractButton(
            enabled: loaded.sceneCount >= 1 && !loaded.isExtracting,
            isExtracting: loaded.isExtracting,
            primaryColor: primaryColor,
            onPressed: () => _onExtractTapped(context, loaded),
          ),
        const SizedBox(width: AppSpacing.s3),
      ],
    );
  }

  Future<void> _onExtractTapped(BuildContext context, StoryLoaded state) async {
    // The cubit checks Firestore for existing assets. If any are found it emits
    // hasExistingAssets = true, which triggers _showReExtractDialog via the
    // BlocConsumer listener. Otherwise it proceeds with extraction.
    context.read<StoryCubit>().extractAssets();
  }
}

/// Shows a confirmation dialog when the project already has Firestore asset
/// documents. The user must explicitly confirm before re-extraction overwrites
/// them. Calls `extractAssets(force: true)` on confirmation.
void _showReExtractDialog(BuildContext context) {
  showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Re-extract assets?'),
      content: const Text(
        'Existing asset documents without generated images will be recreated.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Re-extract'),
        ),
      ],
    ),
  ).then((confirmed) {
    if (confirmed == true && context.mounted) {
      context.read<StoryCubit>().extractAssets(force: true);
    }
  });
}

class _SceneCountBadge extends StatelessWidget {
  const _SceneCountBadge({required this.count, required this.primaryColor});

  final int count;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSizing.radiusFull),
      ),
      child: Text(
        '$count ${count == 1 ? 'scene' : 'scenes'}',
        style: AppTextStyles.caption(context).copyWith(color: primaryColor),
      ),
    );
  }
}

class _SaveIndicator extends StatelessWidget {
  const _SaveIndicator({required this.loaded});

  final StoryLoaded loaded;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (loaded.isSaving) {
      return Text(
        'Saving...',
        style: AppTextStyles.caption(context).copyWith(
          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
        ),
      );
    }
    if (loaded.savedRecently) {
      return Text(
        'Saved ✓',
        style: AppTextStyles.caption(context).copyWith(
          color: isDark ? AppColors.successDark : AppColors.successLight,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _ExtractButton extends StatelessWidget {
  const _ExtractButton({
    required this.enabled,
    required this.isExtracting,
    required this.primaryColor,
    required this.onPressed,
  });

  final bool enabled;
  final bool isExtracting;
  final Color primaryColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: isExtracting
          ? SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: primaryColor,
              ),
            )
          : Icon(LucideIcons.sparkles, size: AppSizing.iconSm, color: primaryColor),
      label: Text(
        'Extract Assets',
        style: AppTextStyles.bodySmall(context).copyWith(color: primaryColor),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: enabled ? primaryColor.withValues(alpha: 0.5) : Colors.transparent,
        ),
        minimumSize: const Size(0, AppSizing.buttonSm),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        ),
      ),
    );
  }
}

// ── Scene list ────────────────────────────────────────────────────────────────

class _SceneList extends StatelessWidget {
  const _SceneList({required this.state});

  final StoryLoaded state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Extraction progress bar
        if (state.isExtracting)
          LinearProgressIndicator(
            backgroundColor: Colors.transparent,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.primaryDark
                : AppColors.primaryLight,
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(
              left: AppSpacing.s4,
              right: AppSpacing.s4,
              top: AppSpacing.s4,
              // Extra bottom padding so content isn't hidden behind the Add Scene button.
              bottom: AppSpacing.s12 + AppSpacing.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Scene blocks ──────────────────────────────────────────
                if (state.scenes.isEmpty)
                  _EmptySceneBlock(
                    onBodyChanged: (body) =>
                        context.read<StoryCubit>().onSceneBodyChanged(1, body),
                  )
                else
                  ...state.scenes.asMap().entries.map((entry) => _SceneBlock(
                        scene: entry.value,
                        sceneIndex: entry.key,
                        totalScenes: state.scenes.length,
                        isReadOnly: state.isExtracting,
                        onBodyChanged: (body) => context
                            .read<StoryCubit>()
                            .onSceneBodyChanged(entry.value.number, body),
                      )),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A single scene block: interactive header divider + body text field.
///
/// Long-pressing the scene header chip reveals an inline action row with
/// three options: add before, add after, delete (per screens.md Scene Header
/// Long-Press spec). All structural changes are delegated to [StoryCubit].
class _SceneBlock extends StatefulWidget {
  const _SceneBlock({
    required this.scene,
    required this.sceneIndex,
    required this.totalScenes,
    required this.onBodyChanged,
    this.isReadOnly = false,
  });

  final StoryScene scene;
  /// 0-based position of this scene in the list (used for insert/delete).
  final int sceneIndex;
  /// Total scene count — needed to disable delete when only 1 scene remains.
  final int totalScenes;
  final ValueChanged<String> onBodyChanged;
  final bool isReadOnly;

  @override
  State<_SceneBlock> createState() => _SceneBlockState();
}

class _SceneBlockState extends State<_SceneBlock>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final AnimationController _actionAnim;
  bool _showActions = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.scene.body);
    _actionAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void didUpdateWidget(_SceneBlock old) {
    super.didUpdateWidget(old);
    // Only update controller if body changed externally (not from user typing).
    if (old.scene.body != widget.scene.body &&
        _controller.text != widget.scene.body) {
      _controller.text = widget.scene.body;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _actionAnim.dispose();
    super.dispose();
  }

  void _toggleActions() {
    setState(() => _showActions = !_showActions);
    if (_showActions) {
      _actionAnim.forward();
    } else {
      _actionAnim.reverse();
    }
  }

  void _dismissActions() {
    if (!_showActions) return;
    setState(() => _showActions = false);
    _actionAnim.reverse();
  }

  void _addBefore() {
    _dismissActions();
    context.read<StoryCubit>().insertSceneBefore(widget.sceneIndex);
  }

  void _addAfter() {
    _dismissActions();
    context.read<StoryCubit>().insertSceneAfter(widget.sceneIndex);
  }

  Future<void> _delete() async {
    _dismissActions();
    if (widget.scene.body.trim().isNotEmpty) {
      // Confirm before deleting a scene that has content.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete scene?'),
          content: Text(
            'Scene ${widget.scene.number} and its content will be permanently removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Delete',
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? AppColors.errorDark
                      : AppColors.errorLight,
                ),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (mounted) context.read<StoryCubit>().deleteScene(widget.sceneIndex);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final dividerColor = isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;
    final errorColor = isDark ? AppColors.errorDark : AppColors.errorLight;
    final canDelete = widget.totalScenes > 1;

    return GestureDetector(
      // Tapping anywhere outside the header dismisses the action row.
      onTap: _showActions ? _dismissActions : null,
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: AppSpacing.s4),

          // ── Scene header row ─────────────────────────────────────────────
          Row(
            children: [
              Expanded(child: Divider(color: dividerColor, height: 1)),
              const SizedBox(width: AppSpacing.s2),

              // The chip is the long-press target. It expands to show actions.
              GestureDetector(
                onLongPress: widget.isReadOnly ? null : _toggleActions,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: _showActions
                      // ── Action row ────────────────────────────────────
                      ? Container(
                          key: const ValueKey('actions'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s1,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppColors.surfaceOverlayDark
                                : AppColors.surfaceOverlayLight,
                            borderRadius:
                                BorderRadius.circular(AppSizing.radiusSm),
                            border: Border.all(
                              color: primaryColor.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Add before
                              _ActionChipButton(
                                icon: LucideIcons.arrowUpCircle,
                                label: 'Before',
                                color: primaryColor,
                                onPressed: _addBefore,
                              ),
                              // Scene number label (stays visible in the center)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.s2),
                                child: Text(
                                  'Scene ${widget.scene.number}',
                                  style: AppTextStyles.caption(context)
                                      .copyWith(color: primaryColor, letterSpacing: 0.6),
                                ),
                              ),
                              // Add after
                              _ActionChipButton(
                                icon: LucideIcons.arrowDownCircle,
                                label: 'After',
                                color: primaryColor,
                                onPressed: _addAfter,
                              ),
                              Container(
                                height: 16,
                                width: 1,
                                color: isDark
                                    ? AppColors.borderDefaultDark
                                    : AppColors.borderDefaultLight,
                                margin: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.s1),
                              ),
                              // Delete
                              _ActionChipButton(
                                icon: LucideIcons.trash2,
                                label: 'Delete',
                                color: canDelete ? errorColor : (isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight),
                                onPressed: canDelete ? _delete : null,
                              ),
                            ],
                          ),
                        )
                      // ── Normal chip ───────────────────────────────────
                      : Container(
                          key: const ValueKey('chip'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s2,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.15),
                            borderRadius:
                                BorderRadius.circular(AppSizing.radiusXs),
                          ),
                          child: Text(
                            'SCENE ${widget.scene.number}',
                            style: AppTextStyles.caption(context).copyWith(
                              color: primaryColor,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                ),
              ),

              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Divider(color: dividerColor, height: 1)),
            ],
          ),

          const SizedBox(height: AppSpacing.s2),

          // ── Scene body text field ────────────────────────────────────────
          TextField(
            controller: _controller,
            enabled: !widget.isReadOnly,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: AppTextStyles.bodyLarge(context),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: 'Write scene ${widget.scene.number} here...',
              hintStyle: AppTextStyles.bodyLarge(context).copyWith(
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiaryLight,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: widget.onBodyChanged,
            onTap: _dismissActions,
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ),
    );
  }
}

/// A compact icon + label button used inside the long-press action row.
class _ActionChipButton extends StatelessWidget {
  const _ActionChipButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AppSizing.radiusXs),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s2,
          vertical: AppSpacing.s1,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppSizing.iconSm, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: AppTextStyles.caption(context).copyWith(
                fontSize: 9,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown for a brand-new empty story (0 scenes) — acts as scene 1.
class _EmptySceneBlock extends StatelessWidget {
  const _EmptySceneBlock({required this.onBodyChanged});

  final ValueChanged<String> onBodyChanged;

  @override
  Widget build(BuildContext context) {
    return _SceneBlock(
      scene: const StoryScene(number: 1, body: ''),
      sceneIndex: 0,
      totalScenes: 1,
      onBodyChanged: onBodyChanged,
    );
  }
}

// ── Add Scene FAB ─────────────────────────────────────────────────────────────

class _AddSceneFab extends StatelessWidget {
  const _AddSceneFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return FloatingActionButton.extended(
      onPressed: onPressed,
      backgroundColor: primaryColor.withValues(alpha: 0.15),
      foregroundColor: primaryColor,
      elevation: 0,
      icon: const Icon(LucideIcons.plus, size: AppSizing.iconSm),
      label: Text('Add Scene', style: AppTextStyles.body(context).copyWith(color: primaryColor)),
    );
  }
}

// ── Loading skeleton ──────────────────────────────────────────────────────────

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(6, (i) {
          final width = (i % 3 == 0) ? double.infinity : (i % 2 == 0 ? 220.0 : 160.0);
          return Container(
            height: 14,
            width: width,
            margin: const EdgeInsets.only(bottom: AppSpacing.s3),
            decoration: BoxDecoration(
              color: base.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppSizing.radiusXs),
            ),
          );
        }),
      ),
    );
  }
}

// ── Error ─────────────────────────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: AppTextStyles.body(context)),
          const SizedBox(height: AppSpacing.s4),
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
