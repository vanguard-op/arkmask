import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/formatters.dart';
import '../cubit/settings_cubit.dart';
import '../cubit/settings_state.dart';

/// Settings Screen — AI provider config, platform key display, credits,
/// and sign-out (FEAT-022, FEAT-023).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => SettingsCubit(
        storage: services.storage,
        authService: services.authService,
        apiClient: services.apiClient,
      )..load(),
      child: const _SettingsView(),
    );
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BlocConsumer<SettingsCubit, SettingsState>(
      listener: (context, state) {
        if (state is SettingsSignedOut) {
          context.go(Routes.splash);
        }
      },
      listenWhen: (prev, curr) {
        // Show success snackbar when key regeneration completes
        // (isRegeneratingKey transitions from true → false with no error).
        if (prev is SettingsLoaded &&
            curr is SettingsLoaded &&
            prev.isRegeneratingKey &&
            !curr.isRegeneratingKey) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Platform key regenerated successfully.'),
                ),
              );
            }
          });
        }
        return true;
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            leading: IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: 'Back',
              onPressed: () => context.pop(),
            ),
          ),
          body: switch (state) {
            SettingsLoading() => const Center(child: CircularProgressIndicator()),
            SettingsError(:final message) => Center(
                child: Text(message, style: AppTextStyles.body(context)),
              ),
            SettingsLoaded() => _SettingsList(state: state, isDark: isDark),
            _ => const SizedBox.shrink(),
          },
        );
      },
    );
  }
}

class _SettingsList extends StatelessWidget {
  const _SettingsList({required this.state, required this.isDark});

  final SettingsLoaded state;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final errorColor = isDark ? AppColors.errorDark : AppColors.errorLight;

    return ListView(
      children: [
        // ── AI Provider ───────────────────────────────────────────────────────
        _SectionHeader(label: 'AI Provider', isDark: isDark),
        ListTile(
          title: const Text('Provider'),
          subtitle: Text(
            state.providerType == null
                ? 'Not configured'
                : state.providerType!.name == 'gemini'
                    ? 'Google Gemini'
                    : 'BytePlus Ark',
          ),
          trailing: const Icon(LucideIcons.chevronRight, size: AppSizing.iconSm),
          onTap: () => context.push('${Routes.providerSetup}?from=settings'),
        ),
        ListTile(
          title: const Text('Provider API Key'),
          subtitle: const Text('••••••••'),
          trailing: const Icon(LucideIcons.chevronRight, size: AppSizing.iconSm),
          onTap: () => context.push('${Routes.providerSetup}?from=settings'),
        ),
        const Divider(height: 1),

        // ── Account ───────────────────────────────────────────────────────────
        _SectionHeader(label: 'Account', isDark: isDark),
        ListTile(
          title: const Text('Platform API Key'),
          subtitle: Text(
            state.platformKeyMasked,
            style: AppTextStyles.monoSmall(context),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  state.platformKeyRevealed ? LucideIcons.eyeOff : LucideIcons.eye,
                  size: AppSizing.iconSm,
                ),
                tooltip: state.platformKeyRevealed ? 'Hide key' : 'Show key',
                onPressed: () =>
                    context.read<SettingsCubit>().toggleKeyVisibility(),
              ),
              IconButton(
                icon: const Icon(LucideIcons.copy, size: AppSizing.iconSm),
                tooltip: 'Copy to clipboard',
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: state.platformKeyMasked),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Platform key copied.')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
        ListTile(
          title: const Text('Regenerate Key'),
          subtitle: const Text('Immediately invalidates the current key.'),
          leading: state.isRegeneratingKey
              ? const SizedBox(
                  width: AppSizing.iconMd,
                  height: AppSizing.iconMd,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.refreshCcw, size: AppSizing.iconMd),
          onTap: state.isRegeneratingKey ? null : () => _confirmRegenerate(context),
        ),
        const Divider(height: 1),

        // ── Usage ─────────────────────────────────────────────────────────────
        _SectionHeader(label: 'Usage', isDark: isDark),
        ListTile(
          title: const Text('Generation History'),
          subtitle: const Text('View events, costs, and filter by type.'),
          trailing: const Icon(LucideIcons.chevronRight, size: AppSizing.iconSm),
          leading: const Icon(LucideIcons.barChart2, size: AppSizing.iconMd),
          onTap: () => context.push(Routes.usage),
        ),
        const Divider(height: 1),

        // ── Vault ─────────────────────────────────────────────────────────────
        _SectionHeader(label: 'Vault', isDark: isDark),
        Builder(builder: (context) {
          final vaultPath =
              ArkMaskServices.of(context).vaultService.vaultPath ?? 'Not set';
          return ListTile(
            title: const Text('Vault Location'),
            subtitle: Text(
              vaultPath,
              style: AppTextStyles.monoSmall(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            leading:
                const Icon(LucideIcons.folderOpen, size: AppSizing.iconMd),
            trailing:
                const Icon(LucideIcons.chevronRight, size: AppSizing.iconSm),
            onTap: () =>
                context.push('${Routes.vaultSetup}?mode=change'),
          );
        }),
        const Divider(height: 1),

        // ── Credits ───────────────────────────────────────────────────────────
        _SectionHeader(label: 'Credits', isDark: isDark),
        ListTile(
          title: const Text('Credit Balance'),
          trailing: state.creditBalance != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                        vertical: AppSpacing.s1,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppColors.primarySubtleDark
                            : AppColors.primarySubtleLight,
                        borderRadius:
                            BorderRadius.circular(AppSizing.radiusFull),
                      ),
                      child: Text(
                        formatCredits(state.creditBalance!),
                        style: AppTextStyles.caption(context).copyWith(
                          color: primaryColor,
                        ),
                      ),
                    ),
                    if (state.tier != null) ...[
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        state.tier!.name.toUpperCase(),
                        style: AppTextStyles.caption(context).copyWith(
                          color: textSecondary,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ],
                )
              : Text('--', style: AppTextStyles.body(context).copyWith(color: textSecondary)),
        ),
        const Divider(height: 1),

        // ── Session ───────────────────────────────────────────────────────────
        _SectionHeader(label: 'Session', isDark: isDark),
        ListTile(
          title: Text(
            'Sign Out',
            style: AppTextStyles.body(context).copyWith(color: errorColor),
          ),
          leading: Icon(LucideIcons.logOut, color: errorColor, size: AppSizing.iconMd),
          onTap: state.isSigningOut
              ? null
              : () => _confirmSignOut(context),
        ),
        const SizedBox(height: AppSpacing.s8),
      ],
    );
  }

  /// Shows a warning dialog before regenerating the platform API key.
  Future<void> _confirmRegenerate(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate API Key?'),
        content: const Text(
          'The current platform key will be permanently invalidated. '
          'Any integrations using the old key will stop working immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Regenerate',
              style: TextStyle(
                color: isDark ? AppColors.errorDark : AppColors.errorLight,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await context.read<SettingsCubit>().regenerateKey();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to regenerate key. Please try again.'),
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your credentials will be cleared from this device. '
          'Local project files are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Sign Out',
              style: TextStyle(
                color: isDark ? AppColors.errorDark : AppColors.errorLight,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<SettingsCubit>().signOut();
    }
  }
}

/// Section header label used between groups of settings tiles.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.isDark});

  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.s4,
        right: AppSpacing.s4,
        top: AppSpacing.s5,
        bottom: AppSpacing.s2,
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.caption(context).copyWith(
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
