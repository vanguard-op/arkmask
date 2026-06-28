import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Upgrade / Paywall Screen.
///
/// Shows a plan comparison table (Free / Creator / Studio) and lets the user
/// start a Stripe Checkout Session that opens in the system browser.
///
/// On iOS we use the reader-app exception — no native IAP, just a Safari
/// redirect to a Stripe-hosted page. On Android the same flow works via Chrome.
///
/// After the user pays, Stripe fires a webhook that updates their tier and
/// credit balance server-side. The app re-fetches credits on next load.
///
/// [highlightPlan] optionally pre-highlights a specific plan ('creator' or
/// 'studio') — useful when navigating from a credits-exhausted prompt.
class UpgradeScreen extends StatelessWidget {
  const UpgradeScreen({super.key, this.highlightPlan});

  final String? highlightPlan;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a Plan'),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      ),
      body: _UpgradeBody(highlightPlan: highlightPlan),
    );
  }
}

class _UpgradeBody extends StatefulWidget {
  const _UpgradeBody({this.highlightPlan});
  final String? highlightPlan;

  @override
  State<_UpgradeBody> createState() => _UpgradeBodyState();
}

class _UpgradeBodyState extends State<_UpgradeBody> {
  /// Whether the user has toggled to annual billing (default: monthly).
  bool _annual = false;

  /// Which plan is currently loading a checkout session.
  String? _loadingPlan;

  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Text(
            'Unlock more credits',
            style: AppTextStyles.h2(context),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'All plans include access to the full ArkMask pipeline. '
            'Credits reset every month.',
            style: AppTextStyles.body(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.s6),

          // ── Monthly / Annual toggle ──────────────────────────────────────
          _BillingToggle(
            annual: _annual,
            onToggle: (v) => setState(() => _annual = v),
          ),
          const SizedBox(height: AppSpacing.s6),

          // ── Error message ────────────────────────────────────────────────
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.errorSubtleDark
                    : AppColors.errorSubtleLight,
                borderRadius: BorderRadius.circular(AppSizing.radiusMd),
              ),
              child: Text(
                _errorMessage!,
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.errorDark : AppColors.errorLight,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
          ],

          // ── Plan cards ──────────────────────────────────────────────────
          _PlanCard(
            tier: 'free',
            name: 'Free',
            price: '\$0',
            billingNote: 'forever',
            credits: '200 credits / month',
            features: const [
              '1 active project',
              'Full pipeline access',
              'Both AI providers',
            ],
            limitations: const [
              'No usage dashboard',
              'No API key management',
            ],
            ctaLabel: 'Your current plan',
            ctaEnabled: false,
            highlighted: false,
            loading: false,
            onTap: null,
            isDark: isDark,
          ),
          const SizedBox(height: AppSpacing.s3),

          _PlanCard(
            tier: 'creator',
            name: 'Creator',
            price: _annual ? '\$79' : '\$9',
            billingNote: _annual ? '/ year  (save 27%)' : '/ month',
            credits: '3,000 credits / month',
            features: const [
              'Unlimited projects',
              'Full pipeline access',
              'Both AI providers',
              'Usage dashboard',
              'View & copy API key',
            ],
            limitations: const [],
            ctaLabel: 'Upgrade to Creator',
            ctaEnabled: _loadingPlan == null,
            highlighted: widget.highlightPlan == 'creator' || widget.highlightPlan == null,
            loading: _loadingPlan == 'creator',
            onTap: () => _startCheckout(context, 'creator'),
            isDark: isDark,
          ),
          const SizedBox(height: AppSpacing.s3),

          _PlanCard(
            tier: 'studio',
            name: 'Studio',
            price: _annual ? '\$249' : '\$29',
            billingNote: _annual ? '/ year  (save 28%)' : '/ month',
            credits: '10,000 credits / month',
            features: const [
              'Unlimited projects',
              'Full pipeline access',
              'Both AI providers',
              'Full usage dashboard + CSV export',
              'API key regeneration',
              'Priority support (24h)',
            ],
            limitations: const [],
            ctaLabel: 'Upgrade to Studio',
            ctaEnabled: _loadingPlan == null,
            highlighted: widget.highlightPlan == 'studio',
            loading: _loadingPlan == 'studio',
            onTap: () => _startCheckout(context, 'studio'),
            isDark: isDark,
          ),

