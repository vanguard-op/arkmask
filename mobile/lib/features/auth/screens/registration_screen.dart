import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/ark_mask_symbol.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/auth_state.dart';

/// Registration Screen — creates a new ArkMask account (FEAT-001).
///
/// On success: navigates to Provider Setup Screen.
/// The platform API key is saved to secure storage inside [AuthService].
class RegistrationScreen extends StatelessWidget {
  const RegistrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => RegistrationCubit(
        authService: services.authService,
        apiClient: services.apiClient,
      ),
      child: const _RegistrationView(),
    );
  }
}

class _RegistrationView extends StatefulWidget {
  const _RegistrationView();

  @override
  State<_RegistrationView> createState() => _RegistrationViewState();
}

class _RegistrationViewState extends State<_RegistrationView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _passwordTouched = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _passwordMeetsLength => _passwordController.text.length >= 8;

  void _submit(BuildContext context) {
    setState(() => _passwordTouched = true);
    if (!_formKey.currentState!.validate()) return;
    context.read<RegistrationCubit>().register(
          email: _emailController.text,
          password: _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final successColor = isDark ? AppColors.successDark : AppColors.successLight;
    final errorColor = isDark ? AppColors.errorDark : AppColors.errorLight;
    final textTertiary = isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    return BlocConsumer<RegistrationCubit, RegistrationState>(
      listener: (context, state) {
        switch (state) {
          case RegistrationSuccess():
            context.go(Routes.providerSetup);
          case RegistrationFailure(:final message):
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _submit(context),
                ),
              ),
            );
            context.read<RegistrationCubit>().reset();
          default:
            break;
        }
      },
      builder: (context, state) {
        final isSubmitting = state is RegistrationSubmitting;
        final isConflict = state is RegistrationEmailConflict;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: 'Back',
              onPressed: () => context.pop(),
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: AppSpacing.s8),
                    // ── Brand mark ────────────────────────────────────────────
                    Center(
                      child: ArkMaskSymbol(color: primaryColor, size: 32),
                    ),
                    const SizedBox(height: AppSpacing.s6),
                    // ── Title ─────────────────────────────────────────────────
                    Text('Create your account', style: AppTextStyles.h1(context)),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      'Get a platform key and start creating.',
                      style: AppTextStyles.body(context).copyWith(
                        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    // ── Email conflict banner ──────────────────────────────────
                    if (isConflict) ...[
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.s3),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
                          border: Border.all(color: primaryColor.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'An account with this email already exists.',
                                style: AppTextStyles.bodySmall(context),
                              ),
                            ),
                            TextButton(
                              onPressed: () => context.go(Routes.login),
                              child: const Text('Log in'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s4),
                    ],
                    // ── Email field ───────────────────────────────────────────
                    TextFormField(
                      controller: _emailController,
                      enabled: !isSubmitting,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) {
                        final val = v?.trim() ?? '';
                        if (val.isEmpty) return 'Email is required.';
                        if (!val.contains('@')) return 'Enter a valid email address.';
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    // ── Password field ────────────────────────────────────────
                    TextFormField(
                      controller: _passwordController,
                      enabled: !isSubmitting,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() {}),
                      onFieldSubmitted: (_) => _submit(context),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword ? LucideIcons.eyeOff : LucideIcons.eye,
                            size: AppSizing.iconSm,
                          ),
                          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                          onPressed: () =>
                              setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) {
                        if ((v ?? '').length < 8) return null; // shown via indicator below
                        return null;
                      },
                    ),
                    // ── Password requirement indicator ─────────────────────────
                    const SizedBox(height: AppSpacing.s2),
                    Row(
                      children: [
                        Icon(
                          _passwordMeetsLength ? LucideIcons.checkCircle : LucideIcons.circle,
                          size: AppSizing.iconXs,
                          color: _passwordTouched && !_passwordMeetsLength
                              ? errorColor
                              : _passwordMeetsLength
                                  ? successColor
                                  : textTertiary,
                        ),
                        const SizedBox(width: AppSpacing.s1),
                        Text(
                          '8+ characters',
                          style: AppTextStyles.bodySmall(context).copyWith(
                            color: _passwordTouched && !_passwordMeetsLength
                                ? errorColor
                                : _passwordMeetsLength
                                    ? successColor
                                    : textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s6),
                    // ── Register button ───────────────────────────────────────
                    SizedBox(
                      height: AppSizing.buttonLg,
                      child: ElevatedButton(
                        onPressed: isSubmitting ? null : () => _submit(context),
                        child: isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(Colors.white),
                                ),
                              )
                            : const Text('Register'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    // ── Log in link ───────────────────────────────────────────
                    Center(
                      child: TextButton(
                        onPressed: () => context.go(Routes.login),
                        child: RichText(
                          text: TextSpan(
                            text: 'Already have an account? ',
                            style: AppTextStyles.body(context).copyWith(
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                            children: [
                              TextSpan(
                                text: 'Log in',
                                style: TextStyle(
                                  color: primaryColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
