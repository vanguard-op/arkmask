import 'package:cloud_firestore/cloud_firestore.dart';

/// Recursive `ref`-chain resolution (FEAT-013/FEAT-036/FEAT-037 asset
/// reference model change — see docs/ArkMask/schema.md "Global Asset
/// Document" and its "Reference resolution (`ref` field)" note).
///
/// Mirrors `backend/app/services/asset_ref.py` exactly (same cycle
/// detection, same max-depth backstop of [kMaxRefDepth] hops) so the mobile
/// app's "not ready" / cycle-error UI state and the backend's video-prompt
/// resolution gate never disagree about what counts as a broken chain.

/// Backstop cap on `ref` hops — protects against a malformed or
/// race-written chain that doesn't strictly loop back on itself (so the
/// visited-path check alone wouldn't catch it) but is unreasonably deep.
const int kMaxRefDepth = 10;

/// Thrown when a `ref` chain revisits a path already visited, or exceeds
/// [kMaxRefDepth] hops without terminating. Both cases are surfaced to the
/// user identically: the "not ready" state with the exact inline error text
/// "Reference cycle detected — this asset's reference chain is broken."
class AssetRefCycleException implements Exception {
  AssetRefCycleException(this.chain);

  /// The sequence of asset_path values visited before the cycle/depth-cap
  /// was detected, for debugging — not shown to the user directly.
  final List<String> chain;

  @override
  String toString() =>
      'Reference cycle detected: ${chain.join(' -> ')}';
}

/// Result of following a `ref` chain to its terminal (non-referencing)
/// asset document.
class ResolvedAssetRef {
  const ResolvedAssetRef({required this.exists, this.path, this.data});

  /// False when the chain leads to a Firestore document that does not exist
  /// (a dangling reference, e.g. after a force-delete) — distinct from a
  /// cycle/depth error, since it isn't malformed, just incomplete.
  final bool exists;

  /// The terminal asset's own relative asset_path (e.g. `'assets/hero'`).
  /// Null when [exists] is false.
  final String? path;

  /// The terminal asset document's raw Firestore fields. Null when [exists]
  /// is false.
  final Map<String, dynamic>? data;
}

/// Recursively follows `ref` fields starting at [startAssetPath] (a relative
/// asset path, e.g. `"assets/hero"` or `"scenes/2/assets/hero"`) until
/// reaching a terminal asset (`ref` is null/empty) or a missing document.
///
/// Resolution is a pure graph walk over current Firestore state — NOT
/// dependent on scene number or creation order, matching
/// `app.services.asset_ref.resolve_asset_ref_chain` on the backend. Throws
/// [AssetRefCycleException] if a path is revisited or the chain exceeds
/// [kMaxRefDepth] hops.
Future<ResolvedAssetRef> resolveAssetRefChain({
  required String uid,
  required String projectSlug,
  required String startAssetPath,
}) async {
  final projectPath = 'users/$uid/projects/$projectSlug';
  final visited = <String>[];
  var current = startAssetPath;
  var hops = 0;

  while (true) {
    if (visited.contains(current)) {
      throw AssetRefCycleException([...visited, current]);
    }
    visited.add(current);
    if (hops > kMaxRefDepth) {
      throw AssetRefCycleException(visited);
    }

    final snap =
        await FirebaseFirestore.instance.doc('$projectPath/$current').get();
    if (!snap.exists) {
      return const ResolvedAssetRef(exists: false);
    }
    final data = snap.data()!;
    final ref = data['ref'] as String?;
    if (ref == null || ref.isEmpty) {
      return ResolvedAssetRef(exists: true, path: current, data: data);
    }
    current = ref;
    hops++;
  }
}
