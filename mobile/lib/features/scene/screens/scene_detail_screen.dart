import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';
import '../cubit/scene_cubit.dart';
import '../cubit/scene_state.dart';

/// Scene Detail Screen — FEAT-014 (Generate Storyboard), FEAT-015
/// (Storyboard MDX Editor), FEAT-016 (Generate Scene Video).
///
/// Route: `/project/:projectName/scene/:sceneId`
///
/// Phase 2: All data comes from Firestore real-time listeners in [SceneCubit].
/// No local filesystem reads or Timer.periodic polling.
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
        projectSlug: projectName,
        sceneNumber: sceneId,
        apiClient: services.apiClient,
        jobsCubit: services.jobsCubit,
      )..load(),
      child: _SceneDetailView(
        projectName: projectName,
        sceneId: sceneId,
      ),
    );
  }
}

// ── Root view ─────────────────────────────────────────────────────────────────

class _SceneDetailView extends StatefulWidget {
  const _SceneDetailView({
    required this.projectName,
    required this.sceneId,
  });

  final String projectName;
  final int sceneId;

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

        // Sync tab controller with cubit's selected tab index.
        if (_tabController.index != state.selectedTabIndex) {
          _tabController.animateTo(state.selectedTabIndex);
        }

        // Handle storyboard errors.
        final sbErr = state.storyboardError;
        if (sbErr != null) {
          if (sbErr == '__credits__') {
            showCreditsExhaustedDialog(context);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sbErr),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () =>
                      context.read<SceneCubit>().generateStoryboard(),
                ),
              ),
            );
          }
          context.read<SceneCubit>().clearStoryboardError();
        }

        // Handle video errors.
        final vidErr = state.videoError;
        if (vidErr != null) {
          if (vidErr == '__credits__') {
            showCreditsExhaustedDialog(context);
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
          ),
          body: switch (state) {
            SceneLoading() =>
              const Center(child: CircularProgressIndicator()),
            SceneError(:final message) => _ErrorBody(
                message: message,
                onRetry: () => context.read<SceneCubit>().load(),
              ),
            SceneLoaded() => _LoadedBody(
                state: state,
                projectName: widget.projectName,
                tabController: _tabController,
              ),
          },
        );
      },
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _SceneAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SceneAppBar({
    required this.sceneId,
    required this.state,
  });

  final int sceneId;
  final SceneState state;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final loaded = state is SceneLoaded ? state as SceneLoaded : null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Derive status dot color from cubit state flags (derived live from JobsCubit — no per-widget dependency needed).
    final Color dotColor;
    if (loaded != null) {
      if (loaded.isGeneratingStoryboard || loaded.isGeneratingVideo) {
        dotColor =
            isDark ? AppColors.stateRunningDark : AppColors.stateRunningLight;
      } else if (loaded.hasVideo) {
        dotColor = isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight;
      } else if (loaded.hasStoryboard) {
        dotColor = isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight;
      } else {
        dotColor =
            isDark ? AppColors.statePendingDark : AppColors.statePendingLight;
      }
    } else {
      dotColor =
          isDark ? AppColors.statePendingDark : AppColors.statePendingLight;
    }

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
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.s3),
      ],
    );
  }
}

