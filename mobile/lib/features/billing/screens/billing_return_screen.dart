import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Billing Return Screen — the in-app landing point for
/// `arkmask://billing-return?status=success|cancel|portal`.
///
/// Stripe Checkout and the Customer Portal are opened in the system browser
/// (`LaunchMode.externalApplication` — see `upgrade_screen.dart`), which
/// means Stripe's `success_url` / `cancel_url` / Portal `return_url` (see
/// `backend/app/config.py`) can't be a plain in-app route — they have to be
/// a URL the OS can hand back to this app. `arkmask://billing-return` is
/// that URL; this screen is what the user actually sees when it resolves.
///
/// No manual credit/tier refetch is needed here: [ProjectsCubit] listens to
/// the user's Firestore profile document in real time, so by the time the
/// user lands back on Home, an already-processed Stripe webhook's tier/
/// credit update is reflected automatically. If the webhook hasn't finished
/// processing yet (a race with the redirect), it will apply moments later
/// with no further action from the user — see ProjectsCubit._profileSub.
class BillingReturnScreen extends StatelessWidget {
  const BillingReturnScreen({super.key, required this.status});

  /// `'success'`, `'cancel'`, or `'portal'` — from the `status` query param.
  /// Falls back to a neutral "you're all set" message for any other value.
  final String status;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (icon, iconColor, title, message) = switch (status) {
      'success' => (
          LucideIcons.checkCircle2,
          isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight,
          'Payment successful',
          'Your plan is being upgraded. Your new credit balance and tier '
              'will appear on the Home screen within a few seconds.',
        ),
      'cancel' => (
          LucideIcons.xCircle,
          isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
          'Checkout cancelled',
          'No changes were made to your plan. You can try again anytime '
              'from the Upgrade screen.',
        ),
      _ => (
          LucideIcons.checkCircle2,
          isDark ? AppColors.stateDoneDark : AppColors.stateDoneLight,
          "You're all set",
          'Any subscription changes will appear on the Home screen shortly.',
        ),
    };

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 64, color: iconColor),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  title,
                  style: AppTextStyles.h1(context),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  message,
                  style: AppTextStyles.body(context).copyWith(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondaryLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s6),
                ElevatedButton(
                  onPressed: () => context.go(Routes.home),
                  child: const Text('Back to Home'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
