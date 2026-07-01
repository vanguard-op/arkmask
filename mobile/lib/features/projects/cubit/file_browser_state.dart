import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/project_tree.dart';

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
    required this.expandedIds,
    this.selectedId,
  });

  /// Firestore-backed project content tree.
  final ProjectTree tree;

  /// Set of node IDs that are currently expanded in the tree UI.
  ///
  /// Uses logical IDs rather than filesystem paths:
  /// - `'__assets__'` — global assets folder
  /// - `'__scenes__'` — scenes folder
  /// - `scene.id` — a specific scene folder (Firestore document ID)
  final Set<String> expandedIds;

  /// The currently highlighted node ID (Firestore document ID or logical key).
  final String? selectedId;

  FileBrowserLoaded copyWith({
    ProjectTree? tree,
    Set<String>? expandedIds,
    String? selectedId,
    bool clearSelectedId = false,
  }) =>
      FileBrowserLoaded(
        tree: tree ?? this.tree,
        expandedIds: expandedIds ?? this.expandedIds,
        selectedId: clearSelectedId ? null : (selectedId ?? this.selectedId),
      );

  @override
  List<Object?> get props => [tree, expandedIds, selectedId];
}

final class FileBrowserError extends FileBrowserState {
  const FileBrowserError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
