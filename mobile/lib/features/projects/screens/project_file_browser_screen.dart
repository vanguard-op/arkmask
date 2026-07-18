import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/models/models.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/formatters.dart' show formatBytes;
import '../../../core/utils/video_download.dart';
import '../../../core/utils/video_player_nav.dart';
import '../../assets/widgets/add_asset_sheet.dart';
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
class ProjectFileBrowserScreen extends StatefulWidget {
  const ProjectFileBrowserScreen({super.key, required this.projectSlug});

  /// Immutable project slug (URL-decoded Firestore document ID).
  final String projectSlug;

  @override
  State<ProjectFileBrowserScreen> createState() =>
      _ProjectFileBrowserScreenState();
}

class _ProjectFileBrowserScreenState extends State<ProjectFileBrowserScreen> {
  /// Last successfully resolved storage summary (FEAT-027), or null before the
  /// first fetch has ever completed. Kept across refreshes so the banner shows
  /// the previous value in place while a new fetch is in flight, instead of
  /// hiding and re-appearing — avoids a jarring UI "jump" every time the user
  /// returns from a child screen.
  ProjectStorageSummary? _lastSummary;

  @override
  void initState() {
    super.initState();
    // Defer until context is fully available (ArkMaskServices.of requires it).
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSummary());
  }

  /// Re-fetches the storage summary (byte usage may have changed after
  /// generating a new image/video). This is a one-shot API call, not a
  /// Firestore listener, so it needs an explicit trigger.
  ///
  /// Called once on entry and again whenever the user returns from a child
  /// screen (asset editor, scene detail, story editor). The rest of the tree
  /// — [FileBrowserCubit]'s Firestore + [JobsCubit] listeners — is already
  /// live and does NOT need re-fetching on return; a full `load()` used to
  /// be called here too, which reset scroll/expand state on every back
  /// navigation for no benefit (see FileBrowserCubit doc comments).
  ///
  /// Deliberately does NOT clear [_lastSummary] before the fetch — the banner
  /// keeps rendering the old numbers until the new summary arrives, then
  /// updates directly via [setState]. On failure the previous value is left
  /// untouched (fails silently, non-blocking).
  Future<void> _refreshSummary() async {
    if (!mounted) return;
    final apiClient = ArkMaskServices.of(context).apiClient;
    try {
      final data = await apiClient.getProjectStorageSummary(widget.projectSlug);
      if (!mounted) return;
      setState(() {
        _lastSummary = ProjectStorageSummary.fromJson(widget.projectSlug, data);
      });
    } catch (_) {
      // Non-critical — keep showing the last known summary, if any.
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => FileBrowserCubit(
        jobsCubit: ArkMaskServices.of(context).jobsCubit,
      )..load(widget.projectSlug),
      child: _FileBrowserView(
        projectSlug: widget.projectSlug,
        storageSummary: _lastSummary,
        onReturnFromChild: _refreshSummary,
      ),
    );
  }
}

class _FileBrowserView extends StatelessWidget {
  const _FileBrowserView({
    required this.projectSlug,
    required this.storageSummary,
    required this.onReturnFromChild,
  });

  final String projectSlug;

  /// Last resolved storage summary, or null before the first fetch completes.
  final ProjectStorageSummary? storageSummary;

