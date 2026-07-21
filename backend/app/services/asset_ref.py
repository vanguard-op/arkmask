"""Recursive `ref`-chain resolution for asset documents (FEAT-013/FEAT-036/
FEAT-037 asset-reference-model change — see docs/ArkMask/schema.md "Global
Asset Document" and its "Reference resolution (`ref` field)" note, and
docs/ArkMask/risk_log.md R-025/R-029).

Replaces the old `name` string convention ("@/scenes/N/<name>") for
expressing an asset reference. Every asset document now has:
  - `name` (str)          — display label only, never overloaded.
  - `ref` (str | None)    — 'assets/<slug>' or 'scenes/<N>/assets/<slug>',
                            or null for an independent (non-referencing) asset.

A referenced asset may itself have a non-null `ref` (chained references), so
resolution MUST be a graph walk — not a single hop and not dependent on scene
number/creation order (a scene N asset may legitimately reference a scene
N-p asset that itself references scene N-q, p > q, or even a later scene).
This module is the single implementation of that walk; both
`app.services.scene_assets` (video-prompt/video reference resolution) and
`app.services.asset_manage` (DELETE /assets transitive dependents check)
import it so the cycle-detection and depth-cap behavior can never drift
between the two call sites.
"""

from __future__ import annotations

from dataclasses import dataclass

# Backstop cap on `ref` hops — protects against a malformed or race-written
# chain that doesn't actually loop back on itself (so plain cycle detection
# via the visited-set wouldn't catch it) but is unreasonably deep. Any
# legitimate reference chain in this product is expected to be at most a
# handful of hops.
MAX_REF_DEPTH = 10


class ReferenceChainError(Exception):
    """Base class for a `ref` chain that cannot be resolved.

    Distinguishable from "just doesn't exist" (a plain missing document,
    which callers treat as an ordinary not-ready state) — this specifically
    means the chain itself is malformed. Surfaced in the mobile UI as the
    "not ready" state with the exact inline error text: "Reference cycle
    detected — this asset's reference chain is broken."
    """

    def __init__(self, start_path: str, chain: list[str]):
        self.start_path = start_path
        self.chain = chain
        super().__init__(
            f"Unresolvable reference chain starting at {start_path!r}: "
            f"{' -> '.join(chain)}"
        )


class CycleDetectedError(ReferenceChainError):
    """A `ref` chain revisited a path it had already visited."""


class MaxDepthExceededError(ReferenceChainError):
    """A `ref` chain exceeded MAX_REF_DEPTH hops without terminating.

    Treated as a backstop for cycles that the visited-set check somehow
    doesn't catch (e.g. a chain that spirals rather than looping exactly) —
    surfaced to the UI identically to CycleDetectedError.
    """


@dataclass(frozen=True)
class ResolvedAsset:
    """Result of following a `ref` chain to its terminal asset.

    `exists=False` means the chain led to a Firestore document that does not
    exist (a dangling reference, e.g. after a force-delete) — this is
    reported distinctly from a cycle/depth error since it is not malformed,
    just incomplete.
    """

    exists: bool
    asset_path: str | None = None
    data: dict | None = None
    hops: int = 0


def resolve_asset_ref_chain(db, project_path: str, start_asset_path: str) -> ResolvedAsset:
    """Follow `ref` fields from `start_asset_path` to the terminal asset.

    `start_asset_path` is itself resolved (i.e. call this with the *value* of
    a referencing document's `ref` field, not the referencing document's own
    path) — the referencing document's own `description`/pass-through-vs-
    variant status is a property of that document alone and must be decided
    by the caller before invoking this resolver, never by inspecting the
    terminal document reached here.

    The walk stops as soon as it reaches a document that is content-terminal:
    either `ref` is null (a true independent/global terminal), OR the
    document's own `description` is non-empty (a *variant* — per
    docs/ArkMask/schema.md, a variant keeps its `ref` set permanently as
    conditioning lineage for regeneration, but it has its own independently
    generated `gcs_image_path`/`prompt_body` and must never be walked past).
    Stopping only on `ref is None` (the pre-fix behavior) incorrectly walked
    straight through a variant to whatever *it* references, silently
    resolving to the wrong (older/earlier) asset's image/prompt instead of
    the variant's own — e.g. a scene referencing a variant would render with
    the variant's upstream global asset instead of the variant itself.

    Raises CycleDetectedError if `start_asset_path` (or any path reached
    while walking) is revisited, and MaxDepthExceededError if the walk
    exceeds MAX_REF_DEPTH hops without terminating — both are graph-walk
    safety nets, since `ref` chains are FEAT-036 user data, not backend-
    controlled, and could in principle be corrupted by a race or a manual
    Firestore edit.
    """
    visited: list[str] = []
    current = start_asset_path
    hops = 0

    while True:
        if current in visited:
            raise CycleDetectedError(start_asset_path, visited + [current])
        visited.append(current)
        if hops > MAX_REF_DEPTH:
            raise MaxDepthExceededError(start_asset_path, visited)

        doc = db.document(f"{project_path}/{current}").get()
        if not doc.exists:
            return ResolvedAsset(exists=False, hops=hops)

        data = doc.to_dict() or {}
        ref = data.get("ref")
        description = data.get("description") or ""
        if not ref or description != "":
            return ResolvedAsset(exists=True, asset_path=current, data=data, hops=hops)

        current = ref
        hops += 1


def ref_chain_paths(db, project_path: str, start_ref: str) -> list[str]:
    """Return the list of asset_paths visited while walking `ref` fields
    starting at `start_ref`, stopping at a terminal asset, a missing
    document, a repeated path (cycle), or MAX_REF_DEPTH hops.

    Unlike `resolve_asset_ref_chain`, this never raises — it is used purely
    for reachability checks (e.g. "does this candidate's chain pass through
    the asset being deleted?"), where a cycle or depth overrun just means
    "stop walking here", not an error to propagate.
    """
    paths: list[str] = []
    current = start_ref
    for _ in range(MAX_REF_DEPTH + 1):
        if current in paths:
            break  # cycle — stop without re-adding.
        paths.append(current)
        doc = db.document(f"{project_path}/{current}").get()
        if not doc.exists:
            break
        data = doc.to_dict() or {}
        nxt = data.get("ref")
        if not nxt:
            break
        current = nxt
    return paths
