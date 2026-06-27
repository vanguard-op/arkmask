import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app.dart';
import '../../../core/models/models.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../cubit/provider_setup_cubit.dart';
import '../cubit/provider_setup_state.dart';

/// Provider Setup Screen — configures AI provider and stores BYOK key
/// (FEAT-003 onboarding, FEAT-022 settings update).
///
/// [fromSettings]: when true, shows "Save Changes" instead of "Save & Continue"
/// and hides the "Skip for now" option.
class ProviderSetupScreen extends StatelessWidget {
  const ProviderSetupScreen({super.key, this.fromSettings = false});

  final bool fromSettings;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) {
        final cubit = ProviderSetupCubit(storage: services.storage);
        if (fromSettings) cubit.loadExisting();
        return cubit;
      },
      child: _ProviderSetupView(fromSettings: fromSettings),
    );
  }
}

class _ProviderSetupView extends StatefulWidget {
  const _ProviderSetupView({required this.fromSettings});

  final bool fromSettings;

  @override
  State<_ProviderSetupView> createState() => _ProviderSetupViewState();
}

class _ProviderSetupViewState extends State<_ProviderSetupView> {
  final _keyController = TextEditingController();

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save(BuildContext context) async {
    final saved = await context
        .read<ProviderSetupCubit>()
        .save(apiKey: _keyController.text);
    if (!saved || !context.mounted) return;

    if (widget.fromSettings) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Provider settings saved.')),
      );
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }

  void _skip(BuildContext context) {
    context.go(Routes.home);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Complete provider setup to start generating.'),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () => context.push(Routes.settings),
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _openProviderConsole(ProviderType? provider) async {
    final url = provider == ProviderType.byteplus
        ? 'https://console.volcengine.com/ark'
        : 'https://aistudio.google.com/app/apikey';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showByokExplainer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => const _ByokExplainerSheet(),
    );
  }

  Future<void> _onProviderSelected(
    BuildContext context,
    ProviderType newProvider,
    ProviderType? currentProvider,
  ) async {
    if (currentProvider != null &&
        currentProvider != newProvider &&
        _keyController.text.isNotEmpty) {
      // Warn before clearing the entered key.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Switch provider?'),
          content: const Text(
            'Switching provider will clear the saved key. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      _keyController.clear();
    }
    if (context.mounted) {
      context.read<ProviderSetupCubit>().selectProvider(newProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final isSaving = state is ProviderSetupSaving;
        final validationError = state is ProviderSetupValidationError ? state : null;
        final selectedProvider = state.selectedProvider;

        return Scaffold(
          appBar: widget.fromSettings
              ? AppBar(
                  title: const Text('AI Provider'),
                  leading: IconButton(
                    icon: const Icon(LucideIcons.arrowLeft),
                    tooltip: 'Back',
                    onPressed: () => context.pop(),
                  ),
                )
              : null,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s6,
                vertical: AppSpacing.s8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Title ──────────────────────────────────────────────────
                  Text('Set up your AI provider', style: AppTextStyles.h1(context)),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'ArkMask uses your own provider key (BYOK) for all generation. '
                    'Your key is stored locally and never shared.',
                    style: AppTextStyles.body(context).copyWith(
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  TextButton(
                    onPressed: () => _showByokExplainer(context),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(
                      'What is BYOK?',
                      style: AppTextStyles.bodySmall(context).copyWith(
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s6),
                  // ── Provider selector ──────────────────────────────────────
                  if (validationError?.providerError != null) ...[
                    Text(
                      validationError!.providerError!,
                      style: AppTextStyles.bodySmall(context).copyWith(
                        color: isDark ? AppColors.errorDark : AppColors.errorLight,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: _ProviderCard(
                          label: 'Google Gemini',
                          isSelected: selectedProvider == ProviderType.gemini,
                          onTap: () => _onProviderSelected(
                            context, ProviderType.gemini, selectedProvider),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: _ProviderCard(
                          label: 'BytePlus Ark',
                          isSelected: selectedProvider == ProviderType.byteplus,
                          onTap: () => _onProviderSelected(
                            context, ProviderType.byteplus, selectedProvider),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  // ── API key field ──────────────────────────────────────────
                  TextFormField(
                    controller: _keyController,
                    enabled: !isSaving,
                    obscureText: state.keyObscured,
                    decoration: InputDecoration(
                      labelText: 'Provider API Key',
                      hintText: widget.fromSettings ? '••••••••' : 'Paste your key from the provider console',
                      errorText: validationError?.keyError,
                      suffixIcon: IconButton(
                        icon: Icon(
                          state.keyObscured ? LucideIcons.eyeOff : LucideIcons.eye,
                          size: AppSizing.iconSm,
                        ),
                        tooltip: state.keyObscured ? 'Show key' : 'Hide key',
                        onPressed: () =>
                            context.read<ProviderSetupCubit>().toggleKeyVisibility(),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  TextButton(
                    onPressed: () => _openProviderConsole(selectedProvider),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(
                      'Get your API key →',
                      style: AppTextStyles.bodySmall(context).copyWith(
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  // ── Save button ────────────────────────────────────────────
                  SizedBox(
                    height: AppSizing.buttonLg,
                    child: ElevatedButton(
                      onPressed: isSaving ? null : () => _save(context),
                      child: isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : Text(widget.fromSettings ? 'Save Changes' : 'Save & Continue'),
                    ),
                  ),
                  // ── Skip (onboarding only) ─────────────────────────────────
                  if (!widget.fromSettings) ...[
                    const SizedBox(height: AppSpacing.s3),
                    Center(
                      child: TextButton(
                        onPressed: () => _skip(context),
                        child: Text(
                          'Skip for now',
                          style: AppTextStyles.body(context).copyWith(
                            color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Selectable provider card with primary border + background when selected.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final borderColor = isSelected
        ? primaryColor
        : (isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight);
    final bgColor = isSelected
        ? (isDark ? AppColors.primarySubtleDark : AppColors.primarySubtleLight)
        : Colors.transparent;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSizing.radiusSm),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.body(context).copyWith(
            color: isSelected ? primaryColor : null,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Bottom sheet explaining the BYOK (Bring Your Own Key) model.
class _ByokExplainerSheet extends StatelessWidget {
  const _ByokExplainerSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.borderStrongDark
                    : AppColors.borderStrongLight,
                borderRadius: BorderRadius.circular(AppSizing.radiusFull),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s6),
          Text('What is BYOK?', style: AppTextStyles.h2(context)),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'BYOK stands for "Bring Your Own Key." ArkMask does not pay your AI provider bills — '
            'you use your own Google Gemini or BytePlus Ark account. '
            'Your API key is stored only on your device in secure storage (iOS Keychain / Android Keystore). '
            'It is sent directly to the provider on each generation request and is never stored or logged by ArkMask.',
            style: AppTextStyles.body(context),
          ),
          const SizedBox(height: AppSpacing.s6),
        ],
      ),
    );
  }
}