  /// Called when the user pops back from a pushed child screen. Only
  /// refreshes the storage summary (FEAT-027) — the tree itself stays live
  /// via [FileBrowserCubit]'s own Firestore/JobsCubit subscriptions and does
  /// not need to be reloaded.
  final VoidCallback onReturnFromChild;

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
            FileBrowserLoaded() => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StorageBanner(summary: storageSummary),
                  Expanded(
                    child: _TreeView(
                      state: state,
                      projectSlug: projectSlug,
                      isDark: isDark,
                      onReturnFromChild: onReturnFromChild,
                    ),
                  ),
                ],
              ),
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
    required this.onReturnFromChild,
  });

  final FileBrowserLoaded state;
  final String projectSlug;
  final bool isDark;
  final VoidCallback onReturnFromChild;

  // ── Route helpers ─────────────────────────────────────────────────────────
  //
  // The :assetPath param carries a qualified Firestore path segment so the
  // AssetEditorCubit can construct the full document path without extra state:
  //   Global asset     → "assets/{assetId}"
  //   Scene-local      → "scenes/{sceneFirestoreId}/assets/{assetId}"
  //
  // AssetEditorCubit prepends "users/{uid}/projects/{slug}/" to obtain the
  // complete Firestore path.

  /// Route to a global asset editor (asset in the top-level `assets/` subcollection).
  String _globalAssetEditorPath(String assetId) => Routes.assetEditor
      .replaceFirst(':projectName', Uri.encodeComponent(projectSlug))
      .replaceFirst(':assetPath', Uri.encodeComponent('assets/$assetId'));

  /// Route to a scene-local asset editor.
  ///
  /// [sceneFirestoreId] is the Firestore doc ID of the parent scene (not the
  /// scene number) so the cubit can resolve the exact subcollection path.
  String _sceneAssetEditorPath(String sceneFirestoreId, String assetId) =>
      Routes.assetEditor
          .replaceFirst(':projectName', Uri.encodeComponent(projectSlug))
          .replaceFirst(
            ':assetPath',
            Uri.encodeComponent('scenes/$sceneFirestoreId/assets/$assetId'),
          );

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
          onReturnFromChild();
        }
      },
    ));

    // ── final.mp4 (shown once merge worker writes gcs_final_path) ─────────
    if (tree.gcsFinalPath != null) {
      rows.add(FileBrowserRow(
        label: 'final.mp4',
        icon: LucideIcons.fileVideo,
        depth: 0,
        onTap: () => openVideoPlayer(
          context,
          gcsPath: tree.gcsFinalPath!,
          title: 'final.mp4',
        ),
        onLongPress: () => showDownloadToGallerySheet(
          context,
          gcsPath: tree.gcsFinalPath!,
          fileNameHint: '${projectSlug}_final.mp4',
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
      // FEAT-033 — long-press opens the Add Asset Sheet scoped globally.
      // Deliberately does not conflict with the section header's own
      // expand/collapse tap gesture (long-press vs. tap are distinct
      // GestureDetector recognizers).
      onLongPress: () =>
          showAddAssetSheet(context, projectSlug: projectSlug),
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
            badge: SourceBadge(source: asset.source),
            steps: [
              asset.isGeneratingPrompt
                  ? GenerationStepState.running
                  : (asset.hasPromptBody
                      ? GenerationStepState.done
                      : GenerationStepState.pending),
              asset.isGeneratingImage
                  ? GenerationStepState.running
                  : (asset.hasImage
                      ? GenerationStepState.done
                      : GenerationStepState.pending),
            ],
            onTap: () async {
              context.read<FileBrowserCubit>().select(asset.id);
              await context.push(_globalAssetEditorPath(asset.id));
              if (context.mounted) {
                onReturnFromChild();
              }
            },
            // FEAT-037 — long-press reveals a delete option.
            onLongPress: () => confirmAndDeleteAssetRow(
              context,
              projectSlug: projectSlug,
              assetFirestorePath: 'assets/${asset.id}',
              assetName: asset.name,
            ),
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
              scene.isGeneratingStoryboard
                  ? GenerationStepState.running
                  : (scene.hasStoryboard
                      ? GenerationStepState.done
                      : GenerationStepState.pending),
              scene.isGeneratingVideo
                  ? GenerationStepState.running
                  : (scene.hasVideo
                      ? GenerationStepState.done
                      : GenerationStepState.pending),
            ],
            onTap: () async {
              context.read<FileBrowserCubit>().toggleExpand(scene.id);
              await context.push(_sceneDetailPath(scene.sceneNumber));
              if (context.mounted) {
                onReturnFromChild();
              }
            },
            onToggleExpand: () =>
                context.read<FileBrowserCubit>().toggleExpand(scene.id),
            // FEAT-033 — long-press opens the Add Asset Sheet scoped to
            // this scene (all three tabs, including Reference).
            onLongPress: () => showAddAssetSheet(
              context,
              projectSlug: projectSlug,
              scope: scene.sceneNumber,
            ),
          ));

          if (expanded.contains(scene.id)) {
            // Scene-local assets.
            for (final asset in scene.assets) {
              rows.add(FileBrowserRow(
                label: asset.name,
                icon: LucideIcons.image,
                depth: 2,
                isSelected: state.selectedId == asset.id,
                badge: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SourceBadge(source: asset.source),
                    if (asset.source != 'extracted') const SizedBox(width: AppSpacing.s1),
                    AssetReferenceBadge(
                      assetName: asset.name,
                      description: asset.description,
                    ),
                  ],
                ),
                steps: asset.isPassThrough
                    ? null
                    : [
                        asset.isGeneratingPrompt
                            ? GenerationStepState.running
                            : (asset.hasPromptBody
                                ? GenerationStepState.done
                                : GenerationStepState.pending),
                        asset.isGeneratingImage
                            ? GenerationStepState.running
                            : (asset.hasImage
                                ? GenerationStepState.done
                                : GenerationStepState.pending),
                      ],
                onTap: () async {
                  context.read<FileBrowserCubit>().select(asset.id);
                  await context.push(
                    _sceneAssetEditorPath(scene.id, asset.id),
                  );
                  if (context.mounted) {
                    onReturnFromChild();
                  }
                },
                // FEAT-037 — long-press reveals a delete option.
                onLongPress: () => confirmAndDeleteAssetRow(
                  context,
                  projectSlug: projectSlug,
                  assetFirestorePath: 'scenes/${scene.id}/assets/${asset.id}',
                  assetName: asset.name,
                ),
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
                  onReturnFromChild();
                }
              },
            ));

            // video.mp4 (only shown once gcs_video_path is set by the worker).
            if (scene.hasVideo && scene.gcsVideoPath != null) {
              rows.add(FileBrowserRow(
                label: 'video.mp4',
                icon: LucideIcons.video,
                depth: 2,
                onTap: () => openVideoPlayer(
                  context,
                  gcsPath: scene.gcsVideoPath!,
                  title: 'Scene ${scene.sceneNumber}',
                ),
                onLongPress: () => showDownloadToGallerySheet(
                  context,
                  gcsPath: scene.gcsVideoPath!,
                  fileNameHint: '${projectSlug}_scene_${scene.sceneNumber}.mp4',
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
                  onReturnFromChild();
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

// ── Storage banner (FEAT-027) ─────────────────────────────────────────────────

/// Compact per-category storage breakdown shown below the AppBar in the project
/// file browser. Hidden only when no summary has ever resolved successfully
/// (first launch, before the initial fetch completes) or all categories are 0.
///
/// Renders directly off [summary] — no [FutureBuilder] here. The parent
/// ([_ProjectFileBrowserScreenState]) holds the last successfully resolved
/// summary in state and keeps rendering it while a background refresh is in
/// flight, only swapping to the new value once it lands. This avoids the
/// banner disappearing and reappearing (a jarring "jump") every time the user
/// returns from a child screen and a refresh is triggered.
class _StorageBanner extends StatelessWidget {
  const _StorageBanner({required this.summary});

  final ProjectStorageSummary? summary;

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    if (summary == null || summary.totalBytes == 0) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipBg =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    final textColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      child: Row(
        children: [
          _StorageChip(
            label: 'Images',
            bytes: summary.imagesBytes,
            chipBg: chipBg,
            textColor: textColor,
            context: context,
          ),
          const SizedBox(width: AppSpacing.s2),
          _StorageChip(
            label: 'Videos',
            bytes: summary.videosBytes,
            chipBg: chipBg,
            textColor: textColor,
            context: context,
          ),
          const SizedBox(width: AppSpacing.s2),
          _StorageChip(
            label: 'Export',
            bytes: summary.exportBytes,
            chipBg: chipBg,
            textColor: textColor,
            context: context,
          ),
        ],
      ),
    );
  }
}

class _StorageChip extends StatelessWidget {
  const _StorageChip({
    required this.label,
    required this.bytes,
    required this.chipBg,
    required this.textColor,
    required this.context,
  });

  final String label;
  final int bytes;
  final Color chipBg;
  final Color textColor;
  // ignore: avoid_field_initializers_in_const_classes
  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: AppSpacing.s1,
      ),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(AppSizing.radiusSm),
      ),
      child: Text(
        '$label · ${formatBytes(bytes)}',
        style: AppTextStyles.caption(context).copyWith(color: textColor),
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

/// Long-press delete action for an asset row in the file browser (FEAT-037).
///
/// Shows the standard "Delete [name]? This cannot be undone." confirmation,
/// calls `DELETE /assets`, and on a 409 (dependents found) offers a
/// force-delete retry listing the dependent asset names. Uses the API client
/// directly rather than a Cubit — this action lives in the tree, not inside
/// an already-open Asset Editor screen.
Future<void> confirmAndDeleteAssetRow(
  BuildContext context, {
  required String projectSlug,
  required String assetFirestorePath,
  required String assetName,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Delete asset?'),
      content: Text('Delete $assetName? This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final apiClient = ArkMaskServices.of(context).apiClient;
  await _deleteAssetRow(context, apiClient, projectSlug, assetFirestorePath, force: false);
}

Future<void> _deleteAssetRow(
  BuildContext context,
  ArkMaskApiClient apiClient,
  String projectSlug,
  String assetFirestorePath, {
  required bool force,
}) async {
  try {
    await apiClient.deleteAsset(
      projectSlug: projectSlug,
      assetFirestorePath: assetFirestorePath,
      force: force,
    );
    // Firestore listener removes the row from the tree automatically.
  } on AssetDeleteBlockedException catch (e) {
    if (!context.mounted) return;
    final names = e.dependents.map((d) => d.name).join(', ');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Asset is referenced elsewhere'),
        content: Text(
          'This asset is referenced by: $names.\n\n'
          'Delete or repoint those references first, or force-delete anyway '
          '(referencing assets will point at a missing asset).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _deleteAssetRow(context, apiClient, projectSlug, assetFirestorePath, force: true);
            },
            child: const Text('Force Delete'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to delete asset: $e')),
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