          const SizedBox(height: AppSpacing.s8),
          Text(
            'Payments are processed by Stripe. '
            'Subscriptions can be cancelled at any time from the billing portal.',
            style: AppTextStyles.caption(context).copyWith(
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiaryLight,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
      ),
    );
  }

  /// Resolve the Stripe price ID for [tier] and the current billing period,
  /// then open a Stripe Checkout Session in the system browser.
  Future<void> _startCheckout(BuildContext context, String tier) async {
    setState(() {
      _loadingPlan = tier;
      _errorMessage = null;
    });

    try {
      final priceId = _priceId(tier);

      // Guard: price IDs are injected at build time via --dart-define-from-file.
      // If the app was run without that flag the constants will be empty strings.
      if (priceId.isEmpty) {
        setState(() {
          _errorMessage =
              'Billing is not configured in this build. '
              'Run with --dart-define-from-file=.env.json.';
        });
        return;
      }

      final apiClient = ArkMaskServices.of(context).apiClient;
      final url = await apiClient.createCheckoutSession(priceId: priceId);

      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not open billing page.');
      }
    } catch (e) {
      if (mounted) {
        // Surface the actual error detail if the API returned one.
        final detail = e.toString().contains('price_id')
            ? 'Invalid price configuration. Check your .env.json.'
            : 'Could not start checkout. Please try again.';
        setState(() => _errorMessage = detail);
      }
    } finally {
      if (mounted) setState(() => _loadingPlan = null);
    }
  }

  /// Map tier + billing period to the correct Stripe Price ID.
  ///
  /// Price IDs are baked into the app at build time as dart-define constants
  /// so they can differ between test and production builds without a code change.
  String _priceId(String tier) {
    // These const values are injected via --dart-define-from-file=.env.json.
    const creatorMonthly = String.fromEnvironment(
      'STRIPE_PRICE_CREATOR_MONTHLY',
      defaultValue: '',
    );
    const creatorAnnual = String.fromEnvironment(
      'STRIPE_PRICE_CREATOR_ANNUAL',
      defaultValue: '',
    );
    const studioMonthly = String.fromEnvironment(
      'STRIPE_PRICE_STUDIO_MONTHLY',
      defaultValue: '',
    );
    const studioAnnual = String.fromEnvironment(
      'STRIPE_PRICE_STUDIO_ANNUAL',
      defaultValue: '',
    );

    // Debug-only: log all resolved price IDs so you can confirm .env.json
    // was picked up. Stripped from release builds automatically (kDebugMode).
    if (kDebugMode) {
      dev.log(
        '[Billing] Resolved price IDs from dart-define:\n'
        '  CREATOR_MONTHLY : ${creatorMonthly.isEmpty ? "(empty — .env.json not loaded?)" : creatorMonthly}\n'
        '  CREATOR_ANNUAL  : ${creatorAnnual.isEmpty  ? "(empty — .env.json not loaded?)" : creatorAnnual}\n'
        '  STUDIO_MONTHLY  : ${studioMonthly.isEmpty  ? "(empty — .env.json not loaded?)" : studioMonthly}\n'
        '  STUDIO_ANNUAL   : ${studioAnnual.isEmpty   ? "(empty — .env.json not loaded?)" : studioAnnual}\n'
        '  API_BASE_URL    : ${const String.fromEnvironment("API_BASE_URL", defaultValue: "(empty)")}',
        name: 'ArkMask.Billing',
      );
    }

    return switch ((tier, _annual)) {
      ('creator', false) => creatorMonthly,
      ('creator', true) => creatorAnnual,
      ('studio', false) => studioMonthly,
      ('studio', true) => studioAnnual,
      _ => throw ArgumentError('Unknown tier: $tier'),
    };
  }
}

// ── Billing toggle (monthly / annual) ─────────────────────────────────────────

