import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/formatters.dart';

/// Project card displayed on the Home Screen.
///
/// Shows: display name, scene count, creation date, and a generation progress
/// bar. Long-press reveals "Rename" and "Delete" options.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    required this.onTap,
    required this.onDeleteConfirmed,
    required this.onRenameConfirmed,
    this.isDeleting = false,
  });

  final ProjectDocument project;
  final VoidCallback onTap;
  final VoidCallback onDeleteConfirmed;

  /// Called with the new display name after the user confirms a rename.
  final ValueChanged<String> onRenameConfirmed;

  /// True while the delete API call is in flight for this card.
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final textSecondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Card(
      child: InkWell(
        onTap: isDeleting ? null : onTap,
        onLongPress: isDeleting ? null : () => _showContextMenu(context),
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s4,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Project display name ───────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.displayName,
                      style: AppTextStyles.h2(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isDeleting)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: primaryColor,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              // ── Metadata row ──────────────────────────────────────────────
              Row(
                children: [
                  Text(
                    '${project.sceneCount} '
                    '${project.sceneCount == 1 ? "scene" : "scenes"}',
                    style: AppTextStyles.bodySmall(context)
                        .copyWith(color: textSecondary),
                  ),
                  _dot(context, textSecondary),
                  Text(
                    formatLastModified(project.createdAt),
                    style: AppTextStyles.bodySmall(context)
                        .copyWith(color: textSecondary),
                  ),
                ],
              ),
              // ── Progress bar ──────────────────────────────────────────────
              const SizedBox(height: AppSpacing.s3),
              if (project.sceneCount > 0)
                LinearProgressIndicator(
                  value: project.completionFraction,
                  minHeight: 3,
                  backgroundColor: isDark
                      ? AppColors.surfaceSunkenDark
                      : AppColors.surfaceSunkenLight,
                  valueColor: AlwaysStoppedAnimation(primaryColor),
                  borderRadius: BorderRadius.circular(AppSizing.radiusFull),
                ),
              if (project.sceneCount > 0)
                const SizedBox(height: 0)
              else
                const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(BuildContext context, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
        child: Text(
          '·',
          style: AppTextStyles.bodySmall(context).copyWith(color: color),
        ),
      );

  Future<void> _showContextMenu(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = await showMenu<String>(
      context: context,
      position: _menuPosition(context),
      items: [
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(
                LucideIcons.pencil,
                size: AppSizing.iconSm,
                color:
                    isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
              ),
              const SizedBox(width: AppSpacing.s3),
              const Text('Rename'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                LucideIcons.trash2,
                size: AppSizing.iconSm,
                color: isDark ? AppColors.errorDark : AppColors.errorLight,
              ),
              const SizedBox(width: AppSpacing.s3),
              const Text('Delete'),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted) return;
    if (result == 'rename') _showRenameDialog(context);
    if (result == 'delete') _confirmDelete(context);
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final controller = TextEditingController(text: project.displayName);
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Rename Project'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            decoration: InputDecoration(
              labelText: 'Project name',
              errorText: errorText,
            ),
            onSubmitted: (_) => _doRename(ctx, controller, setDialogState),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => _doRename(ctx, controller, setDialogState),
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
  }

  void _doRename(
    BuildContext ctx,
    TextEditingController controller,
    StateSetter setDialogState,
  ) {
    final newName = controller.text.trim();
    if (newName.isEmpty) {
      setDialogState(() {});
      return;
    }
    if (newName == project.displayName) {
      Navigator.pop(ctx);
      return;
    }
    Navigator.pop(ctx);
    onRenameConfirmed(newName);
  }

  RelativeRect _menuPosition(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return RelativeRect.fill;
    final offset = box.localToGlobal(Offset.zero);
    return RelativeRect.fromLTRB(
      offset.dx,
      offset.dy + box.size.height,
      offset.dx + box.size.width,
      0,
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${project.displayName}"?'),
        content: const Text(
          'All media — images, videos, and story — will be permanently '
          'removed from the cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor:
                  isDark ? AppColors.errorDark : AppColors.errorLight,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) onDeleteConfirmed();
  }
}
