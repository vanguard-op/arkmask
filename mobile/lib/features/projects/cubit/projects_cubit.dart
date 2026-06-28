import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/filesystem/project_file_service.dart';
import '../../../core/models/models.dart';
import 'projects_state.dart';

/// Cubit for the Home / Projects List Screen (FEAT-006).
///
/// Scans the on-device filesystem for project directories and fetches the
/// credit balance from the backend (fire-and-forget).
class ProjectsCubit extends Cubit<ProjectsState> {
  ProjectsCubit({
    required this.fileService,
    required this.apiClient,
  }) : super(const ProjectsLoading());

  final ProjectFileService fileService;
  final ArkMaskApiClient apiClient;

  /// Loads all projects from device storage and kicks off a credits fetch.
  Future<void> load() async {
    emit(const ProjectsLoading());
    try {
      final projects = await fileService.listProjects();
      emit(ProjectsLoaded(projects: projects));
      _fetchCredits(); // fire-and-forget
    } catch (e) {
      emit(ProjectsError(message: 'Failed to load projects: $e'));
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

  /// Deletes a project and removes it from the list.
  Future<void> deleteProject(String name) async {
    if (state is! ProjectsLoaded) return;
    final current = state as ProjectsLoaded;
    emit(current.copyWith(deletingName: name));

    try {
      await fileService.deleteProject(name);
      final updated = current.projects.where((p) => p.name != name).toList();
      emit(current.copyWith(projects: updated, clearDeletingName: true));
    } catch (e) {
      emit(current.copyWith(clearDeletingName: true));
    }
  }

  /// Renames a project and updates the list in place (FEAT-028).
  ///
  /// Shows a [SnackBar] on failure so the user knows the operation did not
  /// complete — the list is not modified when an error occurs.
  Future<void> renameProject(String oldName, String newName) async {
    if (state is! ProjectsLoaded) return;
    final current = state as ProjectsLoaded;

    try {
      final updated = await fileService.renameProject(oldName, newName);
      final updatedList = current.projects
          .map((p) => p.name == oldName ? updated : p)
          .toList();
      emit(current.copyWith(projects: updatedList));
    } catch (e) {
      // Re-emit the same state so the UI can surface the error via SnackBar.
      emit(current.copyWith(renameError: e.toString(), clearRenameError: false));
      // Immediately clear the error flag so it is consumed only once.
      emit((state as ProjectsLoaded).copyWith(clearRenameError: true));
    }
  }

  /// Refreshes the project list after a new project is created.
  Future<void> refresh() => load();
}
