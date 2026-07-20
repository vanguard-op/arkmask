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

/// Login Screen — authenticates returning users (FEAT-002, FEAT-031).
///
/// Includes an inline "Forgot password?" flow (FEAT-031) that expands below
/// the password field without navigating away.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => LoginCubit(
        authService: services.authService,
        apiClient: services.apiClient,
      ),
      child: const _LoginView(),
    );
  }
}

class _LoginView extends StatefulWidget {
  const _LoginView();

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _resetEmailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePassword = true;
  bool _showForgotPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _resetEmailController.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;
    context.read<LoginCubit>().login(
          email: _emailController.text,
          password: _passwordController.text,
        );
  }

  void _sendReset(BuildContext context) {
    final email = _resetEmailController.text.trim();
    if (email.isEmpty) return;
    context.read<LoginCubit>().sendPasswordReset(email: email);
  }

  void _toggleForgotPassword() {
    setState(() {
      _showForgotPassword = !_showForgotPassword;
      // Pre-fill reset email with whatever is in the login email field.
      if (_showForgotPassword && _emailController.text.isNotEmpty) {
        _resetEmailController.text = _emailController.text;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return BlocConsumer<LoginCubit, LoginState>(
      listener: (context, state) {
        switch (state) {
          case LoginSuccess():
            context.go(Routes.home);
          case LoginFailure(:final message):
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
            context.read<LoginCubit>().reset();
          case PasswordResetSent():
            setState(() {
              _showForgotPassword = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Check your email for a reset link.')),
            );
            context.read<LoginCubit>().reset();
          case PasswordResetFailure(:final message):
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
            context.read<LoginCubit>().reset();
          default:
            break;
        }
      },
      builder: (context, state) {
        final isSubmitting = state is LoginSubmitting;

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
                    Text('Welcome back', style: AppTextStyles.h1(context)),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      'Sign in to continue.',
                      style: AppTextStyles.body(context).copyWith(
                        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    // ── Email field ───────────────────────────────────────────
                    TextFormField(
                      controller: _emailController,
                      enabled: !isSubmitting,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return 'Email is required.';
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
                        if ((v ?? '').isEmpty) return 'Password is required.';
                        return null;
                      },
                    ),
                    // ── Forgot password link ──────────────────────────────────
                    const SizedBox(height: AppSpacing.s2),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _toggleForgotPassword,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, AppSizing.touchMin),
                        ),
                        child: Text(
                          'Forgot password?',
                          style: AppTextStyles.bodySmall(context).copyWith(
                            color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                          ),
                        ),
                      ),
                    ),
                    // ── Forgot password inline expansion ──────────────────────
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      child: _showForgotPassword
                          ? _ForgotPasswordPanel(
                              controller: _resetEmailController,
                              onSend: () => _sendReset(context),
                              onCancel: _toggleForgotPassword,
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: AppSpacing.s6),
                    // ── Log In button ─────────────────────────────────────────
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
                            : const Text('Log In'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    // ── Create account link ───────────────────────────────────
                    Center(
                      child: TextButton(
                        // push, not go — go replaces the whole stack, which
                        // left nothing for the AppBar back button to pop
                        // back to after switching between Login and Signup.
                        onPressed: () => context.push(Routes.register),
                        child: RichText(
                          text: TextSpan(
                            text: "Don't have an account? ",
                            style: AppTextStyles.body(context).copyWith(
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                            children: [
                              TextSpan(
                                text: 'Create one',
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

/// Inline "Forgot Password" panel that expands below the password field.
/// Shown/hidden via [AnimatedSize] for a smooth expand/collapse.
class _ForgotPasswordPanel extends StatelessWidget {
  const _ForgotPasswordPanel({
    required this.controller,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s3, bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        border: Border.all(
          color: isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reset your password',
            style: AppTextStyles.h3(context),
          ),
          const SizedBox(height: AppSpacing.s3),
          TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Registered email',
              hintText: 'Enter your registered email',
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: ElevatedButton(
                  onPressed: onSend,
                  child: const Text('Send Reset Link'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
