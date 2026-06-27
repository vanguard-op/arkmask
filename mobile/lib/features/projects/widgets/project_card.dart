import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/formatters.dart';

/// Project card displayed on the Home Screen.
///
/// Shows: project name, scene count, last modified date, and a thin
/// generation progress bar at the bottom edge.
/// Long-press reveals a "Delete" option.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    required this.onTap,
    required this.onDeleteConfirmed,
    this.isDeleting = false,
  });

  final ProjectMeta project;
  final VoidCallback onTap;
  final VoidCallback onDeleteConfirmed;

  /// True while the delete operation is in progress for this card.
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final textSecondary = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

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
              // ── Project name ──────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.name,
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
                    '${project.sceneCount} ${project.sceneCount == 1 ? "scene" : "scenes"}',
                    style: AppTextStyles.bodySmall(context).copyWith(color: textSecondary),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
                    child: Text(
                      '·',
                      style: AppTextStyles.bodySmall(context).copyWith(color: textSecondary),
                    ),
                  ),
                  Text(
                    formatLastModified(project.lastModified),
                    style: AppTextStyles.bodySmall(context).copyWith(color: textSecondary),
                  ),
                ],
              ),
              // ── Progress bar ──────────────────────────────────────────────
              const SizedBox(height: AppSpacing.s3),
              if (project.sceneCount > 0)
                LinearProgressIndicator(
                  value: project.completionFraction,
                  minHeight: 3,
                  backgroundColor: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
                  valueColor: AlwaysStoppedAnimation(primaryColor),
                  borderRadius: BorderRadius.circular(AppSizing.radiusFull),
                ),
              if (project.sceneCount > 0) const SizedBox(height: 0)
              else const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context) async {
    final result = await showMenu<String>(
      context: context,
      position: _menuPosition(context),
      items: [
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                LucideIcons.trash2,
                size: AppSizing.iconSm,
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.errorDark
                    : AppColors.errorLight,
              ),
              const SizedBox(width: AppSpacing.s3),
              const Text('Delete'),
            ],
          ),
        ),
      ],
    );

    if (result == 'delete' && context.mounted) {
      _confirmDelete(context);
    }
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
        title: Text('Delete "${project.name}"?'),
        content: const Text(
          'All files — images, videos, and story — will be permanently '
          'removed from your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: isDark ? AppColors.errorDark : AppColors.errorLight,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) onDeleteConfirmed();
  }
}
