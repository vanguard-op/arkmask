import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import 'generation_step_dots.dart';

/// A single row in the Project File Browser tree (FEAT-005).
///
/// Handles folder expand/collapse with a chevron animation, icon per node
/// type, selected state, and an optional [GenerationStepDots] widget on the
/// right for asset and scene folders.
class FileBrowserRow extends StatelessWidget {
  const FileBrowserRow({
    super.key,
    required this.label,
    required this.icon,
    required this.depth,
    this.isFolder = false,
    this.isExpanded = false,
    this.isSelected = false,
    this.steps,
    this.badge,
    this.onTap,
    this.onToggleExpand,
  });

  /// Display label for this node.
  final String label;

  /// Leading icon for this node type.
  final IconData icon;

  /// Tree depth level — 16px indent per level.
  final int depth;

  final bool isFolder;
  final bool isExpanded;
  final bool isSelected;

  /// Optional step dots for asset and scene nodes.
  final List<GenerationStepState>? steps;

  /// Optional badge widget (e.g., "Global" / "Variant" pill for scene assets).
  final Widget? badge;

  final VoidCallback? onTap;
  final VoidCallback? onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final textPrimary = isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final textTertiary = isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    final iconColor = isSelected ? primaryColor : textTertiary;
    final labelColor = isSelected ? primaryColor : textPrimary;
    final bgColor = isSelected
        ? (isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight)
        : Colors.transparent;

    return SizedBox(
      height: AppSizing.fileBrowserRow,
      child: Material(
        color: bgColor,
        child: InkWell(
          onTap: onTap,
          splashColor: (isDark ? AppColors.surfaceHoverDark : AppColors.surfaceHoverLight),
          child: Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.s3 + depth * AppSpacing.s4,
              right: AppSpacing.s3,
            ),
            child: Row(
              children: [
                // ── Expand/collapse chevron (folders only) ──────────────────
                SizedBox(
                  width: AppSizing.iconMd,
                  child: isFolder
                      ? GestureDetector(
                          onTap: onToggleExpand,
                          child: AnimatedRotation(
                            turns: isExpanded ? 0.25 : 0,
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOut,
                            child: Icon(
                              LucideIcons.chevronRight,
                              size: AppSizing.iconSm,
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: AppSpacing.s2),
                // ── Node icon ──────────────────────────────────────────────
                Icon(icon, size: AppSizing.iconSm, color: iconColor),
                const SizedBox(width: AppSpacing.s2),
                // ── Label ──────────────────────────────────────────────────
                Expanded(
                  child: Text(
                    label,
                    style: AppTextStyles.body(context).copyWith(color: labelColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // ── Optional badge ─────────────────────────────────────────
                if (badge != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  badge!,
                ],
                // ── Generation step dots ───────────────────────────────────
                if (steps != null) ...[
                  const SizedBox(width: AppSpacing.s3),
                  GenerationStepDots(steps: steps!),
                ],
                const SizedBox(width: AppSpacing.s2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small pill badge for scene-local asset reference mode.
class AssetReferenceBadge extends StatelessWidget {
  const AssetReferenceBadge({super.key, required this.isPassThrough});

  /// True = "Global" (using global image), false = "Variant" (own image).
  final bool isPassThrough;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: isPassThrough
            ? (isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight)
            : (isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight),
        borderRadius: BorderRadius.circular(AppSizing.radiusXs),
      ),
      child: Text(
        isPassThrough ? 'Global' : 'Variant',
        style: AppTextStyles.caption(context).copyWith(
          color: isPassThrough
              ? primaryColor
              : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
          fontSize: 10,
        ),
      ),
    );
  }
}
