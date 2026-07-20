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
    this.isExtracting = false,
    this.extractError,
    this.hasExistingAssets = false,
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

  /// True while the `/assets` API call and Firestore writes are running
  /// (FEAT-009 — extraction now lives only in this cubit, the sole entry
  /// point being this screen's FAB as of FEAT-038).
  final bool isExtracting;

  /// Non-null when the last asset extraction attempt failed.
  final String? extractError;

  /// True when Firestore already has asset documents for this project — the
  /// screen shows a confirmation dialog before re-extracting.
  final bool hasExistingAssets;

  FileBrowserLoaded copyWith({
    ProjectTree? tree,
    Set<String>? expandedIds,
    String? selectedId,
    bool clearSelectedId = false,
    bool? isExtracting,
    String? extractError,
    bool clearExtractError = false,
    bool? hasExistingAssets,
  }) =>
      FileBrowserLoaded(
        tree: tree ?? this.tree,
        expandedIds: expandedIds ?? this.expandedIds,
        selectedId: clearSelectedId ? null : (selectedId ?? this.selectedId),
        isExtracting: isExtracting ?? this.isExtracting,
        extractError: clearExtractError ? null : (extractError ?? this.extractError),
        hasExistingAssets: hasExistingAssets ?? this.hasExistingAssets,
      );

  @override
  List<Object?> get props =>
      [tree, expandedIds, selectedId, isExtracting, extractError, hasExistingAssets];
}

final class FileBrowserError extends FileBrowserState {
  const FileBrowserError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
