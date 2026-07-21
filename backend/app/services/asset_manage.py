"""Backend logic for manual asset management (FEAT-033–FEAT-037).

Manually created asset documents (source in manual_image, manual_text,
manual_reference) are written directly to Firestore by the Flutter app — the
same client-write pattern already used for editing type/description on
existing assets (FEAT-010). See docs/ArkMask/schema.md "Manual asset
creation" note. The only server-side piece needed for the create paths is
already covered by the existing /media/upload-url, /image-describe,
/image-prompt, and /image endpoints (see app.routers.generation).

This module covers what the client genuinely cannot do itself: deleting an
asset (FEAT-037), which requires GCS delete credentials the client does not
have, and — before deleting — scanning the project for other assets whose
`ref` field chain resolves through the one being deleted (FEAT-013), so a
delete never silently creates a dangling reference (docs/ArkMask/
risk_log.md R-025) unless the caller explicitly forces it. The dependents
scan is transitive: an asset that references another asset that in turn
references the one being deleted is still a dependent, not just direct
referencers (docs/ArkMask/risk_log.md R-029).
"""

import re
from dataclasses import dataclass

from app.services.asset_ref import ref_chain_paths


@dataclass
class Dependent:
    """A single asset document whose `ref` chain resolves through the asset
    being deleted, directly or transitively."""
    asset_path: str
    name: str
    ref: str


def parse_asset_path(asset_path: str) -> tuple[int, str]:
    """
    Parse a relative asset path into (scope, slug).

    Examples:
        'assets/palace'            -> (0, 'palace')
        'scenes/2/assets/shade'    -> (2, 'shade')

    Scope 0 means a global asset. Raises ValueError for any path that
    doesn't match one of the two expected shapes.
    """
    global_match = re.fullmatch(r"assets/([^/]+)", asset_path)
    if global_match:
        return 0, global_match.group(1)

    scene_match = re.fullmatch(r"scenes/(\d+)/assets/([^/]+)", asset_path)
    if scene_match:
        return int(scene_match.group(1)), scene_match.group(2)

    raise ValueError(f"Unrecognised asset_path shape: {asset_path!r}")


def build_asset_path(scope: int, slug: str) -> str:
    """Inverse of `parse_asset_path`: (scope, slug) -> relative asset_path."""
    return f"assets/{slug}" if scope == 0 else f"scenes/{scope}/assets/{slug}"


def find_dependent_assets(db, firebase_uid: str, project_slug: str, asset_path: str) -> list[Dependent]:
    """
    Scan every asset document in the project (global + every scene) for a
    `ref` chain that resolves through `asset_path`, directly or transitively.

    Used by DELETE /assets to block a delete that would otherwise leave a
    pass-through/variant reference pointing at a missing document (FEAT-037,
    risk_log.md R-025/R-029).
    """
    project_path = f"users/{firebase_uid}/projects/{project_slug}"
    dependents: list[Dependent] = []

    def _check(doc, dependent_path: str) -> None:
        data = doc.to_dict() or {}
        ref = data.get("ref")
        if not ref:
            return
        # Walk the candidate's own ref chain (not raising on cycles — a
        # candidate with a malformed chain of its own just isn't found to be
        # a dependent of THIS asset unless the target appears before the
        # cycle/depth cutoff).
        chain = ref_chain_paths(db, project_path, ref)
        if asset_path in chain:
            dependents.append(
                Dependent(asset_path=dependent_path, name=data.get("name", ""), ref=ref)
            )

    # Global assets/ subcollection.
    for doc in db.collection(f"{project_path}/assets").stream():
        _check(doc, f"assets/{doc.id}")

    # Every scene's local assets/ subcollection.
    for scene_doc in db.collection(f"{project_path}/scenes").stream():
        scene_n = scene_doc.id
        for doc in db.collection(f"{project_path}/scenes/{scene_n}/assets").stream():
            _check(doc, f"scenes/{scene_n}/assets/{doc.id}")

    return dependents


def delete_asset(db, media_store, firebase_uid: str, project_slug: str, asset_path: str) -> None:
    """
    Hard-delete the Firestore asset document and all GCS objects under its
    asset path (image.png, original.<ext> if present).

    Callers are responsible for the dependents check (find_dependent_assets)
    — this function performs the deletion unconditionally, matching the
    `force` semantics documented in docs/ArkMask/schema.md DELETE /assets.
    """
    fs_path = f"users/{firebase_uid}/projects/{project_slug}/{asset_path}"
    db.document(fs_path).delete()
    media_store.delete_prefix(f"{firebase_uid}/{project_slug}/{asset_path}/")