// ── Loaded body ───────────────────────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({
    required this.state,
    required this.projectName,
    required this.tabController,
  });

  final SceneLoaded state;
  final String projectName;
  final TabController tabController;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CustomTabBar(controller: tabController),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              _AssetsTab(
                state: state,
                projectName: projectName,
              ),
              _StoryboardTab(state: state),
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
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final surfaceRaised =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

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
        : (isDark
            ? AppColors.textSecondaryDark
            : AppColors.textSecondaryLight);

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding:
              const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          decoration: isActive
              ? BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: primaryColor, width: 2),
                  ),
                )
              : null,
          child: Text(
            label,
            style:
                AppTextStyles.body(context).copyWith(color: textColor),
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
  });

  final SceneLoaded state;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Storyboard generation is blocked until every asset has a GCS image.
    final isBlocked = !state.allAssetsHaveImages;

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
                    style: AppTextStyles.caption(context)
                        .copyWith(letterSpacing: 0.8),
                  ),
                  const Spacer(),
                  Text(
                    '${state.assets.length} assets',
                    style: AppTextStyles.caption(context),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),

              // Banner shown when one or more assets are missing images.
              if (isBlocked && state.assets.isNotEmpty)
                _MissingImagesBanner(
                  missing: state.assets
                      .where((a) => a.gcsImagePath == null)
                      .toList(),
                ),

              // Asset list.
              if (state.assets.isEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: AppSpacing.s6),
                  child: Center(
                    child: Text(
                      'No assets in this scene.',
                      style: AppTextStyles.body(context).copyWith(
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondaryLight,
                      ),
                    ),
                  ),
                )
              else
                ...state.assets.map(
                  (asset) => _AssetRow(
                    asset: asset,
                    projectName: projectName,
                  ),
                ),

              const SizedBox(height: AppSpacing.s4),

              // Scene text expansion tile.
              _SceneTextTile(sceneText: state.sceneText ?? ''),

              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),

        // Generate Storyboard button pinned to bottom.
        _GenerateStoryboardButton(
          state: state,
          isBlocked: isBlocked,
        ),
      ],
    );
  }
}

// ── Missing images warning banner ─────────────────────────────────────────────

class _MissingImagesBanner extends StatelessWidget {
  const _MissingImagesBanner({required this.missing});