class _BillingToggle extends StatelessWidget {
  const _BillingToggle({required this.annual, required this.onToggle});
  final bool annual;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final subtleColor =
        isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight;
    final borderColor =
        isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ToggleChip(
          label: 'Monthly',
          selected: !annual,
          primaryColor: primaryColor,
          subtleColor: subtleColor,
          borderColor: borderColor,
          onTap: () => onToggle(false),
          isDark: isDark,
        ),
        const SizedBox(width: AppSpacing.s2),
        _ToggleChip(
          label: 'Annual  (save ~28%)',
          selected: annual,
          primaryColor: primaryColor,
          subtleColor: subtleColor,
          borderColor: borderColor,
          onTap: () => onToggle(true),
          isDark: isDark,
        ),
      ],
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.selected,
    required this.primaryColor,
    required this.subtleColor,
    required this.borderColor,
    required this.onTap,
    required this.isDark,
  });

  final String label;
  final bool selected;
  final Color primaryColor;
  final Color subtleColor;
  final Color borderColor;
  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4, vertical: AppSpacing.s2),
        decoration: BoxDecoration(
          color: selected ? subtleColor : Colors.transparent,
          border: Border.all(
              color: selected ? primaryColor : borderColor, width: 1),
          borderRadius: BorderRadius.circular(AppSizing.radiusFull),
        ),
        child: Text(
          label,
          style: AppTextStyles.caption(context).copyWith(
            color: selected
                ? primaryColor
                : (isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Plan card ─────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.tier,
    required this.name,
    required this.price,
    required this.billingNote,
    required this.credits,
    required this.features,
    required this.limitations,
    required this.ctaLabel,
    required this.ctaEnabled,
    required this.highlighted,
    required this.loading,
    required this.onTap,
    required this.isDark,
  });

  final String tier;
  final String name;
  final String price;
  final String billingNote;
  final String credits;
  final List<String> features;
  final List<String> limitations;
  final String ctaLabel;
  final bool ctaEnabled;
  final bool highlighted;
  final bool loading;
  final VoidCallback? onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final subtleColor =
        isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight;
    final borderColor = highlighted
        ? primaryColor
        : (isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight);
    final surfaceColor =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    final textSecondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final textTertiary =
        isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    return Container(
      decoration: BoxDecoration(
        color: highlighted ? subtleColor : surfaceColor,
        border: Border.all(color: borderColor, width: highlighted ? 1.5 : 1),
        borderRadius: BorderRadius.circular(AppSizing.radiusLg),
      ),
      padding: const EdgeInsets.all(AppSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Plan name + price
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(name, style: AppTextStyles.h3(context)),
              const Spacer(),
              Text(
                price,
                style: AppTextStyles.h2(context).copyWith(
                  color: highlighted ? primaryColor : null,
                ),
              ),
              const SizedBox(width: AppSpacing.s1),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  billingNote,
                  style: AppTextStyles.caption(context)
                      .copyWith(color: textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),

          // Credits badge
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3, vertical: AppSpacing.s1),
            decoration: BoxDecoration(
              color: highlighted
                  ? (isDark ? AppColors.primaryDark : AppColors.primaryLight)
                      .withValues(alpha: 0.15)
                  : (isDark
                      ? AppColors.surfaceOverlayDark
                      : AppColors.surfaceOverlayLight),
              borderRadius: BorderRadius.circular(AppSizing.radiusFull),
            ),
            child: Text(
              credits,
              style: AppTextStyles.caption(context).copyWith(
                color: highlighted ? primaryColor : textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),

          // Feature list
          ...features.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(LucideIcons.check,
                      size: 14,
                      color: isDark
                          ? AppColors.successDark
                          : AppColors.successLight),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(f,
                        style: AppTextStyles.body(context)
                            .copyWith(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
          // Limitation list (shown greyed-out with × icon)
          ...limitations.map(
            (l) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(LucideIcons.x, size: 14, color: textTertiary),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(l,
                        style: AppTextStyles.body(context)
                            .copyWith(fontSize: 13, color: textTertiary)),
                  ),
                ],
              ),
            ),
          ),

          if (onTap != null) ...[
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      highlighted ? primaryColor : Colors.transparent,
                  foregroundColor: highlighted
                      ? (isDark
                          ? AppColors.primaryOnDark
                          : AppColors.primaryOnLight)
                      : primaryColor,
                  side: highlighted
                      ? null
                      : BorderSide(color: primaryColor),
                  padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.s3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppSizing.radiusMd),
                  ),
                ),
                onPressed: ctaEnabled ? onTap : null,
                child: loading
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            highlighted
                                ? (isDark
                                    ? AppColors.primaryOnDark
                                    : AppColors.primaryOnLight)
                                : primaryColor,
                          ),
                        ),
                      )
                    : Text(ctaLabel),
              ),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: borderColor),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppSizing.radiusMd),
                  ),
                ),
                onPressed: null,
                child: Text(ctaLabel,
                    style: AppTextStyles.body(context)
                        .copyWith(color: textSecondary)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
