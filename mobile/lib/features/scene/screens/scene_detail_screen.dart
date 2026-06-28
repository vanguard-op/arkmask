import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../app.dart';
import '../../../core/jobs/generation_job_manager.dart';
import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../projects/widgets/generation_step_dots.dart';
import '../cubit/scene_cubit.dart';
import '../cubit/scene_state.dart';

/// Scene Detail Screen — FEAT-014 (Generate Storyboard), FEAT-015
/// (Storyboard MDX Editor), FEAT-016 (Generate Scene Video).
///
/// Route: `/project/:projectName/scene/:sceneId`
class SceneDetailScreen extends StatelessWidget {
  const SceneDetailScreen({
    super.key,
    required this.projectName,
    required this.sceneId,
  });

  final String projectName;
  final int sceneId;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => SceneCubit(
        projectName: projectName,
        sceneNumber: sceneId,
        fileService: services.fileService,
        apiClient: services.apiClient,
        jobManager: services.jobManager,
      )..load(),
      child: _SceneDetailView(
        projectName: projectName,
        sceneId: sceneId,
        jobManager: services.jobManager,
      ),
    );
  }
}

// ── Root view ─────────────────────────────────────────────────────────────────

class _SceneDetailView extends StatefulWidget {
  const _SceneDetailView({
    required this.projectName,
    required this.sceneId,
    required this.jobManager,
  });

  final String projectName;
  final int sceneId;
  final GenerationJobManager jobManager;

  @override
  State<_SceneDetailView> createState() => _SceneDetailViewState();
}

class _SceneDetailViewState extends State<_SceneDetailView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        context.read<SceneCubit>().switchTab(_tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SceneCubit, SceneState>(
      listener: (context, state) {
        if (state is! SceneLoaded) return;

        // Sync tab controller with cubit's selected tab.
        if (_tabController.index != state.selectedTabIndex) {
          _tabController.animateTo(state.selectedTabIndex);
        }

        // Storyboard errors.
        final sbErr = state.storyboardError;
        if (sbErr != null) {
          if (sbErr == '__credits__') {
            _showCreditsDialog(context, 'Storyboard generation requires ${CreditCost.videoPrompt} credits.');
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sbErr),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => context.read<SceneCubit>().generateStoryboard(),
                ),
              ),
            );
          }
          context.read<SceneCubit>().clearStoryboardError();
        }

        // Video errors.
        final vidErr = state.videoError;
        if (vidErr != null) {
          if (vidErr == '__credits__') {
            _showCreditsDialog(context, 'Video generation requires ${CreditCost.videoGeneration} credits.');
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(vidErr)),
            );
          }
          context.read<SceneCubit>().clearVideoError();
        }
      },
      builder: (context, state) {
        return Scaffold(
          backgroundColor: _surfaceBase(context),
          appBar: _SceneAppBar(
            sceneId: widget.sceneId,
            state: state,
            jobManager: widget.jobManager,
          ),
          body: switch (state) {
            SceneLoading() => const Center(child: CircularProgressIndicator()),
            SceneError(:final message) => _ErrorBody(
                message: message,
                onRetry: () => context.read<SceneCubit>().load(),
              ),
            SceneLoaded() => _LoadedBody(
                state: state,
                projectName: widget.projectName,
                tabController: _tabController,
                jobManager: widget.jobManager,
              ),
          },
        );
      },
    );
  }

  void _showCreditsDialog(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Insufficient Credits'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _SceneAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SceneAppBar({
    required this.sceneId,
    required this.state,
    required this.jobManager,
  });

  final int sceneId;
  final SceneState state;
  final GenerationJobManager jobManager;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final loaded = state is SceneLoaded ? state as SceneLoaded : null;
    final sceneDirPath = loaded?.sceneDirPath;

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () => context.pop(),
      ),
      title: Text(
        'Scene $sceneId',
        style: AppTextStyles.h2(context),
      ),
      actions: [
        if (sceneDirPath != null)
          ListenableBuilder(
            listenable: jobManager,
            builder: (context2, child2) => _AggregateJobDot(
              sceneDirPath: sceneDirPath,
              jobManager: jobManager,
              loaded: loaded,
            ),
          ),
        const SizedBox(width: AppSpacing.s3),
      ],
    );
  }
}

