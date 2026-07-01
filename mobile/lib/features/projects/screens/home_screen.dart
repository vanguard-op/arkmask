import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../cubit/projects_cubit.dart';
import '../cubit/projects_state.dart';
import '../widgets/new_project_bottom_sheet.dart';
import '../widgets/project_card.dart';

/// Home / Projects List Screen (FEAT-006).
///
/// Listens to the Firestore `users/{uid}/projects` collection in real-time via
/// [ProjectsCubit]. The FAB opens [NewProjectBottomSheet] which calls
/// `POST /projects` and navigates to the new project's file browser on success.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => ProjectsCubit(
        apiClient: services.apiClient,
        jobRegistryService: services.jobRegistryService,
      )..load(),
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> {
  @override
  void initState() {
    super.initState();
    // Defer so ArkMaskServices.of(context) can resolve after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkProviderSetup();
    });
  }

  Future<void> _checkProviderSetup() async {
    final services = ArkMaskServices.of(context);
    final hasProvider = await services.storage.hasProviderCredentials();
    if (!hasProvider && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Complete provider setup to start generating.'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => context.push(Routes.settings),
          ),
        ),
      );
    }
  }

  void _showNewProjectSheet(BuildContext context) {
    final services = ArkMaskServices.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      builder: (_) => NewProjectBottomSheet(
        apiClient: services.apiClient,
        onCreated: (slug) {
          // The Firestore listener in ProjectsCubit automatically adds the new
          // project to the list — no manual refresh call needed.
          context.push(
            Routes.projectBrowser
                .replaceFirst(':projectName', Uri.encodeComponent(slug)),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProjectsCubit, ProjectsState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(
              'ArkMask',
              style: AppTextStyles.h2(context),
            ),
            actions: [
              _CreditPill(state: state),
              const SizedBox(width: AppSpacing.s2),
              IconButton(
                icon: const Icon(LucideIcons.settings),
                tooltip: 'Settings',
                onPressed: () => context.push(Routes.settings),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showNewProjectSheet(context),
            tooltip: 'New Project',
            child: const Icon(LucideIcons.plus),
          ),
          body: switch (state) {
            ProjectsLoading() => const _SkeletonList(),
            ProjectsError(:final message) => _ErrorView(message: message),
            ProjectsLoaded() => state.projects.isEmpty
                ? const _EmptyState()
                : _ProjectList(state: state),
          },
        );
      },
    );
  }
}

// ── Credit balance pill ───────────────────────────────────────────────────────

class _CreditPill extends StatelessWidget {
  const _CreditPill({required this.state});
  final ProjectsState state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    int? balance;
    UserTier? tier;
    if (state is ProjectsLoaded) {
      balance = (state as ProjectsLoaded).creditBalance;
      tier = (state as ProjectsLoaded).tier;
    }

    Color textColor;
    if (balance == null) {
      textColor =
          isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    } else if (balance == 0) {
      textColor = isDark ? AppColors.errorDark : AppColors.errorLight;
    } else {
      final fraction = tier != null ? balance / tier.monthlyCredits : 1.0;
      textColor = fraction <= 0.2
          ? (isDark ? AppColors.warningDark : AppColors.warningLight)
          : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight);
    }

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3, vertical: AppSpacing.s1),
      decoration: BoxDecoration(
        color: isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight,
        borderRadius: BorderRadius.circular(AppSizing.radiusFull),
      ),
      child: Text(
        balance != null ? formatCredits(balance) : '--',
        style: AppTextStyles.caption(context).copyWith(color: textColor),
      ),
    );
  }
}

// ── Project list ──────────────────────────────────────────────────────────────

class _ProjectList extends StatelessWidget {
  const _ProjectList({required this.state});
  final ProjectsLoaded state;

  @override
  Widget build(BuildContext context) {
    // Surface rename errors as a one-time SnackBar.
    if (state.renameError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Rename failed: ${state.renameError}')),
          );
        }
      });
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s4,
      ),
      itemCount: state.projects.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s3),
      itemBuilder: (context, index) {
        final project = state.projects[index];
        final isDeleting = state.deletingSlug == project.slug;
        return ProjectCard(
          project: project,
          isDeleting: isDeleting,
          generatingCount: state.generatingCounts[project.slug] ?? 0,
          storageSummary: state.storageSummaries[project.slug],
          onTap: () => context.push(
            Routes.projectBrowser.replaceFirst(
              ':projectName',
              Uri.encodeComponent(project.slug),
            ),
          ),
          onDeleteConfirmed: () =>
              context.read<ProjectsCubit>().deleteProject(project.slug),
          onRenameConfirmed: (newName) =>
              context.read<ProjectsCubit>().renameProject(project.slug, newName),
        );
      },
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.film,
              size: AppSizing.iconLg,
              color: primaryColor.withValues(alpha: 0.4),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'No projects yet',
              style: AppTextStyles.h2(context).copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Tap + to create your first project.',
              style: AppTextStyles.body(context).copyWith(
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiaryLight,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Skeleton loading ──────────────────────────────────────────────────────────

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s4,
      ),
      itemCount: 3,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s3),
      itemBuilder: (_, _) => const _SkeletonCard(),
    );
  }
}

class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard();

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 0.8).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Container(
        height: 80,
        decoration: BoxDecoration(
          color: base.withValues(alpha: _anim.value),
          borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        ),
      ),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: AppTextStyles.body(context)),
          const SizedBox(height: AppSpacing.s4),
          ElevatedButton(
            onPressed: () => context.read<ProjectsCubit>().load(),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
