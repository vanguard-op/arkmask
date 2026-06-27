import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/filesystem/project_file_service.dart';
import 'file_browser_state.dart';

/// Cubit for the Project File Browser Screen (FEAT-005).
///
/// Manages the file tree data, expand/collapse state per path, and the
/// currently selected node.
class FileBrowserCubit extends Cubit<FileBrowserState> {
  FileBrowserCubit({required this.fileService}) : super(const FileBrowserLoading());

  final ProjectFileService fileService;

  /// Loads the project file tree from device storage.
  Future<void> load(String projectName) async {
    emit(const FileBrowserLoading());
    try {
      final tree = await fileService.readProjectTree(projectName);
      emit(FileBrowserLoaded(
        tree: tree,
        expandedPaths: const {},
      ));
    } catch (e) {
      emit(FileBrowserError(message: 'Failed to read project: $e'));
    }
  }

  /// Toggles expand/collapse for a folder node identified by its path.
  void toggleExpand(String path) {
    if (state is! FileBrowserLoaded) return;
    final s = state as FileBrowserLoaded;
    final updated = Set<String>.from(s.expandedPaths);
    if (updated.contains(path)) {
      updated.remove(path);
    } else {
      updated.add(path);
    }
    emit(s.copyWith(expandedPaths: updated));
  }

  /// Marks a node as selected (highlighted in the file browser).
  void select(String path) {
    if (state is! FileBrowserLoaded) return;
    emit((state as FileBrowserLoaded).copyWith(selectedPath: path));
  }

  /// Re-reads the project tree — called after returning from an editor screen.
  Future<void> refresh(String projectName) async {
    if (state is! FileBrowserLoaded) return;
    try {
      final tree = await fileService.readProjectTree(projectName);
      final s = state as FileBrowserLoaded;
      emit(s.copyWith(tree: tree));
    } catch (_) {
      // Refresh failure is non-critical — keep existing tree.
    }
  }
}