/// Single dot in the AppBar showing the worst state of storyboard/video jobs.
class _AggregateJobDot extends StatelessWidget {
  const _AggregateJobDot({
    required this.sceneDirPath,
    required this.jobManager,
    required this.loaded,
  });

  final String sceneDirPath;
  final GenerationJobManager jobManager;
  final SceneLoaded? loaded;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    var sbState = jobManager.stateFor(GenerationJobManager.storyboardKey(sceneDirPath));
    var vidState = jobManager.stateFor(GenerationJobManager.videoKey(sceneDirPath));

    // Fall back to on-disk state when no job has run in this session.
    final hasStoryboard = loaded?.storyboard.storyboardBody.isNotEmpty ?? false;
    final hasVideo = loaded?.hasVideo ?? false;
    if (sbState == GenerationJobState.idle && hasStoryboard) {
      sbState = GenerationJobState.done;
    }
    if (vidState == GenerationJobState.idle && hasVideo) {
      vidState = GenerationJobState.done;
    }

    final worst = _worstState(sbState, vidState);
    final color = switch (worst) {
      GenerationJobState.running => isDark ? AppColors.stateRunningDark : AppColors.stateRunningLight,
      GenerationJobState.done => isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight,
      GenerationJobState.failed => isDark ? AppColors.stateFailedDark : AppColors.stateFailedLight,
      GenerationJobState.idle => isDark ? AppColors.statePendingDark : AppColors.statePendingLight,
    };

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  static GenerationJobState _worstState(
      GenerationJobState a, GenerationJobState b) {
    const priority = [
      GenerationJobState.running,
      GenerationJobState.failed,
      GenerationJobState.done,
      GenerationJobState.idle,
    ];
    final ai = priority.indexOf(a);
    final bi = priority.indexOf(b);
    return ai <= bi ? a : b;
  }
}

