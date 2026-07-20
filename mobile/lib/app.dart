import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:go_router/go_router.dart';

import 'core/api/ark_mask_api_client.dart';
import 'core/auth/auth_service.dart';
import 'core/filesystem/project_file_service.dart';
import 'core/jobs/job_registry_service.dart';
import 'core/jobs/jobs_cubit.dart';
import 'core/messaging/fcm_service.dart';
import 'core/router/router.dart';
import 'core/storage/secure_storage_service.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';

/// Baseline system UI style for the app root — the system navigation bar
/// takes the app's own dark surface color (instead of the OS default black,
/// which read as a jarring mismatched bar) and its divider is hidden so it
/// blends into the Scaffold background seamlessly. themeMode is pinned to
/// ThemeMode.dark app-wide (see below), so this is hardcoded to the dark
/// surface token rather than switching on Theme.of(context).
///
/// Screens that need a different style while they're on top (e.g.
/// [VideoPlayerScreen]'s black fullscreen player) wrap themselves in their
/// own nested AnnotatedRegion — Flutter automatically reverts to this root
/// region's style the instant that screen is popped, no manual restore
/// needed (this is what was missing before: nothing ever established this
/// baseline, so restoring "edgeToEdge" mode after the player closed left the
/// navigation bar in an undefined, sometimes content-overlapping state).
const _rootSystemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: AppColors.surfaceBaseDark,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Colors.transparent,
);

/// Root widget for ArkMask.
///
/// Wires together shared service singletons and provides them to the widget
/// tree via [ArkMaskServices]. Theme and router are configured here.
///
/// Service lifecycle:
/// - [SecureStorageService] — credential reads/writes (always ready).
/// - [ArkMaskApiClient] — HTTP client; credentials injected per-request.
/// - [AuthService] — Firebase Auth wrapper.
/// - [JobRegistryService] — persistent Hive CE job log; survives app restarts.
/// - [JobsCubit] — app-lifetime "Pipeline Orchestrator" (see
///   docs/ArkMask/architecture.md) built on top of [JobRegistryService].
///   Created once here — NOT per-screen — so job state (and the "N
///   generating" / spinner / progress indicators derived from it) is never
///   lost when the user navigates away from and back to a screen.
/// - [FcmService] — resolves jobs via push notification regardless of which
///   screen is mounted; [JobsCubit.pollPendingJobs] covers missed pushes.
/// - [ProjectFileService] — kept for Phase 2 backward compat; uninitialized
///   in Phase 1 (vault guard removed, no local filesystem path configured).
class ArkMaskApp extends StatefulWidget {
  const ArkMaskApp({super.key});

  @override
  State<ArkMaskApp> createState() => _ArkMaskAppState();
}

class _ArkMaskAppState extends State<ArkMaskApp> with WidgetsBindingObserver {
  late final SecureStorageService _storage;
  late final ArkMaskApiClient _apiClient;
  late final AuthService _authService;
  late final JobRegistryService _jobRegistryService;
  late final JobsCubit _jobsCubit;
  late final FcmService _fcmService;
  late final ProjectFileService _fileService; // Phase 2 compat
  late final GoRouterWrapper _routerWrapper;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _storage = SecureStorageService();
    _apiClient = ArkMaskApiClient(storage: _storage);
    _authService = AuthService(
      storageService: _storage,
      firebaseAuth: FirebaseAuth.instance,
    );

    _jobRegistryService = JobRegistryService();
    _jobsCubit = JobsCubit(
      jobRegistryService: _jobRegistryService,
      apiClient: _apiClient,
    );

    // Open the Hive CE box asynchronously, then prune stale terminal entries
    // and run one recovery poll for anything still pending from a previous
    // session (app force-close, crash, etc — architecture.md fallback path).
    _jobRegistryService.init().then((_) {
      _jobRegistryService.pruneStale();
      _jobsCubit.pollPendingJobs();
    });

    // FCM is the primary job-completion signal; wired independently of the
    // widget tree so it keeps resolving jobs even while no relevant screen
    // is mounted. Fire-and-forget — init() never throws.
    _fcmService = FcmService();
    _fcmService.init(jobsCubit: _jobsCubit);

    _fileService = ProjectFileService(); // uninitialized — Phase 2 only

    _routerWrapper = GoRouterWrapper(
      storage: _storage,
      firebaseAuth: FirebaseAuth.instance,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-return recovery poll — the documented fallback for a missed
    // FCM push (architecture.md "Platform Notes"). Ensures job state (and
    // therefore every progress indicator derived from JobsCubit) is
    // eventually correct even if push delivery failed entirely.
    if (state == AppLifecycleState.resumed) {
      _jobsCubit.pollPendingJobs();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fcmService.dispose();
    _jobsCubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _rootSystemUiOverlayStyle,
      child: BlocProvider<JobsCubit>.value(
        value: _jobsCubit,
        child: ArkMaskServices(
          storage: _storage,
          apiClient: _apiClient,
          authService: _authService,
          jobRegistryService: _jobRegistryService,
          jobsCubit: _jobsCubit,
          fileService: _fileService,
          child: MaterialApp.router(
            title: 'ArkMask',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            // Dark mode is the primary experience per branding.md.
            themeMode: ThemeMode.dark,
            routerConfig: _routerWrapper.router,
          ),
        ),
      ),
    );
  }
}

/// Holds the [GoRouter] instance stable across rebuilds.
class GoRouterWrapper {
  GoRouterWrapper({
    required SecureStorageService storage,
    required FirebaseAuth firebaseAuth,
  }) : router = buildRouter(storage: storage, firebaseAuth: firebaseAuth);

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
    required this.jobsCubit,
    required this.fileService,
    required super.child,
  });

  final SecureStorageService storage;
  final ArkMaskApiClient apiClient;
  final AuthService authService;

  /// Durable Hive CE job log. Prefer [jobsCubit] for reactive reads — this
  /// is exposed for the few call sites that need direct registry access
  /// (e.g. one-off `all` iteration).
  final JobRegistryService jobRegistryService;

  /// App-lifetime job state orchestrator — see [JobsCubit] doc comment.
  /// Also provided via [BlocProvider] in [ArkMaskApp.build] so
  /// `context.watch<JobsCubit>()` / `BlocSelector` work from any screen.
  final JobsCubit jobsCubit;

  /// Phase 2 compat — uninitialized in Phase 1. Remove in Phase 2.
  final ProjectFileService fileService;

  static ArkMaskServices of(BuildContext context) {
    final result = context
        .dependOnInheritedWidgetOfExactType<ArkMaskServices>();
    assert(
      result != null,
      'No ArkMaskServices found in context. '
      'Ensure ArkMaskApp is an ancestor.',
    );
    return result!;
  }

  @override
  bool updateShouldNotify(ArkMaskServices oldWidget) => false;
}
