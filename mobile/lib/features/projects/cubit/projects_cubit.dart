import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/job_registry_service.dart';
import '../../../core/models/models.dart';
import 'projects_state.dart';

/// Cubit for the Home / Projects List Screen (FEAT-006).
///
/// Listens to the Firestore `users/{uid}/projects` collection in real-time so
/// the list updates automatically when a project is created or deleted — no
/// manual refresh needed.
///
/// Credits are fetched from the backend API once per load and on each
/// Firestore snapshot (fire-and-forget).
///
/// Also listens to [JobRegistryService] as a [ChangeNotifier] so project card
/// "N generating" badges update in real time as jobs complete (FEAT-006).
class ProjectsCubit extends Cubit<ProjectsState> {
  ProjectsCubit({
    required this.apiClient,
    required this.jobRegistryService,
  }) : super(const ProjectsLoading());

  final ArkMaskApiClient apiClient;
  final JobRegistryService jobRegistryService;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _projectsSub;

  /// Starts listening to the project list. Safe to call multiple times —
  /// cancels any existing subscription before starting a new one.
  ///
  /// Also registers a [JobRegistryService] listener so the "N generating"
  /// badge on each project card updates in real time (FEAT-006).
  void load() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(const ProjectsError(message: 'Not signed in.'));
      return;
    }

    // Attach the job-registry listener once. Removing first ensures we never
    // double-register if load() is called more than once.
    jobRegistryService.removeListener(_onJobRegistryChanged);
    jobRegistryService.addListener(_onJobRegistryChanged);

    _projectsSub?.cancel();
    emit(const ProjectsLoading());

    _projectsSub = FirebaseFirestore.instance
        .collection('users/$uid/projects')
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen(
          (snap) {
            final projects = snap.docs
                .map((doc) => ProjectDocument.fromFirestore(doc.id, doc.data()))
                .toList();

            final current = state;
            emit(ProjectsLoaded(
              projects: projects,
              // Preserve credit balance and tier across Firestore updates.
              creditBalance:
                  current is ProjectsLoaded ? current.creditBalance : null,
              tier: current is ProjectsLoaded ? current.tier : null,
              generatingCounts: _buildGeneratingCounts(),
              // Preserve existing summaries across list refreshes so cards
              // don't flicker back to "—" when Firestore emits a new snapshot.
              storageSummaries:
                  current is ProjectsLoaded ? current.storageSummaries : const {},
            ));

            _fetchCredits();
            // Fire-and-forget: fetch storage summaries for projects that don't
            // yet have one. Each fetch runs independently so a single failure
            // does not block the others. The cubit emits a state update as each
            // summary arrives, triggering a card rebuild.
            _fetchStorageSummaries(projects);
          },
          onError: (Object e) =>
              emit(ProjectsError(message: 'Failed to load projects: $e')),
        );
  }

  /// Builds a map of project slug → count of active (pending/running) jobs
  /// from the Hive CE registry.
  Map<String, int> _buildGeneratingCounts() {
    final counts = <String, int>{};
    for (final entry in jobRegistryService.all) {
      if (entry.isPending) {
        counts[entry.projectId] = (counts[entry.projectId] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Called whenever the job registry notifies of a change. Propagates updated
  /// generating counts into the current state so card badges refresh live.
  void _onJobRegistryChanged() {
    final s = state;
    if (s is ProjectsLoaded) {
      emit(s.copyWith(generatingCounts: _buildGeneratingCounts()));
    }
  }

  /// Queues a storage fetch for each project not yet in [ProjectsLoaded.storageSummaries].
  ///
  /// Intentionally fire-and-forget — never awaited in the Firestore snapshot
  /// handler. Each [_fetchOneStorageSummary] call runs concurrently and updates
  /// state independently as results arrive.
  void _fetchStorageSummaries(List<ProjectDocument> projects) {
    for (final project in projects) {
      // Skip if we already have a summary for this slug — avoids redundant
      // network calls on every Firestore snapshot.
      final s = state;
      if (s is ProjectsLoaded && s.storageSummaries.containsKey(project.slug)) {
        continue;
      }
      _fetchOneStorageSummary(project.slug);
    }
  }

  Future<void> _fetchOneStorageSummary(String slug) async {
    try {
      final data = await apiClient.getProjectStorageSummary(slug);
      final summary = ProjectStorageSummary.fromJson(slug, data);
      if (!isClosed && state is ProjectsLoaded) {
        final current = state as ProjectsLoaded;
        final updated = Map<String, ProjectStorageSummary>.from(
            current.storageSummaries)..[slug] = summary;
        emit(current.copyWith(storageSummaries: updated));
      }
    } catch (_) {
      // Storage summary is non-critical — fail silently. The card shows "—".
    }
  }

  Future<void> _fetchCredits() async {
    try {
      final data = await apiClient.getCredits();
      final credits = data['credits'] as int?;
      final tierStr = data['tier'] as String?;
      final tier = tierStr != null ? UserTier.fromString(tierStr) : null;
      if (state is ProjectsLoaded) {
        emit((state as ProjectsLoaded).copyWith(
          creditBalance: credits,
          tier: tier,
        ));
      }
    } catch (_) {
      // Credits are non-critical — fail silently.
    }
  }

  /// Deletes a project via the backend API. The Firestore real-time listener
  /// will automatically remove it from the project list on success.
  ///
  /// Shows a loading indicator on the card while in flight.
  Future<void> deleteProject(String slug) async {
    if (state is! ProjectsLoaded) return;
    final current = state as ProjectsLoaded;
    emit(current.copyWith(deletingSlug: slug));

    try {
      await apiClient.deleteProject(slug);
      // The Firestore listener removes the document from the list automatically.
      // Clear the loading indicator in case the listener is slow to fire.
      if (state is ProjectsLoaded) {
        emit((state as ProjectsLoaded).copyWith(clearDeletingSlug: true));
      }
    } catch (e) {
      if (state is ProjectsLoaded) {
        emit((state as ProjectsLoaded).copyWith(clearDeletingSlug: true));
      }
    }
  }

  /// Updates the display name of a project.
  ///
  /// Writes `display_name` and `updated_at` directly to the Firestore project
  /// root document. The slug is immutable and is not changed. The Firestore
  /// listener will push the updated name to the list automatically.
  Future<void> renameProject(String slug, String newDisplayName) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance
          .doc('users/$uid/projects/$slug')
          .update({
        'display_name': newDisplayName,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (state is ProjectsLoaded) {
        final current = state as ProjectsLoaded;
        emit(current.copyWith(renameError: e.toString()));
        // Immediately clear the error flag so it is consumed only once.
        emit((state as ProjectsLoaded).copyWith(clearRenameError: true));
      }
    }
  }

  /// No-op: the Firestore real-time listener keeps the list up to date
  /// automatically. Kept for call-site compatibility with screens that call
  /// `refresh()` after project creation.
  Future<void> refresh() async {}

  @override
  Future<void> close() async {
    jobRegistryService.removeListener(_onJobRegistryChanged);
    await _projectsSub?.cancel();
    return super.close();
  }
}
