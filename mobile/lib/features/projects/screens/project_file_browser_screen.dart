import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../cubit/file_browser_cubit.dart';
import '../cubit/file_browser_state.dart';
import '../widgets/file_browser_row.dart';
import '../widgets/generation_step_dots.dart';

/// Project File Browser Screen — Obsidian-style collapsible file tree
/// (FEAT-005).
///
/// Entry point for all project-level navigation: story editor, asset editor,
/// scene detail, video editor. Tree folders remember their expand state.
///
/// The [projectSlug] path parameter is the immutable Firestore document ID —
/// it is passed to [FileBrowserCubit.load] which subscribes to Firestore
/// real-time listeners. Navigation to child screens also encodes the slug in
/// the URL so Phase 2 screens can resolve Firestore paths from it.
class ProjectFileBrowserScreen extends StatelessWidget {
  const ProjectFileBrowserScreen({super.key, required this.projectSlug});

  /// Immutable project slug (URL-decoded Firestore document ID).
  final String projectSlug;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => FileBrowserCubit()..load(projectSlug),
      child: _FileBrowserView(projectSlug: projectSlug),
    );
  }
}

class _FileBrowserView extends StatelessWidget {
  const _FileBrowserView({required this.projectSlug});

  final String projectSlug;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BlocBuilder<FileBrowserCubit, FileBrowserState>(
      builder: (context, state) {
        // Use the display name from Firestore for the AppBar title when loaded.
        final title = state is FileBrowserLoaded
            ? state.tree.displayName
            : projectSlug;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: 'Back to projects',
              onPressed: () => context.go(Routes.home),
            ),
            title: Text(
              title,
              style: AppTextStyles.h2(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                icon: const Icon(LucideIcons.film),
                tooltip: 'Video Editor',
                onPressed: () => context.push(
                  Routes.videoEditor.replaceFirst(
                    ':projectName',
                    Uri.encodeComponent(projectSlug),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.settings),
                tooltip: 'Settings',
                onPressed: () => context.push(Routes.settings),
              ),
            ],
          ),
          body: switch (state) {
            FileBrowserLoading() => const _SkeletonTree(),
            FileBrowserError(:final message) => _ErrorView(
                message: message,
                onRetry: () =>
                    context.read<FileBrowserCubit>().load(projectSlug),
              ),
            FileBrowserLoaded() =>
              _TreeView(state: state, projectSlug: projectSlug, isDark: isDark),
          },
        );
      },
    );
  }
}

// ── Tree view ─────────────────────────────────────────────────────────────────

class _TreeView extends StatelessWidget {
  const _TreeView({
    required this.state,
    required this.projectSlug,
    required this.isDark,
  });

  final FileBrowserLoaded state;
  final String projectSlug;
  final bool isDark;

  // ── Route helper: Phase 2 screens use projectSlug as the :projectName param.

  String _assetEditorPath(String assetId) => Routes.assetEditor
      .replaceFirst(':projectName', Uri.encodeComponent(projectSlug))
      .replaceFirst(':assetPath', Uri.encodeComponent(assetId));

  String _sceneDetailPath(int sceneNumber) => Routes.sceneDetail
      .replaceFirst(':projectName', Uri.encodeComponent(projectSlug))
      .replaceFirst(':sceneId', sceneNumber.toString());

