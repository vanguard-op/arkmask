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

  ProjectsLoaded copyWith({
    List<ProjectDocument>? projects,
    int? creditBalance,
    UserTier? tier,
    String? deletingSlug,
    bool clearDeletingSlug = false,
    String? renameError,
    bool clearRenameError = false,
  }) =>
      ProjectsLoaded(
        projects: projects ?? this.projects,
        creditBalance: creditBalance ?? this.creditBalance,
        tier: tier ?? this.tier,
        deletingSlug:
            clearDeletingSlug ? null : (deletingSlug ?? this.deletingSlug),
        renameError:
            clearRenameError ? null : (renameError ?? this.renameError),
      );

  @override
  List<Object?> get props =>
      [projects, creditBalance, tier, deletingSlug, renameError];
}

final class ProjectsError extends ProjectsState {
  const ProjectsError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
