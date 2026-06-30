import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
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
class ProjectsCubit extends Cubit<ProjectsState> {
  ProjectsCubit({required this.apiClient}) : super(const ProjectsLoading());

  final ArkMaskApiClient apiClient;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _projectsSub;

  /// Starts listening to the project list. Safe to call multiple times —
  /// cancels any existing subscription before starting a new one.
  void load() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      emit(const ProjectsError(message: 'Not signed in.'));
      return;
    }

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
            ));

            _fetchCredits();
          },
          onError: (Object e) =>
              emit(ProjectsError(message: 'Failed to load projects: $e')),
        );
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
    await _projectsSub?.cancel();
    return super.close();
  }
}