  @override
  Widget build(BuildContext context) {
    final tree = state.tree;
    final expanded = state.expandedIds;

    // Logical IDs for the two top-level folders.
    const assetsKey = '__assets__';
    const scenesKey = '__scenes__';

    final List<Widget> rows = [];

    // ── story.mdx (Phase 2: opens story editor) ────────────────────────────
    rows.add(FileBrowserRow(
      label: 'story.mdx',
      icon: LucideIcons.fileText,
      depth: 0,
      isSelected: state.selectedId == '__story__',
      onTap: () async {
        context.read<FileBrowserCubit>().select('__story__');
        await context.push(Routes.storyEditor
            .replaceFirst(':projectName', Uri.encodeComponent(projectSlug)));
        if (context.mounted) {
          context.read<FileBrowserCubit>().load(projectSlug);
        }
      },
    ));

    // ── final.mp4 (shown once merge worker writes gcs_final_path) ─────────
    if (tree.gcsFinalPath != null) {
      rows.add(FileBrowserRow(
        label: 'final.mp4',
        icon: LucideIcons.fileVideo,
        depth: 0,
        onTap: () => context.push(
          Uri(
            path: Routes.videoPlayer,
            queryParameters: {
              // Phase 3: resolve presigned URL from gcs_final_path before
              // navigating. For now, pass the GCS path directly — the video
              // player will receive it in the `path` param and Phase 3 will
              // update it to resolve a fresh presigned URL first.
              'path': Uri.encodeComponent(tree.gcsFinalPath!),
              'title': 'final.mp4',
            },
          ).toString(),
        ),
      ));
    }

    // ── assets/ ────────────────────────────────────────────────────────────
    rows.add(FileBrowserRow(
      label: 'assets',
      icon: expanded.contains(assetsKey)
          ? LucideIcons.folderOpen
          : LucideIcons.folder,
      depth: 0,
      isFolder: true,
      isExpanded: expanded.contains(assetsKey),
      onTap: () =>
          context.read<FileBrowserCubit>().toggleExpand(assetsKey),
      onToggleExpand: () =>
          context.read<FileBrowserCubit>().toggleExpand(assetsKey),
    ));

    if (expanded.contains(assetsKey)) {
      if (tree.globalAssets.isEmpty) {
        rows.add(_EmptyFolderRow(depth: 1, isDark: isDark));
      } else {
        for (final asset in tree.globalAssets) {
          rows.add(FileBrowserRow(
            label: asset.name,
            icon: asset.hasImage ? LucideIcons.image : LucideIcons.image,
            depth: 1,
            isSelected: state.selectedId == asset.id,
            steps: [
              asset.hasPromptBody
                  ? GenerationStepState.done
                  : GenerationStepState.pending,
              asset.hasImage
                  ? GenerationStepState.done
                  : GenerationStepState.pending,
            ],
            onTap: () async {
              context.read<FileBrowserCubit>().select(asset.id);
              await context.push(_assetEditorPath(asset.id));
              if (context.mounted) {
                context.read<FileBrowserCubit>().load(projectSlug);
              }
            },
          ));
        }
      }
    }

    // ── scenes/ ───────────────────────────────────────────────────────────
    rows.add(FileBrowserRow(
      label: 'scenes',
      icon: expanded.contains(scenesKey)
          ? LucideIcons.folderOpen
          : LucideIcons.film,
      depth: 0,
      isFolder: true,
      isExpanded: expanded.contains(scenesKey),
      onTap: () =>
          context.read<FileBrowserCubit>().toggleExpand(scenesKey),
      onToggleExpand: () =>
          context.read<FileBrowserCubit>().toggleExpand(scenesKey),
    ));

    if (expanded.contains(scenesKey)) {
      if (tree.scenes.isEmpty) {
        rows.add(_EmptyFolderRow(depth: 1, isDark: isDark));
      } else {
        for (final scene in tree.scenes) {
          rows.add(FileBrowserRow(
            label: 'Scene ${scene.sceneNumber}',
            icon: scene.hasVideo ? LucideIcons.video : LucideIcons.film,
            depth: 1,
            isFolder: true,
            isExpanded: expanded.contains(scene.id),
            steps: [
              scene.hasStoryboard
                  ? GenerationStepState.done
                  : GenerationStepState.pending,
              scene.hasVideo
                  ? GenerationStepState.done
                  : GenerationStepState.pending,
            ],
            onTap: () async {
              context.read<FileBrowserCubit>().toggleExpand(scene.id);
              await context.push(_sceneDetailPath(scene.sceneNumber));
              if (context.mounted) {
                context.read<FileBrowserCubit>().load(projectSlug);
              }
            },
            onToggleExpand: () =>
                context.read<FileBrowserCubit>().toggleExpand(scene.id),
          ));

          if (expanded.contains(scene.id)) {
            // Scene-local assets.
            for (final asset in scene.assets) {
              rows.add(FileBrowserRow(
                label: asset.name,
                icon: LucideIcons.image,
                depth: 2,
                isSelected: state.selectedId == asset.id,
                badge: AssetReferenceBadge(
                  assetName: asset.name,
                  description: asset.description,
                ),
                steps: asset.isPassThrough
                    ? null
                    : [
                        asset.hasPromptBody
                            ? GenerationStepState.done
                            : GenerationStepState.pending,
                        asset.hasImage
                            ? GenerationStepState.done
                            : GenerationStepState.pending,
                      ],
                onTap: () async {
                  context.read<FileBrowserCubit>().select(asset.id);
                  await context.push(_assetEditorPath(asset.id));
                  if (context.mounted) {
                    context.read<FileBrowserCubit>().load(projectSlug);
                  }
                },
              ));
            }

            // ark.mdx (storyboard) — navigates to scene detail.
            rows.add(FileBrowserRow(
              label: 'ark.mdx',
              icon: LucideIcons.scrollText,
              depth: 2,
              onTap: () async {
                await context.push(_sceneDetailPath(scene.sceneNumber));
                if (context.mounted) {
                  context.read<FileBrowserCubit>().load(projectSlug);
                }
              },
            ));

            // video.mp4 (only shown once gcs_video_path is set by the worker).
            if (scene.hasVideo && scene.gcsVideoPath != null) {
              rows.add(FileBrowserRow(
                label: 'video.mp4',
                icon: LucideIcons.video,
                depth: 2,
                onTap: () => context.push(
                  Uri(
                    path: Routes.videoPlayer,
                    queryParameters: {
                      // Phase 3: resolve presigned URL from gcsVideoPath before
                      // navigating. Passes the GCS path for now.
                      'path': Uri.encodeComponent(scene.gcsVideoPath!),
                      'title': 'Scene ${scene.sceneNumber}',
                    },
                  ).toString(),
                ),
              ));
            }
          }
        }
      }
    }

    return Stack(
      children: [
        ListView(children: rows),
        // ── Extract Assets CTA (blank project with story content) ──────────
        if (tree.isBlank && tree.storyHasContent)
          Positioned(
            left: AppSpacing.s4,
            right: AppSpacing.s4,
            bottom: AppSpacing.s6,
            child: _ExtractAssetsButton(
              onTap: () async {
                await context.push(Routes.storyEditor.replaceFirst(
                  ':projectName',
                  Uri.encodeComponent(projectSlug),
                ));
                if (context.mounted) {
                  context.read<FileBrowserCubit>().load(projectSlug);
                }
              },
              isDark: isDark,
            ),
          ),
        // ── New project hint (no story, no assets, no scenes) ──────────────
        if (tree.isBlank && !tree.storyHasContent)
          Positioned(
            bottom: AppSpacing.s8,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'Open story.mdx to start writing.',
                style: AppTextStyles.body(context).copyWith(
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiaryLight,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

class _EmptyFolderRow extends StatelessWidget {
  const _EmptyFolderRow({required this.depth, required this.isDark});

  final int depth;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizing.fileBrowserRow,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.s3 +
              depth * AppSpacing.s4 +
              AppSizing.iconMd +
              AppSpacing.s2,
          right: AppSpacing.s3,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '(empty)',
            style: AppTextStyles.body(context).copyWith(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiaryLight,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Extract Assets" button pinned above the safe area for blank projects
/// that already have story content.
class _ExtractAssetsButton extends StatelessWidget {
  const _ExtractAssetsButton({required this.onTap, required this.isDark});

  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(LucideIcons.sparkles, size: AppSizing.iconSm, color: primaryColor),
      label: Text(
        'Extract Assets',
        style: AppTextStyles.body(context).copyWith(color: primaryColor),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: primaryColor.withValues(alpha: 0.4)),
        backgroundColor: primaryColor.withValues(alpha: 0.12),
        minimumSize: const Size.fromHeight(AppSizing.buttonSm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        ),
      ),
    );
  }
}

class _SkeletonTree extends StatelessWidget {
  const _SkeletonTree();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;

    return Column(
      children: List.generate(7, (i) {
        final indent = i > 1 ? AppSpacing.s4 : 0.0;
        return Container(
          height: AppSizing.fileBrowserRow,
          margin: EdgeInsets.only(
            left: AppSpacing.s3 + indent,
            right: AppSpacing.s3,
            top: 2,
          ),
          decoration: BoxDecoration(
            color: base.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppSizing.radiusXs),
          ),
        );
      }),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

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
