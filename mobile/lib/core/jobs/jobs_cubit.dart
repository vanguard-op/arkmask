import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../api/ark_mask_api_client.dart';
import '../models/models.dart';
import 'job_registry_service.dart';

/// Immutable snapshot of every tracked job, keyed by [JobRegistryEntry.jobId].
///
/// Equatable's deep-collection comparison means [JobsCubit] only emits (and
/// therefore only triggers widget rebuilds) when the underlying map actually
/// changes — not on every unrelated registry write.
class JobsState extends Equatable {
  const JobsState(this.entries);

  final Map<String, JobRegistryEntry> entries;

  static const empty = JobsState({});

  @override
  List<Object?> get props => [entries];
}

/// The Flutter app's "Pipeline Orchestrator" (docs/ArkMask/architecture.md,
/// Component: Flutter App) — the single, app-lifetime owner of live
/// generation-job state, exposed as a [Stream] via [Cubit].
///
/// This replaces the previous design where each screen's Cubit
/// (AssetEditorCubit, SceneCubit, StoryCubit, EditorCubit) tracked its own
/// "isGenerating" flag and cleared it from its *own* Firestore listener.
/// That design silently broke as soon as the user navigated away before a
/// job finished: the listener (and the Cubit that owned it) was disposed,
/// so the job never resolved, the registry entry stayed `pending` forever,
/// and returning to the screen created a fresh Cubit with no memory of the
/// in-flight job.
///
/// [JobsCubit] is created once in `app.dart` and lives for the app's entire
/// lifetime — independent of navigation — so job state is never lost when
/// the user leaves and returns to a screen. Three independent mechanisms
/// keep it in sync, matching architecture.md's documented design:
///
///  1. **FCM push** ([FcmService]) — the primary completion signal. Fires
///     regardless of which screen (if any) is currently mounted.
///  2. **Foreground-return / launch polling** ([pollPendingJobs]) — the
///     documented fallback for missed FCM delivery (offline device, stale
///     token, backgrounded app killed by the OS).
///  3. **Firestore content listeners** already owned by feature Cubits —
///     kept as a fast, low-latency path while the enqueuing screen happens
///     to still be open. They now call [resolve] instead of writing to the
///     registry directly, so this Cubit remains the single point of truth.
///
/// [JobRegistryService] remains the durable Hive CE persistence layer
/// underneath — this Cubit is a reactive adapter on top of it.
class JobsCubit extends Cubit<JobsState> {
  JobsCubit({
    required this.jobRegistryService,
    required this.apiClient,
  }) : super(JobsState(_snapshot(jobRegistryService))) {
    jobRegistryService.addListener(_onRegistryChanged);
  }

  final JobRegistryService jobRegistryService;
  final ArkMaskApiClient apiClient;

  /// Guards against overlapping poll cycles (e.g. rapid resume/pause/resume).
  bool _isPolling = false;

  void _onRegistryChanged() {
    if (isClosed) return;
    emit(JobsState(_snapshot(jobRegistryService)));
  }

  static Map<String, JobRegistryEntry> _snapshot(JobRegistryService svc) => {
        for (final e in svc.all) e.jobId: e,
      };

  // ── Writes ───────────────────────────────────────────────────────────────

  /// Registers a newly-enqueued job. Delegates to [JobRegistryService]; its
  /// change notification re-derives [state] via [_onRegistryChanged].
  Future<void> enqueue(JobRegistryEntry entry) =>
      jobRegistryService.register(entry);

  /// Marks [jobId] resolved (`'success'` or `'failed'`).
  ///
  /// Safe to call redundantly from multiple resolution paths — a no-op if
  /// the job is unknown or already terminal, so FCM, polling, and Firestore
  /// listeners can race harmlessly and whichever arrives first wins.
  Future<void> resolve(String jobId, String status) async {
    final existing = jobRegistryService.get(jobId);
    if (existing == null || existing.isTerminal) return;
    await jobRegistryService.updateStatus(
      jobId,
      status,
      resolvedAt: DateTime.now(),
    );
  }

  // ── Reads ────────────────────────────────────────────────────────────────

  /// Returns the most recent pending/running job matching the given routing
  /// context (mirrors the FCM payload's routing fields — see
  /// architecture.md "FCM Data Payload"), or `null` if none is active.
  ///
  /// Screens call this when their Cubit is (re)created — e.g. after
  /// navigating back to a screen mid-generation — to correctly initialize
  /// their "generating" flag instead of assuming idle.
  JobRegistryEntry? activeJob({
    required String type,
    required String projectId,
    int? sceneIndex,
    String? assetName,
  }) {
    JobRegistryEntry? latest;
    for (final e in state.entries.values) {
      if (!e.isPending) continue;
      if (e.type != type || e.projectId != projectId) continue;
      if (e.sceneIndex != sceneIndex || e.assetName != assetName) continue;
      if (latest == null || e.createdAt.isAfter(latest.createdAt)) {
        latest = e;
      }
    }
    return latest;
  }

  /// True when any job for [projectId] is still pending/running.
  bool isProjectGenerating(String projectId) => state.entries.values
      .any((e) => e.isPending && e.projectId == projectId);

  /// Count of pending/running jobs for [projectId] — drives the "N
  /// generating" badge on the project list (FEAT-006).
  int generatingCount(String projectId) => state.entries.values
      .where((e) => e.isPending && e.projectId == projectId)
      .length;

  // ── Recovery polling (architecture.md "Platform Notes") ────────────────────

  /// Polls `GET /job/{id}/status` for every still-pending registry entry.
  ///
  /// Called on app launch and on every foreground return
  /// (`AppLifecycleState.resumed`) as the documented fallback for missed FCM
  /// delivery. This is what guarantees a job's state is eventually correct
  /// even if the push notification never arrives.
  Future<void> pollPendingJobs() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      final pending = jobRegistryService.pendingJobs.toList();
      if (pending.isEmpty) return;
      await Future.wait(pending.map(_pollOne));
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _pollOne(JobRegistryEntry entry) async {
    try {
      final data = await apiClient.getJobStatus(jobId: entry.jobId);
      final status = data['status'] as String?;
      if (status == 'success' || status == 'failed') {
        await resolve(entry.jobId, status!);
      }
    } catch (_) {
      // Non-fatal — stays pending, retried on the next poll cycle or
      // resolved by a later FCM push.
    }
  }

  @override
  Future<void> close() {
    jobRegistryService.removeListener(_onRegistryChanged);
    return super.close();
  }
}
