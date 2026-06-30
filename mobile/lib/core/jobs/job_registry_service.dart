import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/models.dart';

/// Persistent job registry backed by a Hive CE box named `job_registry`.
///
/// Each generation job (image, video, merge) writes an entry here on enqueue
/// so job state survives app restarts. On foreground return the app polls
/// `GET /job/{id}/status` for any entry still marked `pending` or `running`.
///
/// The box is keyed by [JobRegistryEntry.jobId].
///
/// **Lifecycle:** call [init] once at app startup (before [MaterialApp] builds)
/// then inject this service via [ArkMaskServices]. Call [clearAll] on sign-out.
class JobRegistryService extends ChangeNotifier {
  static const _boxName = 'job_registry';

  /// The open Hive CE box. Null until [init] has completed.
  Box<Map>? _box;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Opens the Hive CE box. Must be awaited before any read/write calls.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops if the box is
  /// already open.
  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    await Hive.initFlutter();
    _box = await Hive.openBox<Map>(_boxName);
  }

  // ── Accessors ──────────────────────────────────────────────────────────────

  /// All entries currently in the registry.
  Iterable<JobRegistryEntry> get all => _entriesFromBox();

  /// Returns the entry for [jobId], or null if not found.
  JobRegistryEntry? get(String jobId) {
    final raw = _box?.get(jobId);
    if (raw == null) return null;
    return _entryFromMap(Map<String, dynamic>.from(raw));
  }

  /// All jobs for [projectSlug] that are still pending or running.
  Iterable<JobRegistryEntry> activeForProject(String projectSlug) =>
      all.where((e) => e.projectId == projectSlug && e.isPending);

  /// True when any job for [projectSlug] is currently pending or running.
  bool isProjectGenerating(String projectSlug) =>
      activeForProject(projectSlug).isNotEmpty;

  /// All jobs that are still pending or running (for recovery polling on
  /// foreground return — FEAT-017).
  Iterable<JobRegistryEntry> get pendingJobs => all.where((e) => e.isPending);

  // ── Mutations ──────────────────────────────────────────────────────────────

  /// Writes a new entry to the Hive CE box.
  Future<void> register(JobRegistryEntry entry) async {
    await _box?.put(entry.jobId, _entryToMap(entry));
    notifyListeners();
  }

  /// Updates the [status] (and optionally [resolvedAt]) of an existing entry.
  ///
  /// No-op if the entry does not exist in the box.
  Future<void> updateStatus(
    String jobId,
    String status, {
    DateTime? resolvedAt,
  }) async {
    final existing = get(jobId);
    if (existing == null) return;
    final isTerminal = status == 'success' || status == 'failed';
    final updated = existing.copyWith(
      status: status,
      resolvedAt: resolvedAt ?? (isTerminal ? DateTime.now() : null),
    );
    await _box?.put(jobId, _entryToMap(updated));
    notifyListeners();
  }

  /// Removes all entries for [projectSlug] from the registry.
  ///
  /// Called when a project is deleted (FEAT-007) so orphaned entries do not
  /// accumulate in the box.
  Future<void> clearProject(String projectSlug) async {
    final toRemove = all
        .where((e) => e.projectId == projectSlug)
        .map((e) => e.jobId)
        .toList();
    await _box?.deleteAll(toRemove);
    if (toRemove.isNotEmpty) notifyListeners();
  }

  /// Clears the entire registry. Called on sign-out (FEAT-023).
  ///
  /// In-flight cloud jobs continue running and their results are delivered via
  /// Firestore listeners and FCM on the next login.
  Future<void> clearAll() async {
    await _box?.clear();
    notifyListeners();
  }

  /// Removes entries with a [resolvedAt] timestamp older than [maxAge].
  ///
  /// Prevents the box from growing unboundedly over time. Call once per
  /// session (e.g. on foreground return in [AppLifecycleState.resumed]).
  Future<void> pruneStale({Duration maxAge = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final toRemove = all
        .where((e) =>
            e.isTerminal &&
            e.resolvedAt != null &&
            e.resolvedAt!.isBefore(cutoff))
        .map((e) => e.jobId)
        .toList();
    await _box?.deleteAll(toRemove);
    if (toRemove.isNotEmpty) notifyListeners();
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Converts a [JobRegistryEntry] to a plain map for Hive CE storage.
  static Map<String, dynamic> _entryToMap(JobRegistryEntry e) => {
        'job_id': e.jobId,
        'type': e.type,
        'project_id': e.projectId,
        'status': e.status,
        'created_at': e.createdAt.millisecondsSinceEpoch,
        if (e.sceneIndex != null) 'scene_index': e.sceneIndex,
        if (e.assetName != null) 'asset_name': e.assetName,
        if (e.resolvedAt != null)
          'resolved_at': e.resolvedAt!.millisecondsSinceEpoch,
      };

  static JobRegistryEntry _entryFromMap(Map<String, dynamic> m) =>
      JobRegistryEntry(
        jobId: m['job_id'] as String,
        type: m['type'] as String,
        projectId: m['project_id'] as String,
        status: m['status'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        sceneIndex: m['scene_index'] as int?,
        assetName: m['asset_name'] as String?,
        resolvedAt: m['resolved_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['resolved_at'] as int)
            : null,
      );

  Iterable<JobRegistryEntry> _entriesFromBox() {
    final box = _box;
    if (box == null) return const [];
    return box.values
        .map((raw) => _entryFromMap(Map<String, dynamic>.from(raw)));
  }
}
