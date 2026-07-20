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


def _count_story_scenes(raw: str) -> int:
    """
    Mirrors the Flutter app's FileBrowserCubit._countStoryScenes exactly —
    same heading pattern, same "highest number wins" logic (story scenes are
    always sequentially re-indexed 1..N on save, per StoryCubit._reindex).
    Returns 0 for empty content, 1 for content with no `# N` headings at all
    (an unheaded single scene), otherwise the highest heading number found.
    """
    if not raw.strip():
        return 0
    matches = re.findall(r"^# (\d+)\s*$", raw, flags=re.MULTILINE)
    if not matches:
        return 1
    return max(int(n) for n in matches)


def write_extracted_assets(
    db,
    firebase_uid: str,
    project_slug: str,
    raw_assets: list[dict],
    story: str = "",
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
        story: Full story text this extraction ran against. Used to backfill
            scene documents the model didn't emit any asset for at all (see
            below) — pass "" to skip that backfill (e.g. call sites that
            don't have the story text handy).

    Global assets (scene_number == 0) go to the project-level `assets`
    subcollection. Scene-local assets go under
    `scenes/{scene_number}/assets/{slug}`. Parent scene documents are
    created with merge semantics so existing scene data (storyboard,
    video path) is never overwritten.

    On a long story, the model is instructed to emit at least a reused-
    background reference for every scene (see
    backend/instructions/asset-list-generation.md's quality checklist), but
    in practice it sometimes skips that boilerplate entry for scattered
    scenes as the output grows — those scenes then never get a `scenes/{n}`
    document and silently disappear from the file browser, even though
    nothing was truncated. To make the tree robust to that omission
    regardless of cause, every scene number 1..N found in [story] (via the
    same `# N` heading parse the app itself uses) always gets its document
    created here, not just the scene numbers the model actually returned
    assets for.
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

    # Backfill every scene the story actually contains, not just the ones
    # the model returned assets for (see docstring above).
    scene_numbers.update(range(1, _count_story_scenes(story) + 1))

    # Ensure parent scene documents exist without overwriting existing content.
    for n in scene_numbers:
        scene_ref = db.document(f"{project_path}/scenes/{n}")
        batch.set(scene_ref, {"scene_number": n, "created_at": SERVER_TIMESTAMP}, merge=True)

    batch.commit()
