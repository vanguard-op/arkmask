import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/registration_screen.dart';
import '../../features/auth/screens/splash_screen.dart';
import '../../features/projects/screens/home_screen.dart';
import '../../features/projects/screens/project_file_browser_screen.dart';
import '../../features/provider_setup/screens/provider_setup_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../storage/secure_storage_service.dart';
import 'routes.dart';

/// Placeholder screen for Phase 2+ routes that are declared in the skeleton
/// but not yet implemented.
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Text(
            '$title — coming in a future phase',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
}

/// Builds the [GoRouter] for ArkMask.
///
/// Guards:
/// 1. **Auth guard** — unauthenticated users are redirected to `/`.
/// 2. **Provider guard** — authenticated users without a provider key are
///    redirected to `/provider-setup` before accessing `/home` or deeper routes.
///
/// The [FirebaseAuth] stream is used as a listenable so the router re-evaluates
/// redirect on auth state changes (login, logout, session expiry).
GoRouter buildRouter({
  required SecureStorageService storage,
  required FirebaseAuth firebaseAuth,
}) {
  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: _AuthNotifier(firebaseAuth),
    redirect: (context, state) async {
      final isSignedIn = firebaseAuth.currentUser != null;
      final loc = state.matchedLocation;

      // Allow all auth screens without checks.
      final isAuthScreen = loc == Routes.splash ||
          loc == Routes.login ||
          loc == Routes.register ||
          loc == Routes.providerSetup;

      if (!isSignedIn && !isAuthScreen) {
        return Routes.splash;
      }

      if (isSignedIn && !isAuthScreen) {
        // Ensure provider credentials are set before deeper routes.
        final hasProvider = await storage.hasProviderCredentials();
        if (!hasProvider && loc != Routes.settings) {
          return Routes.providerSetup;
        }
      }

      return null; // no redirect
    },
    routes: [
      GoRoute(
        path: Routes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.register,
        builder: (context, state) => const RegistrationScreen(),
      ),
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.providerSetup,
        builder: (context, state) {
          // When accessed from Settings, show "Save Changes" instead of
          // "Save & Continue" and hide the "Skip for now" link.
          final fromSettings = state.uri.queryParameters['from'] == 'settings';
          return ProviderSetupScreen(fromSettings: fromSettings);
        },
      ),
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: Routes.projectBrowser,
        builder: (context, state) {
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          return ProjectFileBrowserScreen(projectName: projectName);
        },
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),

      // ── Phase 2+ stub routes ────────────────────────────────────────────────
      GoRoute(
        path: Routes.storyEditor,
        builder: (context, state) => const _PlaceholderScreen(title: 'Story Editor'),
      ),
      GoRoute(
        path: Routes.assetEditor,
        builder: (context, state) => const _PlaceholderScreen(title: 'Asset Editor'),
      ),
      GoRoute(
        path: Routes.sceneDetail,
        builder: (context, state) => const _PlaceholderScreen(title: 'Scene Detail'),
      ),
      GoRoute(
        path: Routes.videoEditor,
        builder: (context, state) => const _PlaceholderScreen(title: 'Video Editor'),
      ),
      GoRoute(
        path: Routes.videoPlayer,
        builder: (context, state) => const _PlaceholderScreen(title: 'Video Player'),
      ),
      GoRoute(
        path: Routes.upgrade,
        builder: (context, state) => const _PlaceholderScreen(title: 'Upgrade'),
      ),
      GoRoute(
        path: Routes.usage,
        builder: (context, state) => const _PlaceholderScreen(title: 'Usage Dashboard'),
      ),
    ],
  );
}

/// [ChangeNotifier] that fires whenever Firebase auth state changes.
/// Used as [GoRouter.refreshListenable] so the router re-evaluates redirect
/// on sign-in and sign-out.
class _AuthNotifier extends ChangeNotifier {
  _AuthNotifier(FirebaseAuth auth) {
    _sub = auth.authStateChanges().listen((_) => notifyListeners());
  }

  late final Object _sub;

  @override
  void dispose() {
    (_sub as dynamic).cancel();
    super.dispose();
  }
}
