import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/formatters.dart';
import '../cubit/usage_cubit.dart';
import '../cubit/usage_state.dart';

/// Usage Dashboard Screen (FEAT-024).
///
/// Shows the user's generation event history: type, AI provider, timestamp,
/// and credit cost. Supports per-type filtering and shows a total cost summary
/// for the currently visible period.
class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => UsageCubit(apiClient: services.apiClient)..load(),
      child: const _UsageView(),
    );
  }
}

class _UsageView extends StatelessWidget {
  const _UsageView();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UsageCubit, UsageState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Generation History'),
            leading: IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              onPressed: () => context.pop(),
            ),
          ),
          body: switch (state) {
            UsageLoading() =>
              const Center(child: CircularProgressIndicator()),
            UsageError(:final message) =>
              _ErrorView(message: message),
            UsageLoaded() => _LoadedBody(state: state),
          },
        );
      },
    );
  }
}

// ── Loaded body ───────────────────────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({required this.state});
  final UsageLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final events = state.filteredEvents;

    return Column(
      children: [
        // ── Filter chip bar ────────────────────────────────────────────────
        _FilterBar(currentFilter: state.filterType),
        // ── Total cost summary ─────────────────────────────────────────────
        _TotalCostBanner(totalCredits: state.totalCostCredits, isDark: isDark),
        // ── Event list ─────────────────────────────────────────────────────
        Expanded(
          child: events.isEmpty
              ? _EmptyState(hasFilter: state.filterType != null)
              : ListView.separated(
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _EventRow(event: events[index], isDark: isDark),
                ),
        ),
      ],
    );
  }
}

// ── Filter bar ────────────────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.currentFilter});
  final String? currentFilter;

  // Keys match the raw `endpoint` values written by _deduct_credits in
  // backend/app/routers/generation.py (leading slash included) — these are
  // what UsageEvent.type now holds directly from the API response.
  static const _labels = <String?, String>{
    null: 'All',
    '/image-prompt': 'Image Prompt',
    '/image': 'Image',
    '/video-prompt': 'Storyboard',
    '/video': 'Video',
    '/refine-story': 'Refine',
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final subtleColor =
        isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight;
    final borderColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      child: Row(
        children: _labels.entries.map((entry) {
          final isSelected = currentFilter == entry.key;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s2),
            child: ChoiceChip(
              label: Text(entry.value),
              selected: isSelected,
              selectedColor: subtleColor,
              backgroundColor:
                  isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
              side: BorderSide(
                  color: isSelected ? primaryColor : borderColor),
              labelStyle: AppTextStyles.caption(context).copyWith(
                color: isSelected ? primaryColor : null,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
              onSelected: (_) => context
                  .read<UsageCubit>()
                  .setTypeFilter(entry.key),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Total cost banner ─────────────────────────────────────────────────────────

class _TotalCostBanner extends StatelessWidget {
  const _TotalCostBanner({required this.totalCredits, required this.isDark});
  final int totalCredits;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: borderColor),
          top: BorderSide(color: borderColor),
        ),
        color: isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
      ),
      child: Row(
        children: [
          Text(
            'Total',
            style: AppTextStyles.body(context).copyWith(
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
            ),
          ),
          const Spacer(),
          Text(
            formatCredits(totalCredits),
            style: AppTextStyles.body(context).copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Event row ─────────────────────────────────────────────────────────────────

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.isDark});
  final UsageEvent event;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textSecondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final textTertiary =
        isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Type icon
          Padding(
            padding: const EdgeInsets.only(top: 2, right: AppSpacing.s3),
            child: Icon(
              _iconFor(event.type),
              size: AppSizing.iconSm,
              color: textSecondary,
            ),
          ),
          // Event details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.typeLabel,
                  style: AppTextStyles.body(context),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatProvider(event.provider)} · ${_formatTimestamp(event.timestamp)}',
                  style: AppTextStyles.caption(context).copyWith(
                    color: textTertiary,
                  ),
                ),
              ],
            ),
          ),
          // Credit cost
          Text(
            '${event.costCredits} cr',
            style: AppTextStyles.body(context).copyWith(
              color: textSecondary,
              fontVariations: const [FontVariation('wght', 500)],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String type) => switch (type) {
        '/image-prompt' => LucideIcons.pencil,
        '/image' => LucideIcons.image,
        '/video-prompt' => LucideIcons.fileText,
        '/video' => LucideIcons.film,
        '/assets' => LucideIcons.plus,
        '/refine-story' => LucideIcons.fileText,
        '/merge' => LucideIcons.film,
        '/image-describe' => LucideIcons.image,
        _ => LucideIcons.zap,
      };

  String _formatProvider(String provider) => switch (provider.toLowerCase()) {
        'gemini' => 'Gemini',
        'bytedance' || 'byteplus' => 'BytePlus Ark',
        _ => provider,
      };

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasFilter});
  final bool hasFilter;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.barChart2,
              size: AppSizing.iconLg,
              color: (isDark ? AppColors.primaryDark : AppColors.primaryLight)
                  .withValues(alpha: 0.3),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              hasFilter ? 'No events for this filter' : 'No events yet',
              style: AppTextStyles.h3(context),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              hasFilter
                  ? 'Try selecting a different event type.'
                  : 'Generation events will appear here after your first run.',
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

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: AppTextStyles.body(context)),
            const SizedBox(height: AppSpacing.s4),
            ElevatedButton(
              onPressed: () => context.read<UsageCubit>().load(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
