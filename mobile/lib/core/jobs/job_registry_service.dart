import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// In-memory job registry for tracking generation jobs (image, video, merge).
///
/// This is the Phase 1 in-memory implementation. Phase 2 will replace the
/// backing store with a Hive CE box (box name: `job_registry`, key: `job_id`)
/// so that job state survives app restarts and background kills. The public
/// API surface of this class must remain stable across phases.
///
/// Jobs are keyed by [JobRegistryEntry.jobId]. Status transitions:
///   `pending` → `running` → `success` | `failed`
///
/// Widgets observe changes via [ListenableBuilder] on this service singleton.
class JobRegistryService extends ChangeNotifier {
  final _entries = <String, JobRegistryEntry>{};

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// All tracked job entries (including terminal ones not yet pruned).
  Iterable<JobRegistryEntry> get all => _entries.values;

  /// Returns the entry for [jobId], or null if not tracked.
  JobRegistryEntry? get(String jobId) => _entries[jobId];

  /// Returns all non-terminal jobs for the given [projectSlug].
  ///
  /// Used to show the "N generating" badge on a project card.
  Iterable<JobRegistryEntry> activeForProject(String projectSlug) =>
      _entries.values.where(
        (e) => e.projectId == projectSlug && e.isPending,
      );

  /// True when any job in [projectSlug] is currently pending or running.
  bool isProjectGenerating(String projectSlug) =>
      activeForProject(projectSlug).isNotEmpty;

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Inserts a new entry when a job is enqueued. Notifies listeners.
  void register(JobRegistryEntry entry) {
    _entries[entry.jobId] = entry;
    notifyListeners();
  }

  /// Updates an existing entry's status. No-op if [jobId] is not tracked.
  void updateStatus(String jobId, String status) {
    final existing = _entries[jobId];
    if (existing == null) return;
    _entries[jobId] = existing.copyWith(
      status: status,
      resolvedAt: (status == 'success' || status == 'failed') ? DateTime.now() : null,
    );
    notifyListeners();
  }

  /// Removes all entries for a project. Called after project deletion.
  void clearProject(String projectSlug) {
    final toRemove = _entries.keys
        .where((k) => _entries[k]?.projectId == projectSlug)
        .toList();
    for (final k in toRemove) {
      _entries.remove(k);
    }
    if (toRemove.isNotEmpty) notifyListeners();
  }

  /// Removes all entries. Called on user sign-out (AGENTS.md: clear job
  /// registry on sign-out).
  void clearAll() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// Prunes terminal entries older than 7 days. Called on app startup.
  ///
  /// Phase 1 no-op (in-memory — entries do not survive restarts). Phase 2
  /// (Hive CE) will iterate the persisted box and delete stale entries.
  void pruneStale() {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final toRemove = _entries.keys
        .where((k) {
          final e = _entries[k]!;
          return e.isTerminal && e.resolvedAt != null && e.resolvedAt!.isBefore(cutoff);
        })
        .toList();
    for (final k in toRemove) {
      _entries.remove(k);
    }
    if (toRemove.isNotEmpty) notifyListeners();
  }
}
