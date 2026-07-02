"""Writes extracted asset documents to Firestore.

Ported from the Flutter app's ``StoryCubit._writeAssetDocuments`` (Dart) —
that logic used to run client-side after a synchronous `/assets` HTTP
response. Now that `/assets` is an async Cloud Tasks job (see
app.routers.generation.extract_assets and workers/app/tasks/assets.py), the
worker calls this function directly so the Firestore writes happen
server-side instead. The app's existing real-time listeners on the assets/
scenes subcollections pick up the new documents automatically — no client
changes needed beyond triggering the job and clearing a loading spinner.

Keep this logic in sync with the (now unused for this purpose) Dart
`_slugify`/`_writeAssetDocuments` if either ever changes independently.
"""

import re

from google.cloud.firestore_v1 import SERVER_TIMESTAMP


def _slugify(name: str) -> str:
    """
    Mirrors Dart's ``StoryCubit._slugify`` exactly:
    lowercase -> strip non [a-z0-9 -] -> trim -> collapse whitespace to '-'.
    """
    lowered = name.lower()
    stripped = re.sub(r"[^a-z0-9\s-]", "", lowered).strip()
    return re.sub(r"\s+", "-", stripped)


def write_extracted_assets(
    db,
    firebase_uid: str,
    project_slug: str,
    raw_assets: list[dict],
) -> None:
    """
    Batch-write extracted asset documents to Firestore.

    Args:
        db: Firestore client (from app.dependencies._firestore or
            app.firestore_client.get_firestore in workers).
        firebase_uid: Owning user's Firebase UID.
        project_slug: Immutable project slug.
        raw_assets: List of dicts matching the AssetItem schema —
            {name, type, scene_number, description} — as returned by
            AIProvider.generate_asset_list().

    Global assets (scene_number == 0) go to the project-level `assets`
    subcollection. Scene-local assets go under
    `scenes/{scene_number}/assets/{slug}`. Parent scene documents are
    created with merge semantics so existing scene data (storyboard,
    video path) is never overwritten.
    """
    project_path = f"users/{firebase_uid}/projects/{project_slug}"
    batch = db.batch()
    scene_numbers: set[int] = set()

    for asset in raw_assets:
        slug = _slugify(asset["name"])
        data = {
            "name": asset["name"],
            "type": asset["type"],
            "description": asset["description"],
            "prompt_body": None,
            "gcs_image_path": None,
            "created_at": SERVER_TIMESTAMP,
            "scene_number": asset["scene_number"],
        }

        if asset["scene_number"] == 0:
            ref = db.document(f"{project_path}/assets/{slug}")
        else:
            scene_numbers.add(asset["scene_number"])
            ref = db.document(
                f"{project_path}/scenes/{asset['scene_number']}/assets/{slug}"
            )
        batch.set(ref, data)

    # Ensure parent scene documents exist without overwriting existing content.
    for n in scene_numbers:
        scene_ref = db.document(f"{project_path}/scenes/{n}")
        batch.set(scene_ref, {"scene_number": n, "created_at": SERVER_TIMESTAMP}, merge=True)

    batch.commit()
