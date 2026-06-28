import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'core/api/ark_mask_api_client.dart';
import 'core/auth/auth_service.dart';
import 'core/filesystem/project_file_service.dart';
import 'core/jobs/generation_job_manager.dart';
import 'core/router/router.dart';
import 'core/storage/secure_storage_service.dart';
import 'core/theme/app_theme.dart';
import 'core/vault/vault_service.dart';

/// Root widget for ArkMask.
///
/// Wires together the shared service instances (auth, API, storage, filesystem)
/// and provides them down the widget tree via [InheritedWidget].
/// Theme and router are configured here.
class ArkMaskApp extends StatefulWidget {
  const ArkMaskApp({super.key});

  @override
  State<ArkMaskApp> createState() => _ArkMaskAppState();
}

class _ArkMaskAppState extends State<ArkMaskApp> {
  late final SecureStorageService _storage;
  late final ArkMaskApiClient _apiClient;
  late final AuthService _authService;
  late final ProjectFileService _fileService;
  late final GenerationJobManager _jobManager;
  late final VaultService _vaultService;
  late final GoRouterWrapper _routerWrapper;

  @override
  void initState() {
    super.initState();
    _storage = SecureStorageService();
    _apiClient = ArkMaskApiClient(storage: _storage);
    _authService = AuthService(
      storageService: _storage,
      firebaseAuth: FirebaseAuth.instance,
    );
    _vaultService = VaultService();
    _fileService = ProjectFileService();
    // Vault initialization and file-service bootstrapping happen lazily inside
    // the router redirect so they complete before the first navigation.
    _jobManager = GenerationJobManager();

    _routerWrapper = GoRouterWrapper(
      storage: _storage,
      firebaseAuth: FirebaseAuth.instance,
      vaultService: _vaultService,
      fileService: _fileService,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ArkMaskServices(
      storage: _storage,
      apiClient: _apiClient,
      authService: _authService,
      fileService: _fileService,
      jobManager: _jobManager,
      vaultService: _vaultService,
      child: MaterialApp.router(
        title: 'ArkMask',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        // Dark mode is the primary experience per branding.md.
        themeMode: ThemeMode.dark,
        routerConfig: _routerWrapper.router,
      ),
    );
  }
}

/// Holds the [GoRouter] instance stable across rebuilds.
class GoRouterWrapper {
  GoRouterWrapper({
    required SecureStorageService storage,
    required FirebaseAuth firebaseAuth,
    required VaultService vaultService,
    required ProjectFileService fileService,
  }) : router = buildRouter(
          storage: storage,
          firebaseAuth: firebaseAuth,
          vaultService: vaultService,
          fileService: fileService,
        );

  final GoRouter router;
}

// ── Dependency injection via InheritedWidget ──────────────────────────────────

/// Provides shared service instances to the widget subtree.
///
/// Usage:
/// ```dart
/// final services = ArkMaskServices.of(context);
/// services.authService.signOut();
/// ```
class ArkMaskServices extends InheritedWidget {
  const ArkMaskServices({
    super.key,
    required this.storage,
    required this.apiClient,
    required this.authService,
    required this.fileService,
    required this.jobManager,
    required this.vaultService,
    required super.child,
  });

  final SecureStorageService storage;
  final ArkMaskApiClient apiClient;
  final AuthService authService;
  final ProjectFileService fileService;

  /// Singleton job manager for tracking all in-progress generation steps
  /// (FEAT-017). Widgets listen via [ListenableBuilder].
  final GenerationJobManager jobManager;

  /// Manages the user-chosen vault folder and migration from legacy storage.
  final VaultService vaultService;

  static ArkMaskServices of(BuildContext context) {
    final result = context.dependOnInheritedWidgetOfExactType<ArkMaskServices>();
    assert(result != null, 'No ArkMaskServices found in context. '
        'Ensure ArkMaskApp is an ancestor.');
    return result!;
  }

  @override
  bool updateShouldNotify(ArkMaskServices oldWidget) => false;
}
