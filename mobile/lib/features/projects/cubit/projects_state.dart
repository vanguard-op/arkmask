import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';

@immutable
sealed class ProjectsState extends Equatable {
  const ProjectsState();
  @override
  List<Object?> get props => [];
}

final class ProjectsLoading extends ProjectsState {
  const ProjectsLoading();
}

final class ProjectsLoaded extends ProjectsState {
  const ProjectsLoaded({
    required this.projects,
    this.creditBalance,
    this.tier,
    this.deletingSlug,
    this.renameError,
    this.generatingCounts = const {},
    this.storageSummaries = const {},
  });

  /// Live project list from the Firestore `users/{uid}/projects` collection.
  final List<ProjectDocument> projects;

  final int? creditBalance;
  final UserTier? tier;

  /// The project slug currently being deleted (shows a loading indicator on
  /// that card). Set while [ProjectsCubit.deleteProject] is in flight; cleared
  /// once the Firestore listener confirms removal.
  final String? deletingSlug;

  /// Non-null when a rename operation failed; consumed once and cleared.
  final String? renameError;

  /// Maps project slug → count of active (pending/running) jobs in the Hive CE
  /// registry. Used to display "N generating" badges on project cards (FEAT-006).
  final Map<String, int> generatingCounts;

  /// Maps project slug → GCS storage summary (FEAT-027).
  ///
  /// Populated asynchronously after the project list loads — entries arrive
  /// one at a time as each per-project storage fetch completes. Cards show
  /// a placeholder ("—") until the summary arrives.
  final Map<String, ProjectStorageSummary> storageSummaries;

  ProjectsLoaded copyWith({
    List<ProjectDocument>? projects,
    int? creditBalance,
    UserTier? tier,
    String? deletingSlug,
    bool clearDeletingSlug = false,
    String? renameError,
    bool clearRenameError = false,
    Map<String, int>? generatingCounts,
    Map<String, ProjectStorageSummary>? storageSummaries,
  }) =>
      ProjectsLoaded(
        projects: projects ?? this.projects,
        creditBalance: creditBalance ?? this.creditBalance,
        tier: tier ?? this.tier,
        deletingSlug:
            clearDeletingSlug ? null : (deletingSlug ?? this.deletingSlug),
        renameError:
            clearRenameError ? null : (renameError ?? this.renameError),
        generatingCounts: generatingCounts ?? this.generatingCounts,
        storageSummaries: storageSummaries ?? this.storageSummaries,
      );

  @override
  List<Object?> get props =>
      [projects, creditBalance, tier, deletingSlug, renameError, generatingCounts, storageSummaries];
}

final class ProjectsError extends ProjectsState {
  const ProjectsError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
