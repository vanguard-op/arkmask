import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/jobs/jobs_cubit.dart';
import '../../../core/models/models.dart';
import 'projects_state.dart';

/// Cubit for the Home / Projects List Screen (FEAT-006).
///
/// Listens to the Firestore `users/{uid}/projects` collection in real-time so
/// the list updates automatically when a project is created or deleted — no
/// manual refresh needed.
///
/// Credit balance and tier are also live — see [_subscribeToProfile].
///
/// Also subscribes to [JobsCubit]'s stream so project card "N generating"
/// badges update in real time as jobs complete (FEAT-006) — including jobs
/// that resolve via FCM/poll while this screen is not the active one.
class ProjectsCubit extends Cubit<ProjectsState> {
  ProjectsCubit({
    required this.apiClient,
    required this.jobsCubit,
  }) : super(const ProjectsLoading());

  final ArkMaskApiClient apiClient;
  final JobsCubit jobsCubit;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _projectsSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  StreamSubscription<JobsState>? _jobsSub;

  // ── Credit balance / tier ────────────────────────────────────────────────
  //
  // Deliberately NOT derived from `state` (i.e. not "carried over from the
  // previous ProjectsLoaded"): _profileSub and _projectsSub are two
  // independent Firestore listeners started around the same time in load(),
  // and Firestore gives no ordering guarantee between them. A single-document
  // get (the profile doc) typically resolves before a collection query (the
  // projects list), so the profile listener's first snapshot often arrives
  // while `state` is still ProjectsLoading — at which point the
  // `if (s is ProjectsLoaded)` guard in _subscribeToProfile would silently
  // drop the update, and the credit pill would show "--" until some
  // unrelated future profile write happened to re-fire the listener while
  // state actually was ProjectsLoaded by then. Keeping these as cubit-lifetime
  // fields means whichever listener's first snapshot lands first, the other
  // one still picks up the correct value when it builds its own emission.
  int? _creditBalance;
  UserTier? _tier;

  /// Starts listening to the project list. Safe to call multiple times —
  /// cancels any existing subscription before starting a new one.
  ///
  /// Also subscribes to [jobsCubit] so the "N generating" badge on each
  /// project card updates in real time (FEAT-006), and to the user's
  /// Firestore profile document so the credit balance / tier pill is live.
  void load() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(const ProjectsError(message: 'Not signed in.'));
      return;
    }

    _jobsSub?.cancel();
    _jobsSub = jobsCubit.stream.listen((_) => _onJobsChanged());

    _subscribeToProfile(uid);

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
              // Read from the cubit-lifetime fields (not `current`) so a
              // profile snapshot that arrived before this collection's first
              // snapshot is never lost — see the field doc comment above.
              creditBalance: _creditBalance,
              tier: _tier,
              generatingCounts: _buildGeneratingCounts(),
              // Preserve existing summaries across list refreshes so cards
              // don't flicker back to "—" when Firestore emits a new snapshot.
              storageSummaries:
                  current is ProjectsLoaded ? current.storageSummaries : const {},
            ));

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
  /// from [jobsCubit].
  Map<String, int> _buildGeneratingCounts() {
    final counts = <String, int>{};
    for (final entry in jobsCubit.state.entries.values) {
      if (entry.isPending) {
        counts[entry.projectId] = (counts[entry.projectId] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Called whenever [jobsCubit] emits a new state. Propagates updated
  /// generating counts into the current state so card badges refresh live —
  /// this correctly decrements the moment a job resolves, regardless of
  /// whether resolution happened via FCM, poll, or a Firestore fast path.
  void _onJobsChanged() {
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

  /// Subscribes to the user's Firestore profile document
  /// (`users/{uid}/profile/data`) so [ProjectsLoaded.creditBalance] /
  /// [ProjectsLoaded.tier] stay live.
  ///
  /// Previously this was a one-shot `GET /me/credits` call, fired only when
  /// the project list happened to re-emit — which meant the credit pill
  /// never reflected a generation's credit deduction, and a Stripe
  /// subscription upgrade (written by the webhook straight to this same
  /// document) didn't show up even after an app restart landed on a
  /// *different* snapshot of the profile that happened to still be behind a
  /// stale REST cache. Every other piece of user data in this app is
  /// Firestore-realtime; credits/tier had been the one exception.
  void _subscribeToProfile(String uid) {
    _profileSub?.cancel();
    _profileSub = FirebaseFirestore.instance
        .doc('users/$uid/profile/data')
        .snapshots()
        .listen(
          (snap) {
            if (!snap.exists) return;
            final data = snap.data();
            if (data == null) return;
            _creditBalance = data['credit_balance'] as int?;
            final tierStr = data['tier'] as String?;
            _tier = tierStr != null ? UserTier.fromString(tierStr) : null;

            // If the project list snapshot hasn't arrived yet, there's
            // nothing to emit into yet — _creditBalance/_tier are still
            // picked up correctly once it does (see the field doc comment).
            final s = state;
            if (s is ProjectsLoaded) {
              emit(s.copyWith(creditBalance: _creditBalance, tier: _tier));
            }
          },
          onError: (_) {
            // Non-critical — the pill just shows "—" until the next
            // successful snapshot; project list functionality is unaffected.
          },
        );
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
    await _jobsSub?.cancel();
    await _profileSub?.cancel();
    await _projectsSub?.cancel();
    return super.close();
  }
}
