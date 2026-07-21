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


def _extract_ai_ref(asset: dict) -> tuple[int, str] | None:
    """Reads the AI extraction contract's `ref` field off a raw asset dict.

    Per `backend/instructions/asset-list-generation.md`, the model now emits
    a structured `ref: {"scene_number": N, "name": "<source_name>"} | null`
    field directly alongside a `name` that is always a plain display label —
    no more `"@/scenes/N/base"` string encoding to parse out of `name`. This
    keeps the model-output contract and the Firestore schema's own `name`/
    `ref` split (docs/ArkMask/schema.md "Global Asset Document") in lockstep,
    so this function is now a straight, validated read instead of a regex
    parse.

    Returns `None` if `ref` is null/absent — i.e. this is a brand-new,
    independent asset.
    """
    ref = asset.get("ref")
    if not ref:
        return None
    scene_number = ref.get("scene_number")
    ref_name = ref.get("name")
    if scene_number is None or not ref_name:
        return None
    try:
        return int(scene_number), ref_name
    except (TypeError, ValueError):
        return None


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
            {name, ref, type, scene_number, description}, where `ref` is
            `{"scene_number": int, "name": str} | None` — as returned by
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

    # ── Build a (scope, lower(display_name)) -> slug lookup ────────────────
    #
    # A `ref` in this batch (e.g. {"scene_number": 0, "name": "elias"}) names
    # its source by display name, not slug — and that source may be (a) an
    # asset already persisted from a previous extraction run, or (b) a
    # sibling asset being written in this very batch. Both must resolve to
    # the same slug the source asset actually gets, so the `ref` path we
    # write is a valid asset_path.
    name_to_slug: dict[tuple[int, str], str] = {}
    involved_scopes = {0} | {
        (_extract_ai_ref(a) or (a["scene_number"],))[0]
        for a in raw_assets
    } | {a["scene_number"] for a in raw_assets}
    for scope in involved_scopes:
        coll_path = (
            f"{project_path}/assets"
            if scope == 0
            else f"{project_path}/scenes/{scope}/assets"
        )
        for doc in db.collection(coll_path).stream():
            existing = doc.to_dict() or {}
            existing_name = existing.get("name") or doc.id
            name_to_slug[(scope, existing_name.lower())] = doc.id

    # Register this batch's own (as-yet-unwritten) display names too, so a
    # reference to a sibling extracted in the SAME call resolves even though
    # that sibling isn't in Firestore yet.
    for asset in raw_assets:
        name_to_slug[(asset["scene_number"], asset["name"].lower())] = _slugify(asset["name"])

    for asset in raw_assets:
        ai_ref = _extract_ai_ref(asset)
        display_name = asset["name"]
        slug = _slugify(display_name)

        ref_path: str | None = None
        if ai_ref is not None:
            ref_scope, ref_base_name = ai_ref
            ref_slug = name_to_slug.get(
                (ref_scope, ref_base_name.lower()), _slugify(ref_base_name)
            )
            ref_path = (
                f"assets/{ref_slug}"
                if ref_scope == 0
                else f"scenes/{ref_scope}/assets/{ref_slug}"
            )

        data = {
            # `name` is now display-label-only, always taken as-is from the
            # model's own `name` field (schema.md) — the reference
            # relationship, if any, lives entirely in `ref` below.
            "name": display_name,
            "ref": ref_path,
            "type": asset["type"],
            "description": asset["description"],
            "prompt_body": None,
            "gcs_image_path": None,
            "created_at": SERVER_TIMESTAMP,
            "scene_number": asset["scene_number"],
        }

        if asset["scene_number"] == 0:
            doc_ref = db.document(f"{project_path}/assets/{slug}")
        else:
            scene_numbers.add(asset["scene_number"])
            doc_ref = db.document(
                f"{project_path}/scenes/{asset['scene_number']}/assets/{slug}"
            )
        batch.set(doc_ref, data)

    # Backfill every scene the story actually contains, not just the ones
    # the model returned assets for (see docstring above).
    scene_numbers.update(range(1, _count_story_scenes(story) + 1))

    # Ensure parent scene documents exist without overwriting existing content.
    for n in scene_numbers:
        scene_ref = db.document(f"{project_path}/scenes/{n}")
        batch.set(scene_ref, {"scene_number": n, "created_at": SERVER_TIMESTAMP}, merge=True)

    batch.commit()
