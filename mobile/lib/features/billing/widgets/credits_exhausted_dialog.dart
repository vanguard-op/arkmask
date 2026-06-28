import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Shows a modal dialog when a generation request returns HTTP 402
/// (insufficient credits).
///
/// Presents the user's remaining balance (if known), explains what happened,
/// and offers two actions: upgrade or dismiss.
///
/// Usage:
/// ```dart
/// showCreditsExhaustedDialog(context, balance: 0);
/// ```
Future<void> showCreditsExhaustedDialog(
  BuildContext context, {
  int? balance,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => _CreditsExhaustedDialog(balance: balance),
  );
}

class _CreditsExhaustedDialog extends StatelessWidget {
  const _CreditsExhaustedDialog({this.balance});
  final int? balance;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final errorColor = isDark ? AppColors.errorDark : AppColors.errorLight;

    return AlertDialog(
      backgroundColor:
          isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSizing.radiusLg),
      ),
      title: Row(
        children: [
          Icon(Icons.bolt_outlined, color: errorColor, size: AppSizing.iconMd),
          const SizedBox(width: AppSpacing.s2),
          Text('Credits exhausted', style: AppTextStyles.h3(context)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            balance != null && balance! <= 0
                ? 'Your credit balance is 0. Generation is paused until your '
                    'credits reset at the start of next month, or you upgrade now.'
                : 'You don\'t have enough credits for this generation. '
                    'Upgrade to continue or wait for your monthly reset.',
            style: AppTextStyles.body(context),
          ),
          if (balance != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.surfaceOverlayDark
                    : AppColors.surfaceOverlayLight,
                borderRadius: BorderRadius.circular(AppSizing.radiusMd),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Current balance: ',
                    style: AppTextStyles.caption(context).copyWith(
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                  ),
                  Text(
                    '$balance cr',
                    style: AppTextStyles.caption(context).copyWith(
                      fontWeight: FontWeight.w700,
                      color: errorColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Dismiss',
            style: AppTextStyles.body(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
            ),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor:
                isDark ? AppColors.primaryOnDark : AppColors.primaryOnLight,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
          ),
          onPressed: () {
            Navigator.of(context).pop();
            // Navigate to upgrade screen, hinting the creator plan as default.
            context.push('${Routes.upgrade}?highlight=creator');
          },
          child: const Text('Upgrade'),
        ),
      ],
    );
  }
}
