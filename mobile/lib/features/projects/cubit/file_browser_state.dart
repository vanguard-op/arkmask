import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../../../core/filesystem/project_file_service.dart';

@immutable
sealed class FileBrowserState extends Equatable {
  const FileBrowserState();
  @override
  List<Object?> get props => [];
}

final class FileBrowserLoading extends FileBrowserState {
  const FileBrowserLoading();
}

final class FileBrowserLoaded extends FileBrowserState {
  const FileBrowserLoaded({
    required this.tree,
    required this.expandedPaths,
    this.selectedPath,
  });

  final ProjectTree tree;

  /// Set of directory paths that are currently expanded in the tree UI.
  final Set<String> expandedPaths;

  /// The currently active / highlighted node path.
  final String? selectedPath;

  FileBrowserLoaded copyWith({
    ProjectTree? tree,
    Set<String>? expandedPaths,
    String? selectedPath,
    bool clearSelectedPath = false,
  }) =>
      FileBrowserLoaded(
        tree: tree ?? this.tree,
        expandedPaths: expandedPaths ?? this.expandedPaths,
        selectedPath: clearSelectedPath ? null : (selectedPath ?? this.selectedPath),
      );

  @override
  List<Object?> get props => [tree, expandedPaths, selectedPath];
}

final class FileBrowserError extends FileBrowserState {
  const FileBrowserError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
