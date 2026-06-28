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
import '../../features/billing/screens/upgrade_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/usage/screens/usage_screen.dart';
import '../../features/vault_setup/screens/vault_setup_screen.dart';
import '../../features/scene/screens/scene_detail_screen.dart';
import '../../features/story/screens/story_editor_screen.dart';
import '../filesystem/project_file_service.dart';
import '../storage/secure_storage_service.dart';
import '../vault/vault_service.dart';
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
/// Guards (evaluated in order on every navigation):
/// 1. **Vault guard** — redirects to `/vault-setup` until the user has chosen
///    a vault folder. Also lazily initializes [VaultService] and
///    [ProjectFileService] on the first navigation so the router can be
///    constructed synchronously in [initState].
/// 2. **Auth guard** — unauthenticated users are redirected to `/`.
/// 3. **Provider guard** — authenticated users without a provider key are
///    redirected to `/provider-setup` before accessing `/home` or deeper routes.
///
/// The [FirebaseAuth] stream is used as a listenable so the router re-evaluates
/// redirect on auth state changes (login, logout, session expiry).
GoRouter buildRouter({
  required SecureStorageService storage,
  required FirebaseAuth firebaseAuth,
  required VaultService vaultService,
  required ProjectFileService fileService,
}) {
  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: _AuthNotifier(firebaseAuth),
    redirect: (context, state) async {
      final loc = state.matchedLocation;

      // ── 1. Vault guard ────────────────────────────────────────────────────
      // Initialize the vault service once (idempotent) and, if a vault path
      // is known, initialize the file service with it.
      if (!vaultService.isInitialized) {
        await vaultService.initialize();
        if (vaultService.isConfigured) {
          await fileService.initialize(vaultService.vaultPath!);
        }
      }

      final isVaultScreen = loc == Routes.vaultSetup;
      if (!vaultService.isConfigured && !isVaultScreen) {
        return Routes.vaultSetup;
      }
      // Allow vault setup screen to be reached freely.
      if (isVaultScreen) return null;

      // ── 2. Auth guard ─────────────────────────────────────────────────────
      final isSignedIn = firebaseAuth.currentUser != null;

      final isAuthScreen = loc == Routes.splash ||
          loc == Routes.login ||
          loc == Routes.register ||
          loc == Routes.providerSetup;

      if (!isSignedIn && !isAuthScreen) {
        return Routes.splash;
      }

      // ── 3. Provider guard ─────────────────────────────────────────────────
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
        path: Routes.vaultSetup,
        builder: (context, state) {
          final isChange = state.uri.queryParameters['mode'] == 'change';
          return VaultSetupScreen(isChange: isChange);
        },
      ),
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
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          // assetPath is the full directory path, URL-encoded to handle slashes.
          final assetDirPath = Uri.decodeComponent(
            state.pathParameters['assetPath'] ?? '',
          );
          return AssetEditorScreen(
            projectName: projectName,
            assetDirPath: assetDirPath,
          );
        },
      ),
      GoRoute(
        path: Routes.sceneDetail,
        builder: (context, state) {
          final projectName = Uri.decodeComponent(
            state.pathParameters['projectName'] ?? '',
          );
          final sceneId = int.tryParse(
                state.pathParameters['sceneId'] ?? '',
              ) ??
              1;
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
          // `path` query param carries the absolute filesystem path (URL-encoded).
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
