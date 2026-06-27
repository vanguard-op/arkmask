import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../firebase_options.dart';
import '../../../shared/widgets/ark_mask_symbol.dart';

/// Splash / Welcome Screen — app entry point that routes users based on
/// their auth state (Screen 1 in screens.md).
///
/// On mount: checks Firebase auth + secure storage for a valid session and
/// provider credentials. Routes to Home, Provider Setup, or shows the
/// Welcome UI (Create Account / Log In).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacityAnim;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _wordmarkOpacityAnim;
  late final Animation<double> _buttonsOpacityAnim;

  bool _showButtons = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    // Symbol: fade + 12px upward translate over 400ms.
    _opacityAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.57, curve: Curves.easeOut),
      ),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.57, curve: Curves.easeOut),
      ),
    );

    // Wordmark: fades in 150ms after symbol (starts at 400ms).
    _wordmarkOpacityAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.57, 0.85, curve: Curves.easeOut),
      ),
    );

    // Buttons: fade in after animation completes (when no session).
    _buttonsOpacityAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.85, 1, curve: Curves.easeOut),
      ),
    );

    _controller.forward();
    _checkAuthAndRoute();
  }

  Future<void> _checkAuthAndRoute() async {
    final services = ArkMaskServices.of(context);

    // Always play logo animation regardless of auth state.
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    if (!isFirebaseConfigured) {
      // Firebase not yet configured — show welcome buttons.
      setState(() => _showButtons = true);
      return;
    }

    final isSignedIn = services.authService.isSignedIn;
    if (!isSignedIn) {
      setState(() => _showButtons = true);
      return;
    }

    // Signed in — check provider credentials.
    final hasProvider = await services.storage.hasProviderCredentials();
    if (!mounted) return;

    if (hasProvider) {
      context.go(Routes.home);
    } else {
      context.go(Routes.providerSetup);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final textTertiary = isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    return Scaffold(
      backgroundColor: isDark ? AppColors.surfaceBaseDark : AppColors.surfaceBaseLight,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Column(
            children: [
              const Spacer(flex: 3),
              // ── ArkMask symbol ──────────────────────────────────────────────
              SlideTransition(
                position: _slideAnim,
                child: FadeTransition(
                  opacity: _opacityAnim,
                  child: ArkMaskSymbol(color: primaryColor, size: 80),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              // ── Wordmark ────────────────────────────────────────────────────
              FadeTransition(
                opacity: _wordmarkOpacityAnim,
                child: Text(
                  'ArkMask',
                  style: AppTextStyles.h1(context).copyWith(
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(flex: 2),
              // ── Buttons (only shown when no session) ────────────────────────
              if (_showButtons) ...[
                FadeTransition(
                  opacity: _buttonsOpacityAnim,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton(
                        onPressed: () => context.push(Routes.register),
                        child: const Text('Create Account'),
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      TextButton(
                        onPressed: () => context.push(Routes.login),
                        child: const Text('Log In'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
              ],
              // ── Tagline ─────────────────────────────────────────────────────
              FadeTransition(
                opacity: _wordmarkOpacityAnim,
                child: Text(
                  'Your story. No face required.',
                  style: AppTextStyles.bodySmall(context).copyWith(
                    color: textTertiary,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s6),
            ],
          ),
        ),
      ),
    );
  }
}