  final List<SceneAsset> missing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warningColor =
        isDark ? AppColors.warningDark : AppColors.warningLight;
    final surfaceOverlay = isDark
        ? AppColors.surfaceOverlayDark
        : AppColors.surfaceOverlayLight;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: surfaceOverlay,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        border: Border(left: BorderSide(color: warningColor, width: 3)),
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          Icon(LucideIcons.triangleAlert,
              size: AppSizing.iconSm, color: warningColor),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              '${missing.length} asset${missing.length == 1 ? '' : 's'} '
              '${missing.length == 1 ? 'is' : 'are'} missing a generated '
              'image. Generate images for all assets first.',
              style: AppTextStyles.bodySmall(context)
                  .copyWith(color: warningColor),
            ),
          ),
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
  });

  final SceneAsset asset;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final surfaceRaised =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Material(
        color: surfaceRaised,
        borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        // Phase 2: asset navigation path is not yet defined for Firestore-based
        // asset IDs. Asset rows are non-tappable until the asset editor migrates.
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
            child: Row(
              children: [
                // Thumbnail: fetch presigned URL from GCS path.
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppSizing.radiusXs),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: asset.gcsImagePath != null
                        ? _GcsImageThumbnail(gcsPath: asset.gcsImagePath!)
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
                        asset.displayName,
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

                // Status dot: filled = has image, outlined = pending.
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: asset.gcsImagePath != null
                        ? (isDark
                            ? AppColors.stateDoneDark
                            : AppColors.stateDoneLight)
                        : null,
                    border: asset.gcsImagePath == null
                        ? Border.all(
                            color: isDark
                                ? AppColors.statePendingDark
                                : AppColors.statePendingLight,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _greyPlaceholder(bool isDark) => Container(
        color: isDark
            ? AppColors.surfaceOverlayDark
            : AppColors.surfaceOverlayLight,
        child: Icon(
          LucideIcons.image,
          size: 16,
          color: isDark
              ? AppColors.textTertiaryDark
              : AppColors.textTertiaryLight,
        ),
      );
}

/// Fetches a presigned GCS URL once and renders the image.
///
/// Uses a [StatefulWidget] to cache the [Future] so it does not refire on
/// every parent rebuild (a raw [FutureBuilder] passed `apiClient.getPresignedUrl()`
/// directly would create a new Future on each build).
class _GcsImageThumbnail extends StatefulWidget {
  const _GcsImageThumbnail({required this.gcsPath});

  final String gcsPath;

  @override
  State<_GcsImageThumbnail> createState() => _GcsImageThumbnailState();
}

class _GcsImageThumbnailState extends State<_GcsImageThumbnail> {
  // Initialised in didChangeDependencies (first call after initState completes)
  // to avoid calling ArkMaskServices.of(context) before the widget is in tree.
  Future<String>? _urlFuture;
  String? _lastGcsPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Fetch once on first mount, then only when the GCS path changes.
    if (_lastGcsPath != widget.gcsPath) {
      _lastGcsPath = widget.gcsPath;
      _urlFuture = _fetchUrl();
    }
  }

  @override
  void didUpdateWidget(_GcsImageThumbnail old) {
    super.didUpdateWidget(old);
    // Re-fetch if the GCS path changed (e.g., after regeneration).
    if (old.gcsPath != widget.gcsPath) {
      _lastGcsPath = widget.gcsPath;
      _urlFuture = _fetchUrl();
    }
  }

  Future<String> _fetchUrl() {
    final apiClient = ArkMaskServices.of(context).apiClient;
    return apiClient.getPresignedUrl(gcsPath: widget.gcsPath);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (context, snap) {
        if (snap.hasData) {
          return Image.network(
            snap.data!,
            fit: BoxFit.cover,
            errorBuilder: (ctx, err, stack) => _placeholder(isDark),
          );
        }
        // Loading or error — show placeholder.
        return _placeholder(isDark);
      },
    );
  }

  Widget _placeholder(bool isDark) => Container(
        color: isDark
            ? AppColors.surfaceOverlayDark
            : AppColors.surfaceOverlayLight,
        child: Icon(
          LucideIcons.image,
          size: 16,
          color: isDark
              ? AppColors.textTertiaryDark
              : AppColors.textTertiaryLight,
        ),
      );
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

    final String label;
    final Color bgColor;
    final Color textColor;

    if (asset.isPassThrough) {
      // Pass-through: delegates image to the referenced global asset.
      label = 'Pass-through';
      bgColor = primaryColor.withValues(alpha: 0.15);
      textColor = primaryColor;
    } else if (asset.ref != null && asset.description.isNotEmpty) {
      // Variant: references another asset but has its own description.
      label = 'Variant';
      bgColor = isDark
          ? AppColors.surfaceOverlayDark
          : AppColors.surfaceOverlayLight;
      textColor = isDark
          ? AppColors.textSecondaryDark
          : AppColors.textSecondaryLight;
    } else {
      // Local: independent asset owned by this scene.
      label = 'Scene';
      bgColor = isDark
          ? AppColors.surfaceOverlayDark
          : AppColors.surfaceOverlayLight;
      textColor = isDark
          ? AppColors.textSecondaryDark
          : AppColors.textSecondaryLight;
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
      title: Text('Scene Text', style: AppTextStyles.h3(context)),
      tilePadding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s4),
          child: Text(
            sceneText.isEmpty ? 'No story text found.' : sceneText,
            style: AppTextStyles.bodyLarge(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
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

  /// True when assets are missing images — blocks storyboard generation.
  final bool isBlocked;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final isGenerating = state.isGeneratingStoryboard;
    final isDisabled = isBlocked || isGenerating;
    final hasExisting = state.hasStoryboard;

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
                    ? (isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiaryLight)
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
                message:
                    'All asset images must be generated before creating a storyboard.',
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
    // Warn if many character assets (may affect generation quality).
    final charAssets = state.assets
        .where((a) =>
            !a.isPassThrough &&
            a.type == AssetType.character &&
            a.gcsImagePath != null)
        .toList();
    if (charAssets.length > 4) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Many Character Assets'),
          content: Text(
            'This scene has ${charAssets.length} character assets with '
            'reference images. This may affect generation quality. Continue?',
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
  const _StoryboardTab({required this.state});

  final SceneLoaded state;

  static const double _storyboardBoxHeight = 320;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          // Scrollable, with the storyboard box given a fixed height instead
          // of Expanded/expands filling whatever space is left: with the
          // storyboard now editable (FEAT-015), opening the keyboard shrinks
          // this Expanded's available height (Scaffold resizeToAvoidBottomInset),
          // and the fixed-size siblings below (status strip, 180px video
          // preview) used to eat nearly all of what remained, squeezing the
          // text field to near zero. A fixed height inside a scroll view lets
          // the column overflow into scroll instead of being crushed, and
          // Flutter auto-scrolls the focused field above the keyboard.
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: _storyboardBoxHeight,
                  child: state.hasStoryboard
                      ? _StoryboardDisplay(
                          storyboardBody: state.storyboardBody!,
                        )
                      : _EmptyStoryboardState(),
                ),

                // Generation status strip — driven by cubit state, derived live from JobsCubit.
                _GenerationStatusStrip(state: state),

                // Video preview: shows a card with a play button when video is ready.
                if (state.hasVideo)
                  _VideoPreviewArea(
                    gcsVideoPath: state.gcsVideoPath!,
                  ),
              ],
            ),
          ),
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
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

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
          Text('No storyboard yet', style: AppTextStyles.h3(context)),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'Generate a storyboard from the Assets tab.',
            style: AppTextStyles.body(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Storyboard display ────────────────────────────────────────────────────────

/// Editable display of the storyboard body written by the backend (FEAT-015).
///
/// The storyboard lives in Firestore (`storyboard_body`); the Firestore
/// listener in [SceneCubit] delivers updates automatically (e.g. after
/// (re)generation). User edits are persisted on focus loss — same
/// save-on-blur pattern as an asset's description/prompt fields (see
/// `_PromptBodySection` in asset_editor_screen.dart) — since a multiline
/// field's keyboard shows "newline" rather than "done", making focus loss
/// the only reliable signal that editing has ended.
class _StoryboardDisplay extends StatefulWidget {
  const _StoryboardDisplay({required this.storyboardBody});

  final String storyboardBody;

  @override
  State<_StoryboardDisplay> createState() => _StoryboardDisplayState();
}

class _StoryboardDisplayState extends State<_StoryboardDisplay> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.storyboardBody);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _save();
  }

  void _save() {
    if (!mounted) return;
    if (_controller.text != widget.storyboardBody) {
      context.read<SceneCubit>().onStoryboardBodyChanged(_controller.text);
    }
  }

  @override
  void didUpdateWidget(_StoryboardDisplay old) {
    super.didUpdateWidget(old);
    // Keep the display in sync when the Firestore listener delivers new text
    // (e.g. after (re)generation) — but never clobber active local edits.
    if (old.storyboardBody != widget.storyboardBody &&
        _controller.text != widget.storyboardBody &&
        !_focusNode.hasFocus) {
      _controller.text = widget.storyboardBody;
    }
  }

  @override
  void dispose() {
    // Flush any pending edit if the widget is torn down (e.g. user navigates
    // back or switches tabs) without the field ever losing focus first.
    _save();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
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
        focusNode: _focusNode,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: AppTextStyles.monoBody(context),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

// ── Generation status strip ───────────────────────────────────────────────────

/// Shows the storyboard and video generation status driven by [SceneLoaded]
/// state — no direct JobsCubit dependency — the flags are already resolved by SceneCubit.
class _GenerationStatusStrip extends StatefulWidget {
  const _GenerationStatusStrip({required this.state});

  final SceneLoaded state;

  @override
  State<_GenerationStatusStrip> createState() =>
      _GenerationStatusStripState();
}

class _GenerationStatusStripState extends State<_GenerationStatusStrip>
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
    final hasRunning = widget.state.isGeneratingStoryboard ||
        widget.state.isGeneratingVideo;

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
          _StatusDot(
            icon: LucideIcons.scroll,
            label: 'Storyboard',
            isRunning: widget.state.isGeneratingStoryboard,
            isDone: widget.state.hasStoryboard,
            scaleAnim: _scaleAnim,
            subLabel: widget.state.isGeneratingStoryboard
                ? 'Generating…'
                : null,
          ),
          const SizedBox(width: AppSpacing.s6),
          _StatusDot(
            icon: LucideIcons.video,
            label: 'Video',
            isRunning: widget.state.isGeneratingVideo,
            isDone: widget.state.hasVideo,
            scaleAnim: _scaleAnim,
            subLabel: widget.state.isGeneratingVideo
                ? 'This may take a few minutes.'
                : null,
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.icon,
    required this.label,
    required this.isRunning,
    required this.isDone,
    required this.scaleAnim,
    this.subLabel,
  });

  final IconData icon;
  final String label;
  final bool isRunning;
  final bool isDone;
  final Animation<double> scaleAnim;
  final String? subLabel;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color color;
    if (isRunning) {
      color = isDark ? AppColors.stateRunningDark : AppColors.stateRunningLight;
    } else if (isDone) {
      color = isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight;
    } else {
      color = isDark ? AppColors.statePendingDark : AppColors.statePendingLight;
    }

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        isRunning
            ? AnimatedBuilder(
                animation: scaleAnim,
                builder: (_, child) =>
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
                    style:
                        AppTextStyles.caption(context).copyWith(color: color)),
              ],
            ),
            if (subLabel != null)
              Text(
                subLabel!,
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiaryLight,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Video preview area ────────────────────────────────────────────────────────

/// Shows a play-button card that navigates to the video player.
///
/// Phase 2: Fetches a presigned GCS URL and passes it to the `/player` route
/// (which accepts a `path` query param that can be either a filesystem path or
/// a presigned URL — see router.dart).
class _VideoPreviewArea extends StatefulWidget {
  const _VideoPreviewArea({required this.gcsVideoPath});

  final String gcsVideoPath;

  @override
  State<_VideoPreviewArea> createState() => _VideoPreviewAreaState();
}

class _VideoPreviewAreaState extends State<_VideoPreviewArea> {
  // Initialised in didChangeDependencies to avoid calling
  // ArkMaskServices.of(context) before the widget is in the tree.
  Future<String>? _urlFuture;
  String? _lastGcsVideoPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lastGcsVideoPath != widget.gcsVideoPath) {
      _lastGcsVideoPath = widget.gcsVideoPath;
      _urlFuture = _fetchUrl();
    }
  }

  @override
  void didUpdateWidget(_VideoPreviewArea old) {
    super.didUpdateWidget(old);
    if (old.gcsVideoPath != widget.gcsVideoPath) {
      _lastGcsVideoPath = widget.gcsVideoPath;
      _urlFuture = _fetchUrl();
    }
  }

  Future<String> _fetchUrl() {
    final apiClient = ArkMaskServices.of(context).apiClient;
    return apiClient.getPresignedUrl(gcsPath: widget.gcsVideoPath);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (context, snap) {
        return GestureDetector(
          onTap: snap.hasData
              ? () => context.push(
                    Uri(
                      path: '/player',
                      queryParameters: {
                        'path': Uri.encodeComponent(snap.data!),
                        'title': 'Scene ${widget.gcsVideoPath.split('/').last}',
                      },
                    ).toString(),
                  )
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
            width: double.infinity,
            height: 180,
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.surfaceSunkenDark
                  : AppColors.surfaceSunkenLight,
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (snap.connectionState == ConnectionState.waiting)
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: primaryColor),
                  )
                else ...[
                  Positioned(
                    bottom: AppSpacing.s2,
                    left: AppSpacing.s3,
                    child: Text(
                      'video.mp4',
                      style: AppTextStyles.caption(context).copyWith(
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiaryLight,
                      ),
                    ),
                  ),
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.play,
                      color: isDark
                          ? AppColors.primaryOnDark
                          : AppColors.primaryOnLight,
                      size: AppSizing.iconMd,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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
    final primaryColor =
        isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final isGenerating = state.isGeneratingVideo;
    final isDisabled = !state.hasStoryboard || isGenerating;

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
                          'Generating…',
                          style: AppTextStyles.body(context)
                              .copyWith(color: primaryColor),
                        ),
                      ],
                    )
                  : Text(
                      state.hasVideo
                          ? 'Regenerate Video'
                          : 'Generate Video',
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
    // Confirm overwrite when a video already exists.
    if (state.hasVideo) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Regenerate Video?'),
          content: const Text(
            'This will replace the existing video and use '
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

    // Warn when many character assets are present.
    final charAssets = state.assets
        .where((a) =>
            !a.isPassThrough &&
            a.type == AssetType.character &&
            a.gcsImagePath != null)
        .toList();
    if (charAssets.length > 4) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Many Character Assets'),
          content: Text(
            'This scene has ${charAssets.length} character assets with '
            'reference images. Continue?',
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
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
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
