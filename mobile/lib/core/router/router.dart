import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/assets/screens/asset_editor_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/editor/screens/video_editor_screen.dart';
import '../../features/auth/screens/registration_screen.dart';
import '../../features/auth/screens/splash_screen.dart';
import '../../features/player/screens/video_player_screen.dart';
import '../../features/projects/screens/home_screen.dart';
import '../../features/projects/screens/project_file_browser_screen.dart';
import '../../features/provider_setup/screens/provider_setup_screen.dart';
import '../../features/billing/screens/billing_return_screen.dart';
import '../../features/billing/screens/upgrade_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/usage/screens/usage_screen.dart';
import '../../features/scene/screens/scene_detail_screen.dart';
import '../../features/story/screens/story_editor_screen.dart';
import '../storage/secure_storage_service.dart';
import 'routes.dart';

/// Builds the [GoRouter] for ArkMask.
///
/// Guards (evaluated in order on every navigation):
/// 1. **Auth guard** — unauthenticated users are redirected to `/` (splash).
/// 2. **Provider guard** — authenticated users without a provider key are
///    redirected to `/provider-setup` before accessing `/home` or deeper routes.
///
/// The vault guard that previously redirected to `/vault-setup` has been
/// removed in the cloud-first architecture — there is no local filesystem
/// vault to configure.
///
/// The [FirebaseAuth] stream is used as a listenable so the router
/// re-evaluates the redirect on auth state changes (login, logout, expiry).
GoRouter buildRouter({
  required SecureStorageService storage,
  required FirebaseAuth firebaseAuth,
}) {
  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: _AuthNotifier(firebaseAuth),
    redirect: (context, state) async {
      final loc = state.matchedLocation;

      // ── 1. Auth guard ─────────────────────────────────────────────────────
      final isSignedIn = firebaseAuth.currentUser != null;

      final isAuthScreen = loc == Routes.splash ||
          loc == Routes.login ||
          loc == Routes.register ||
          loc == Routes.providerSetup;

      if (!isSignedIn && !isAuthScreen) {
        return Routes.splash;
      }

      // ── 2. Provider guard ─────────────────────────────────────────────────
      // Authenticated users who have not configured a provider key are
      // redirected to the provider setup screen. Settings is exempt so the
      // user can update credentials from there.
      if (isSignedIn && !isAuthScreen) {
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
          // When accessed from Settings show "Save Changes" instead of
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
          // The path parameter carries the immutable project slug
          // (URL-encoded). See Routes.projectBrowser.
          final projectSlug = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          return ProjectFileBrowserScreen(projectSlug: projectSlug);
        },
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),

      // ── Phase 2 screens ─────────────────────────────────────────────────────
      GoRoute(
        path: Routes.storyEditor,
        builder: (context, state) {
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          return StoryEditorScreen(projectName: projectName);
        },
      ),
      GoRoute(
        path: Routes.assetEditor,
        builder: (context, state) {
          // :projectName holds the project slug; :assetPath holds the qualified
          // Firestore path segment (e.g. "assets/abc123" or
          // "scenes/xyz/assets/def456"), URL-encoded by the file browser.
          final projectSlug = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          final assetPath = Uri.decodeComponent(
            state.pathParameters['assetPath'] ?? '',
          );
          return AssetEditorScreen(
            projectSlug: projectSlug,
            assetPath: assetPath,
          );
        },
      ),
      GoRoute(
        path: Routes.sceneDetail,
        builder: (context, state) {
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          final sceneId =
              int.tryParse(state.pathParameters['sceneId'] ?? '') ?? 1;
          return SceneDetailScreen(
            projectName: projectName,
            sceneId: sceneId,
          );
        },
      ),
      GoRoute(
        path: Routes.videoEditor,
        builder: (context, state) {
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          return VideoEditorScreen(projectName: projectName);
        },
      ),
      GoRoute(
        path: Routes.videoPlayer,
        builder: (context, state) {
          // `path` query param carries either an absolute filesystem path
          // (Phase 2, legacy) or a GCS presigned URL (Phase 3+).
          // Both are URL-encoded strings and decoded here identically.
          final videoPath = state.uri.queryParameters['path'] ?? '';
          final title = state.uri.queryParameters['title'];
          return VideoPlayerScreen(
            videoPath: Uri.decodeComponent(videoPath),
            title: title,
          );
        },
      ),
      GoRoute(
        path: Routes.upgrade,
        builder: (context, state) {
          final highlight = state.uri.queryParameters['highlight'];
          return UpgradeScreen(highlightPlan: highlight);
        },
      ),
      GoRoute(
        path: Routes.usage,
        builder: (context, state) => const UsageScreen(),
      ),
      GoRoute(
        path: Routes.billingReturn,
        builder: (context, state) {
          final status = state.uri.queryParameters['status'] ?? '';
          return BillingReturnScreen(status: status);
        },
      ),
    ],
  );
}

/// [ChangeNotifier] that fires whenever Firebase auth state changes.
/// Used as [GoRouter.refreshListenable] so the router re-evaluates the
/// redirect on sign-in and sign-out.
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
