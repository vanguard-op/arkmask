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
    this.deletingName,
  });

  final List<ProjectMeta> projects;
  final int? creditBalance;
  final UserTier? tier;

  /// The project name currently being deleted (shows loading on that card).
  final String? deletingName;

  ProjectsLoaded copyWith({
    List<ProjectMeta>? projects,
    int? creditBalance,
    UserTier? tier,
    String? deletingName,
    bool clearDeletingName = false,
  }) =>
      ProjectsLoaded(
        projects: projects ?? this.projects,
        creditBalance: creditBalance ?? this.creditBalance,
        tier: tier ?? this.tier,
        deletingName: clearDeletingName ? null : (deletingName ?? this.deletingName),
      );

  @override
  List<Object?> get props => [projects, creditBalance, tier, deletingName];
}

final class ProjectsError extends ProjectsState {
  const ProjectsError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
