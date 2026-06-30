import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'core/api/ark_mask_api_client.dart';
import 'core/auth/auth_service.dart';
import 'core/filesystem/project_file_service.dart';
import 'core/jobs/generation_job_manager.dart';
import 'core/jobs/job_registry_service.dart';
import 'core/router/router.dart';
import 'core/storage/secure_storage_service.dart';
import 'core/theme/app_theme.dart';

/// Root widget for ArkMask.
///
/// Wires together shared service singletons and provides them to the widget
/// tree via [ArkMaskServices]. Theme and router are configured here.
///
/// Service lifecycle:
/// - [SecureStorageService] — credential reads/writes (always ready).
/// - [ArkMaskApiClient] — HTTP client; credentials injected per-request.
/// - [AuthService] — Firebase Auth wrapper.
/// - [JobRegistryService] — in-memory job tracking (Phase 1); Phase 2 opens
///   a Hive CE box here instead.
/// - [ProjectFileService] — kept for Phase 2 backward compat; uninitialized
///   in Phase 1 (vault guard removed, no local filesystem path configured).
/// - [GenerationJobManager] — kept for Phase 2 backward compat; Phase 2
///   cubits will migrate to [JobRegistryService].
class ArkMaskApp extends StatefulWidget {
  const ArkMaskApp({super.key});

  @override
  State<ArkMaskApp> createState() => _ArkMaskAppState();
}

class _ArkMaskAppState extends State<ArkMaskApp> {
  late final SecureStorageService _storage;
  late final ArkMaskApiClient _apiClient;
  late final AuthService _authService;
  late final JobRegistryService _jobRegistryService;
  late final ProjectFileService _fileService; // Phase 2 compat
  late final GenerationJobManager _jobManager; // Phase 2 compat
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
    _jobRegistryService = JobRegistryService()..pruneStale();
    _fileService = ProjectFileService(); // uninitialized — Phase 2 only
    _jobManager = GenerationJobManager(); // Phase 2 compat

    _routerWrapper = GoRouterWrapper(
      storage: _storage,
      firebaseAuth: FirebaseAuth.instance,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ArkMaskServices(
      storage: _storage,
      apiClient: _apiClient,
      authService: _authService,
      jobRegistryService: _jobRegistryService,
      fileService: _fileService,
      jobManager: _jobManager,
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
  }) : router = buildRouter(
          storage: storage,
          firebaseAuth: firebaseAuth,
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
    required this.jobRegistryService,
    required this.fileService,
    required this.jobManager,
    required super.child,
  });

  final SecureStorageService storage;
  final ArkMaskApiClient apiClient;
  final AuthService authService;

  /// Cloud-first job registry. Observe via [ListenableBuilder] to rebuild on
  /// job status changes.
  final JobRegistryService jobRegistryService;

  /// Phase 2 compat — uninitialized in Phase 1. Remove in Phase 2.
  final ProjectFileService fileService;

  /// Phase 2 compat — replaced by [jobRegistryService] in Phase 2.
  final GenerationJobManager jobManager;

  static ArkMaskServices of(BuildContext context) {
    final result = context.dependOnInheritedWidgetOfExactType<ArkMaskServices>();
    assert(result != null, 'No ArkMaskServices found in context. '
        'Ensure ArkMaskApp is an ancestor.');
    return result!;
  }

  @override
  bool updateShouldNotify(ArkMaskServices oldWidget) => false;
}
