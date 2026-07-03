"""Server-side resolution of a scene's text, generation settings, and
reference assets.

This is the single source of truth for the resolution logic that used to
live only in the Flutter app (`mobile/lib/features/scene/cubit/scene_cubit.dart`
`_parseSceneText` / `_rebuildState`). The client used to compute the scene
text and the ordered, pass-through-resolved asset list itself and ship the
result to `/video-prompt` and `/video` — which meant:

  - Two independent implementations of the same resolution rules (Dart here,
    none in Python) that could silently drift apart.
  - The payload could go stale between when the client snapshotted it and
    when the (async) job actually executed.
  - `/video-prompt` was shipping full reference *images* to the storyboard
    LLM call, which backend/instructions/video-prompt-generation.md never
    asked for — it only wants each asset's `name` and `prompt` text.

Both `backend/app/routers/generation.py` (local-dev inline fallback) and
`workers/app/tasks/{video_prompt,video}.py` (the actual Cloud Tasks
production path) call into this module so there is exactly one
implementation of "what does this scene look like right now".

Kept in `app/services/` (not `app/routers/`) because this module is also
imported by the workers image, which copies `backend/app/services/` wholesale
— see `workers/Dockerfile`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from app.services.ai.base import AssetPromptInput

_DEFAULT_ART_STYLE = "painterly illustration with clean lines and rich color"

# Matches an MDX scene heading of the form "# 3" on its own line — mirrors
# StoryCubit._parseScenes / SceneCubit._parseSceneText in the Flutter app.
_HEADING_RE = re.compile(r"^# (\d+)\s*$", re.MULTILINE)

# background -> character -> object, matching SceneCubit._typePriority. This
# ordering is meaningful: it determines each asset's "Image N" number, which
# the storyboard/video prompts rely on for character/background/object
# identification.
_TYPE_PRIORITY = {"background": 0, "character": 1, "object": 2}


@dataclass(frozen=True)
class ResolvedAsset:
    """One scene's fully-resolved reference asset.

    For a pass-through reference (name starts with "@", description empty),
    `prompt`/`gcs_image_path`/`type` are the *referenced* global asset's
    values, not the scene-local document's own (empty) fields — mirroring
    SceneCubit._rebuildState's pass-through resolution exactly.
    """

    name: str
    prompt: str
    gcs_image_path: str | None
    type: str | None

    @property
    def has_image(self) -> bool:
        return bool(self.gcs_image_path)

    @property
    def has_prompt(self) -> bool:
        return bool(self.prompt)


def parse_scene_text(story_content: str | None, target_scene: int) -> str:
    """Extract the body for `target_scene` from `story_content` MDX.

    Mirrors StoryCubit._parseScenes / SceneCubit._parseSceneText: content is
    split on `# N` headings; a document with no headings at all is treated
    as scene 1 in its entirety.
    """
    raw = (story_content or "").strip()
    if not raw:
        return ""

    matches = list(_HEADING_RE.finditer(raw))
    if not matches:
        return raw if target_scene == 1 else ""

    for i, match in enumerate(matches):
        number = int(match.group(1))
        if number != target_scene:
            continue
        body_start = match.end()
        body_end = matches[i + 1].start() if i + 1 < len(matches) else len(raw)
        return raw[body_start:body_end].strip()

    return ""


def get_scene_text(db, uid: str, project_slug: str, scene_index: int) -> str:
    """Read the project's `story_content` and extract this scene's body.

    Convenience wrapper around `parse_scene_text` for the common case of
    "I have a Firestore client and a scene index, give me the text" — used
    by both the API's local-dev fallback and the Cloud Tasks worker.
    """
    doc = db.document(f"users/{uid}/projects/{project_slug}").get()
    story_content = (doc.to_dict() or {}).get("story_content") if doc.exists else None
    return parse_scene_text(story_content, scene_index)


def get_generation_settings(db, uid: str, project_slug: str) -> tuple[str, bool]:
    """Return (art_style, subtitles) from the project's `generation_settings`.

    Falls back to defaults (and logs nothing — callers already log on
    failure elsewhere) if the project document or field is missing.
    """
    doc = db.document(f"users/{uid}/projects/{project_slug}").get()
    settings: dict = (doc.get("generation_settings") or {}) if doc.exists else {}
    art_style = settings.get("art_style") or _DEFAULT_ART_STYLE
    subtitles = bool(settings.get("video_subtitles", False))
    return art_style, subtitles


def get_previous_scene_prompt(db, uid: str, project_slug: str, scene_index: int) -> str:
    """Return scene `scene_index - 1`'s generated video prompt (`storyboard_body`).

    This is the *generated* storyboard/video prompt from the prior scene —
    not its raw `story_content` text — so the video-prompt model can read
    what was actually asked of the previous shot (camera, blocking, lighting,
    established continuity) when deciding whether the new scene continues
    directly from it or is a hard cut to somewhere new. See
    backend/instructions/video-prompt-generation.md "Continuity Inference".

    Returns `""` when there is no previous scene (scene_index <= the first
    scene number, whatever that happens to be) or when the previous scene's
    document exists but has no `storyboard_body` yet (e.g. not generated
    yet) — in both cases the doc simply won't exist/won't have the field, so
    no special-cased "first scene" check is needed here.
    """
    previous_index = scene_index - 1
    if previous_index < 0:
        return ""
    doc = db.document(f"users/{uid}/projects/{project_slug}/scenes/{previous_index}").get()
    if not doc.exists:
        return ""
    return (doc.to_dict() or {}).get("storyboard_body") or ""


def _extract_base_name(name: str) -> str:
    """`"@/scenes/2/hero"` -> `"hero"`. Mirrors SceneCubit._extractBaseName."""
    without_at = name[1:] if name.startswith("@") else name
    parts = [p for p in without_at.split("/") if p]
    return parts[-1] if parts else name


def _type_priority(asset_type: str | None) -> int:
    return _TYPE_PRIORITY.get(asset_type or "", 3)


def resolve_scene_assets(db, uid: str, project_slug: str, scene_index: int) -> list[ResolvedAsset]:
    """Resolve this scene's ordered reference assets.

    Mirrors SceneCubit._rebuildState() in the Flutter app exactly:
      1. Read this scene's local assets (`scenes/{n}/assets`) and the
         project's global assets (`assets/`).
      2. A pass-through scene asset (description empty) delegates to the
         global asset with the matching base name — using ITS prompt,
         image, and type, not the scene-local document's own (empty) fields.
      3. Sort background -> character -> object, stable within a type (the
         order scene-local asset documents were read in is preserved).

    Only scene-local asset documents produce rows — a global asset that is
    never referenced by a scene-local pass-through document does not appear
    in this scene's resolved list, matching the existing Dart behaviour.
    """
    project_path = f"users/{uid}/projects/{project_slug}"

    global_by_name: dict[str, dict] = {}
    for doc in db.collection(f"{project_path}/assets").stream():
        data = doc.to_dict() or {}
        global_by_name[data.get("name") or doc.id] = data

    def _find_global(base_name: str) -> dict:
        if base_name in global_by_name:
            return global_by_name[base_name]
        lower = base_name.lower()
        for name, data in global_by_name.items():
            if name.lower() == lower:
                return data
        return {}

    entries: list[tuple[int, ResolvedAsset]] = []
    for doc in db.collection(f"{project_path}/scenes/{scene_index}/assets").stream():
        data = doc.to_dict() or {}
        name = data.get("name") or doc.id
        description = data.get("description") or ""
        is_pass_through = description == ""

        if is_pass_through:
            referenced = _find_global(_extract_base_name(name))
            prompt = referenced.get("prompt_body") or ""
            gcs_image_path = referenced.get("gcs_image_path")
            asset_type = referenced.get("type")
        else:
            prompt = data.get("prompt_body") or ""
            gcs_image_path = data.get("gcs_image_path")
            asset_type = data.get("type")

        resolved = ResolvedAsset(
            name=name,
            prompt=prompt,
            gcs_image_path=gcs_image_path,
            type=asset_type,
        )
        entries.append((_type_priority(asset_type), resolved))

    # Python's sort is stable, so entries keep their Firestore read order
    # within each type group — same intent as the Dart comment "Stable sort
    # preserves relative FCFS order within each type group."
    entries.sort(key=lambda e: e[0])
    return [resolved for _, resolved in entries]


def to_asset_prompt_inputs(assets: list[ResolvedAsset]) -> list[AssetPromptInput]:
    """Convert resolved assets to the shape `generate_video_prompt` expects."""
    return [AssetPromptInput(name=a.name, prompt=a.prompt) for a in assets]


def ordered_gcs_image_paths(assets: list[ResolvedAsset]) -> list[str]:
    """GCS paths of every resolved asset that has an image, in scene order.

    Mirrors `[for (final asset in s.assets) if (asset.gcsImagePath != null) asset.gcsImagePath!]`
    in SceneCubit — used by `generate_video` (real reference images), not by
    `generate_video_prompt` (text-only).
    """
    return [a.gcs_image_path for a in assets if a.gcs_image_path]


def assets_ready_for_storyboard(assets: list[ResolvedAsset]) -> bool:
    """True when every resolved asset has a GCS image — the readiness gate
    for storyboard generation (FEAT-014 acceptance criteria: "If any asset in
    the scene is missing its gcs_image_path ... generation is blocked").

    Kept as an explicit product-level gate even though `generate_video_prompt`
    itself only reads `prompt` text — mirrors SceneCubit.allAssetsHaveImages.
    """
    return bool(assets) and all(a.has_image for a in assets)