// ── Loaded body ───────────────────────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({
    required this.state,
    required this.projectName,
    required this.tabController,
    required this.jobManager,
  });

  final SceneLoaded state;
  final String projectName;
  final TabController tabController;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Custom tab row.
        _CustomTabBar(controller: tabController),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              _AssetsTab(
                state: state,
                projectName: projectName,
                jobManager: jobManager,
              ),
              _StoryboardTab(
                state: state,
                projectName: projectName,
                jobManager: jobManager,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Custom tab bar ────────────────────────────────────────────────────────────

class _CustomTabBar extends StatelessWidget {
  const _CustomTabBar({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final surfaceRaised = isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          color: surfaceRaised,
          child: Row(
            children: [
              _TabItem(
                label: 'Assets',
                isActive: controller.index == 0,
                primaryColor: primaryColor,
                onTap: () => controller.animateTo(0),
              ),
              _TabItem(
                label: 'Storyboard',
                isActive: controller.index == 1,
                primaryColor: primaryColor,
                onTap: () => controller.animateTo(1),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.label,
    required this.isActive,
    required this.primaryColor,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isActive
        ? (isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight)
        : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight);

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          decoration: isActive
              ? BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: primaryColor, width: 2),
                  ),
                )
              : null,
          child: Text(
            label,
            style: AppTextStyles.body(context).copyWith(color: textColor),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

// ── Assets Tab ────────────────────────────────────────────────────────────────

class _AssetsTab extends StatelessWidget {
  const _AssetsTab({
    required this.state,
    required this.projectName,
    required this.jobManager,
  });

  final SceneLoaded state;
  final String projectName;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final missingImages = state.missingVariantAssets;
    final missingPrompts = state.missingPromptAssets;
    final hasMissing = missingImages.isNotEmpty || missingPrompts.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s4,
            ),
            children: [
              // Section header.
              Row(
                children: [
                  Text(
                    'SCENE ASSETS',
                    style: AppTextStyles.caption(context).copyWith(
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${state.assets.length} assets',
                    style: AppTextStyles.caption(context),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),

              // Missing images warning.
              if (missingImages.isNotEmpty)
                _MissingImagesBanner(
                  missing: missingImages,
                  projectName: projectName,
                ),

              // Missing prompts warning.
              if (missingPrompts.isNotEmpty) ...[
                if (missingImages.isNotEmpty) const SizedBox(height: AppSpacing.s2),
                _MissingPromptsBanner(
                  missing: missingPrompts,
                  projectName: projectName,
                ),
              ],

              // Asset list.
              if (state.assets.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s6),
                  child: Center(
                    child: Text(
                      'No assets in this scene.',
                      style: AppTextStyles.body(context).copyWith(
                        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                      ),
                    ),
                  ),
                )
              else
                ...state.assets.map((asset) => _AssetRow(
                      asset: asset,
                      projectName: projectName,
                      jobManager: jobManager,
                    )),

              const SizedBox(height: AppSpacing.s4),

              // Scene text expansion tile.
              _SceneTextTile(sceneText: state.sceneText),

              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),

        // Generate Storyboard button pinned to bottom.
        _GenerateStoryboardButton(
          state: state,
          isBlocked: hasMissing,
        ),
      ],
    );
  }
}

// ── Missing images warning banner ─────────────────────────────────────────────

class _MissingImagesBanner extends StatelessWidget {
  const _MissingImagesBanner({
    required this.missing,
    required this.projectName,
  });

  final List<SceneAsset> missing;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warningColor = isDark ? AppColors.warningDark : AppColors.warningLight;
    final surfaceOverlay =
        isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: surfaceOverlay,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        border: Border(left: BorderSide(color: warningColor, width: 3)),
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.triangleAlert,
                  size: AppSizing.iconSm, color: warningColor),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  '${missing.length} asset${missing.length == 1 ? '' : 's'} are missing reference images.',
                  style: AppTextStyles.bodySmall(context)
                      .copyWith(color: warningColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ...missing.map((asset) => GestureDetector(
                onTap: () => context.push(
                  '/project/${Uri.encodeComponent(projectName)}'
                  '/asset/${Uri.encodeComponent(asset.dirPath)}',
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Text(
                    asset.displayName,
                    style: AppTextStyles.bodySmall(context).copyWith(
                      color: isDark ? AppColors.primaryDark : AppColors.primaryLight,
                      decoration: TextDecoration.underline,
                      decorationColor:
                          isDark ? AppColors.primaryDark : AppColors.primaryLight,
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

// ── Missing prompts warning banner ────────────────────────────────────────────

class _MissingPromptsBanner extends StatelessWidget {
  const _MissingPromptsBanner({
    required this.missing,
    required this.projectName,
  });

  final List<SceneAsset> missing;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warningColor = isDark ? AppColors.warningDark : AppColors.warningLight;
    final surfaceOverlay =
        isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: surfaceOverlay,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        border: Border(left: BorderSide(color: warningColor, width: 3)),
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.triangleAlert,
                  size: AppSizing.iconSm, color: warningColor),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  '${missing.length} asset${missing.length == 1 ? '' : 's'} '
                  '${missing.length == 1 ? 'has' : 'have'} no image prompt. '
                  'Generate a prompt for each asset first.',
                  style: AppTextStyles.bodySmall(context)
                      .copyWith(color: warningColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ...missing.map((asset) => GestureDetector(
                onTap: () {
                  // Navigate to the referenced asset editor so the user can
                  // generate a prompt there. For pass-through assets this is
                  // the global or scene-local referenced dir, not the
                  // placeholder dir owned by this scene.
                  context.push(
                    '/project/${Uri.encodeComponent(projectName)}'
                    '/asset/${Uri.encodeComponent(asset.resolvedDirPath)}',
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Text(
                    asset.displayName,
                    style: AppTextStyles.bodySmall(context).copyWith(
                      color: isDark ? AppColors.primaryDark : AppColors.primaryLight,
                      decoration: TextDecoration.underline,
                      decorationColor:
                          isDark ? AppColors.primaryDark : AppColors.primaryLight,
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

// ── Asset row ─────────────────────────────────────────────────────────────────

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.projectName,
    required this.jobManager,
  });

  final SceneAsset asset;
  final String projectName;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final surfaceRaised =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    // Pass-through assets have no own image — show the referenced asset's image.
    // Variants and local assets always use their own image.
    final imageFile = File(p.join(asset.resolvedDirPath, 'image.png'));

    // Tapping a pass-through navigates to the referenced asset so the user
    // can see/edit it. Variants and locals navigate to their own dir.
    final editorPath = asset.resolvedDirPath;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Material(
        color: surfaceRaised,
        borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          onTap: () => context.push(
            '/project/${Uri.encodeComponent(projectName)}'
            '/asset/${Uri.encodeComponent(editorPath)}',
          ),
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
              child: Row(
                children: [
                  // Thumbnail.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppSizing.radiusXs),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: asset.hasImage
                          ? Image.file(imageFile, fit: BoxFit.cover,
                              errorBuilder: (ctx, err, stack) =>
                                  _greyPlaceholder(isDark))
                          : _greyPlaceholder(isDark),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),

                  // Name + badge.
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayName(asset.name),
                          style: AppTextStyles.body(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        _AssetBadge(
                          asset: asset,
                          primaryColor: primaryColor,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),

                  // Step dots (2: prompt, image).
                  ListenableBuilder(
                    listenable: jobManager,
                    builder: (context2, child2) => GenerationStepDots(
                      steps: [
                        _jobStateToStepState(
                            jobManager.stateFor(
                                GenerationJobManager.promptKey(asset.dirPath)),
                            fallbackDone: asset.isPromptReady),
                        _jobStateToStepState(
                            jobManager.stateFor(
                                GenerationJobManager.imageKey(asset.dirPath)),
                            fallbackDone: asset.hasImage),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _greyPlaceholder(bool isDark) => Container(
        color: isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
        child: Icon(
          LucideIcons.image,
          size: 16,
          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
        ),
      );

  /// Shows only the last path segment for reference names like `@/scenes/0/lyra`.
  String _displayName(String name) =>
      name.contains('/') ? name.split('/').last : name;

  GenerationStepState _jobStateToStepState(
    GenerationJobState job, {
    required bool fallbackDone,
  }) {
    return switch (job) {
      GenerationJobState.running => GenerationStepState.running,
      GenerationJobState.failed => GenerationStepState.failed,
      GenerationJobState.done => GenerationStepState.done,
      GenerationJobState.idle =>
        fallbackDone ? GenerationStepState.done : GenerationStepState.pending,
    };
  }
}

class _AssetBadge extends StatelessWidget {
  const _AssetBadge({
    required this.asset,
    required this.primaryColor,
  });

  final SceneAsset asset;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Badge classification:
    //   Global   — asset lives in the global pool, or is a pass-through ref
    //              (delegates everything to a global/prior-scene asset)
    //   Variant  — @-named asset that has its own description/prompt/image
    //   Scene    — plain local asset with no reference
    final bool isGlobalOrPassThrough =
        asset.isGlobal || (asset.isPassThrough && asset.name.startsWith('@'));
    final bool isVariant =
        asset.name.startsWith('@') && asset.description.isNotEmpty;

    final String label;
    final Color bgColor;
    final Color textColor;

    if (isGlobalOrPassThrough) {
      label = 'Global';
      bgColor = primaryColor.withValues(alpha: 0.15);
      textColor = primaryColor;
    } else if (isVariant) {
      label = 'Variant';
      bgColor = isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight;
      textColor = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    } else {
      label = 'Scene';
      bgColor = isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight;
      textColor = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s2, vertical: 1),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppSizing.radiusXs),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption(context).copyWith(
          color: textColor,
          fontSize: 10,
        ),
      ),
    );
  }
}

// ── Scene text expansion tile ─────────────────────────────────────────────────

class _SceneTextTile extends StatelessWidget {
  const _SceneTextTile({required this.sceneText});

  final String sceneText;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ExpansionTile(
      title: Text(
        'Scene Text',
        style: AppTextStyles.h3(context),
      ),
      tilePadding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s4),
          child: Text(
            sceneText.isEmpty ? 'No story text found.' : sceneText,
            style: AppTextStyles.bodyLarge(context).copyWith(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Generate Storyboard button ────────────────────────────────────────────────

class _GenerateStoryboardButton extends StatelessWidget {
  const _GenerateStoryboardButton({
    required this.state,
    required this.isBlocked,
  });

  final SceneLoaded state;

  /// True when missing images or missing prompts block storyboard generation.
  final bool isBlocked;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final isGenerating = state.isGeneratingStoryboard;
    final isDisabled = isBlocked || isGenerating;
    final hasExisting = state.storyboard.storyboardBody.isNotEmpty;

    final button = ElevatedButton(
      onPressed: isDisabled ? null : () => _onTap(context),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSizing.buttonMd),
        backgroundColor: Colors.transparent,
        side: BorderSide(
          color: isDisabled ? Colors.transparent : primaryColor,
        ),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        ),
      ),
      child: isGenerating
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: primaryColor),
                ),
                const SizedBox(width: AppSpacing.s2),
                Text(
                  'Generating...',
                  style: AppTextStyles.body(context)
                      .copyWith(color: primaryColor),
                ),
              ],
            )
          : Text(
              hasExisting ? 'Regenerate Storyboard' : 'Generate Storyboard',
              style: AppTextStyles.body(context).copyWith(
                color: isDisabled
                    ? (isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight)
                    : primaryColor,
              ),
            ),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4,
          AppSpacing.s2,
          AppSpacing.s4,
          AppSpacing.s4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isBlocked)
              Tooltip(
                message: 'Resolve all warnings above before generating a storyboard.',
                child: button,
              )
            else
              button,
            const SizedBox(height: AppSpacing.s1),
            Text(
              '${CreditCost.videoPrompt} credits',
              style: AppTextStyles.caption(context),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTap(BuildContext context) async {
    // Warn if many character assets.
    final charAssets = state.assets
        .where((a) => !a.isPassThrough && a.type == AssetType.character && a.hasImage)
        .toList();
    if (charAssets.length > 4) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Many Character Assets'),
          content: Text(
            'This scene has ${charAssets.length} character assets with reference images. '
            'This may affect generation quality. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    context.read<SceneCubit>().generateStoryboard();
  }
}

// ── Storyboard Tab ────────────────────────────────────────────────────────────

class _StoryboardTab extends StatelessWidget {
  const _StoryboardTab({
    required this.state,
    required this.projectName,
    required this.jobManager,
  });

  final SceneLoaded state;
  final String projectName;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    final hasStoryboard = state.storyboard.storyboardBody.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: hasStoryboard
              ? _StoryboardEditor(storyboard: state.storyboard)
              : _EmptyStoryboardState(),
        ),

        // Job status strip.
        _JobStatusStrip(
          state: state,
          jobManager: jobManager,
        ),

        // Video preview.
        if (state.hasVideo)
          _VideoPreviewArea(
            sceneDirPath: state.sceneDirPath,
          ),

        // Generate Video button.
        _GenerateVideoButton(state: state),
      ],
    );
  }
}

// ── Empty storyboard state ────────────────────────────────────────────────────

class _EmptyStoryboardState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.scroll,
            size: 48,
            color: primaryColor.withValues(alpha: 0.4),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'No storyboard yet',
            style: AppTextStyles.h3(context),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'Generate a storyboard from the Assets tab.',
            style: AppTextStyles.body(context).copyWith(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Storyboard editor ─────────────────────────────────────────────────────────

class _StoryboardEditor extends StatefulWidget {
  const _StoryboardEditor({required this.storyboard});

  final SceneStoryboard storyboard;

  @override
  State<_StoryboardEditor> createState() => _StoryboardEditorState();
}

class _StoryboardEditorState extends State<_StoryboardEditor> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.storyboard.storyboardBody);
  }

  @override
  void didUpdateWidget(_StoryboardEditor old) {
    super.didUpdateWidget(old);
    if (old.storyboard.storyboardBody != widget.storyboard.storyboardBody &&
        _controller.text != widget.storyboard.storyboardBody) {
      _controller.text = widget.storyboard.storyboardBody;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceRaised =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    return Container(
      color: surfaceRaised,
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: TextField(
        controller: _controller,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: AppTextStyles.monoBody(context),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onEditingComplete: () => _save(),
      ),
    );
  }

  void _save() {
    context.read<SceneCubit>().onStoryboardChanged(_controller.text);
  }
}

// ── Job status strip ──────────────────────────────────────────────────────────

class _JobStatusStrip extends StatefulWidget {
  const _JobStatusStrip({required this.state, required this.jobManager});

  final SceneLoaded state;
  final GenerationJobManager jobManager;

  @override
  State<_JobStatusStrip> createState() => _JobStatusStripState();
}

class _JobStatusStripState extends State<_JobStatusStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.jobManager,
      builder: (context, _) {
        final sceneDirPath = widget.state.sceneDirPath;
        final sbJobState =
            widget.jobManager.stateFor(GenerationJobManager.storyboardKey(sceneDirPath));
        final vidJobState =
            widget.jobManager.stateFor(GenerationJobManager.videoKey(sceneDirPath));

        final hasRunning = sbJobState == GenerationJobState.running ||
            vidJobState == GenerationJobState.running;
        if (hasRunning && !_pulse.isAnimating) {
          _pulse.repeat(reverse: true);
        } else if (!hasRunning && _pulse.isAnimating) {
          _pulse.stop();
          _pulse.reset();
        }

        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s3,
          ),
          child: Row(
            children: [
              _StatusStep(
                icon: LucideIcons.scroll,
                label: 'Storyboard',
                jobState: sbJobState,
                scaleAnim: _scaleAnim,
                errorMessage: widget.jobManager
                    .errorFor(GenerationJobManager.storyboardKey(sceneDirPath)),
              ),
              const SizedBox(width: AppSpacing.s6),
              _StatusStep(
                icon: LucideIcons.video,
                label: 'Video',
                jobState: vidJobState,
                scaleAnim: _scaleAnim,
                subLabel: vidJobState == GenerationJobState.running
                    ? 'This may take a few minutes.'
                    : null,
                errorMessage: widget.jobManager
                    .errorFor(GenerationJobManager.videoKey(sceneDirPath)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusStep extends StatelessWidget {
  const _StatusStep({
    required this.icon,
    required this.label,
    required this.jobState,
    required this.scaleAnim,
    this.subLabel,
    this.errorMessage,
  });

  final IconData icon;
  final String label;
  final GenerationJobState jobState;
  final Animation<double> scaleAnim;
  final String? subLabel;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (jobState) {
      GenerationJobState.idle => isDark ? AppColors.statePendingDark : AppColors.statePendingLight,
      GenerationJobState.running => isDark ? AppColors.stateRunningDark : AppColors.stateRunningLight,
      GenerationJobState.done => isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight,
      GenerationJobState.failed => isDark ? AppColors.stateFailedDark : AppColors.stateFailedLight,
    };

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        jobState == GenerationJobState.running
            ? AnimatedBuilder(
                animation: scaleAnim,
                builder: (context2, child2) =>
                    Transform.scale(scale: scaleAnim.value, child: dot),
              )
            : dot,
        const SizedBox(width: AppSpacing.s2),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: AppSizing.iconXs, color: color),
                const SizedBox(width: AppSpacing.s1),
                Text(label,
                    style: AppTextStyles.caption(context).copyWith(color: color)),
                if (jobState == GenerationJobState.failed && errorMessage != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  GestureDetector(
                    onTap: () => _showError(context, errorMessage!),
                    child: Text(
                      'View Error',
                      style: AppTextStyles.caption(context).copyWith(
                        color: isDark ? AppColors.primaryDark : AppColors.primaryLight,
                        decoration: TextDecoration.underline,
                        decorationColor:
                            isDark ? AppColors.primaryDark : AppColors.primaryLight,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (subLabel != null)
              Text(
                subLabel!,
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                ),
              ),
          ],
        ),
      ],
    );
  }

  void _showError(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Generation Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ── Video preview area ────────────────────────────────────────────────────────

class _VideoPreviewArea extends StatelessWidget {
  const _VideoPreviewArea({required this.sceneDirPath});

  final String sceneDirPath;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final videoFile = File(p.join(sceneDirPath, 'video.mp4'));
    // Use the first frame as thumbnail — show video file's icon since we can't
    // decode video frames without a video player package. Use a placeholder card
    // with a play icon overlay.
    return GestureDetector(
      onTap: () => context.push(
        Uri(
          path: '/player',
          queryParameters: {
            'path': Uri.encodeComponent(videoFile.path),
            'title': 'Scene ${p.basename(sceneDirPath)}',
          },
        ).toString(),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
        width: double.infinity,
        height: 180,
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
          borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Try to show a file thumbnail (placeholder since video thumbnails
            // need a plugin). Show the video path label.
            Positioned(
              bottom: AppSpacing.s2,
              left: AppSpacing.s3,
              child: Text(
                'video.mp4',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                ),
              ),
            ),
            // Play button overlay.
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: primaryColor,
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.play,
                color: isDark ? AppColors.primaryOnDark : AppColors.primaryOnLight,
                size: AppSizing.iconMd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Generate Video button ─────────────────────────────────────────────────────

class _GenerateVideoButton extends StatelessWidget {
  const _GenerateVideoButton({required this.state});

  final SceneLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final isGenerating = state.isGeneratingVideo;
    final hasStoryboard = state.storyboard.storyboardBody.isNotEmpty;
    final isDisabled = !hasStoryboard || isGenerating;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4,
          AppSpacing.s2,
          AppSpacing.s4,
          AppSpacing.s4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: isDisabled ? null : () => _onTap(context),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(AppSizing.buttonMd),
                backgroundColor: Colors.transparent,
                side: BorderSide(
                  color: isDisabled ? Colors.transparent : primaryColor,
                ),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSizing.radiusSm),
                ),
              ),
              child: isGenerating
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: primaryColor),
                        ),
                        const SizedBox(width: AppSpacing.s2),
                        Text(
                          'Generating...',
                          style: AppTextStyles.body(context)
                              .copyWith(color: primaryColor),
                        ),
                      ],
                    )
                  : Text(
                      state.hasVideo ? 'Regenerate Video' : 'Generate Video',
                      style: AppTextStyles.body(context).copyWith(
                        color: isDisabled
                            ? (isDark
                                ? AppColors.textTertiaryDark
                                : AppColors.textTertiaryLight)
                            : primaryColor,
                      ),
                    ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              '${CreditCost.videoGeneration} credits',
              style: AppTextStyles.caption(context),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTap(BuildContext context) async {
    // Confirm overwrite if video already exists.
    if (state.hasVideo) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Regenerate Video?'),
          content: const Text(
            'This will replace the existing video.mp4 and use '
            '${CreditCost.videoGeneration} credits.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Regenerate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    // Warn if many character assets.
    final charAssets = state.assets
        .where((a) => !a.isPassThrough &&
            a.type == AssetType.character &&
            a.hasImage)
        .toList();
    if (charAssets.length > 4) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Many Character Assets'),
          content: Text(
            'This scene has ${charAssets.length} character assets with reference images. '
            'Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    context.read<SceneCubit>().generateVideo();
  }
}

// ── Error body ────────────────────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: AppTextStyles.body(context)),
            const SizedBox(height: AppSpacing.s4),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Color _surfaceBase(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? AppColors.surfaceBaseDark : AppColors.surfaceBaseLight;
}
