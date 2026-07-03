"""Storyboard generation job handler — POST /tasks/video_prompt (Cloud Tasks push target).

Resolves the scene's text and reference assets (name + generated image
prompt text — no images) server-side via app.services.scene_assets, calls
the AI provider, and writes the result to the scene's Firestore document
(storyboard_body). Mirrors the logic that used to run inline on the API
service — see tasks/assets.py for the shared rationale.

Resolution moved server-side (previously the payload carried a pre-resolved
`scene` string and `ref_image_gcs_paths` sent by the Flutter client) so that:
  - There is exactly one implementation of "what does this scene look like"
    (app.services.scene_assets), instead of duplicate Dart/Python logic that
    could drift apart.
  - The job always uses Firestore state as of *execution* time, not whatever
    the client happened to see when it enqueued the job.
  - The storyboard-prompt AI call no longer needs images at all — see
    backend/instructions/video-prompt-generation.md "Input Format": it reads
    each asset's `name` and `prompt` text only.

Also reads the previous scene's own generated video prompt
(`scenes/{scene_index-1}.storyboard_body`, via
app.services.scene_assets.get_previous_scene_prompt) and passes it through as
`previous_scene_prompt` — "" for the first scene / when the prior scene has
no storyboard yet. This lets the model infer continuity (or a deliberate
hard cut) from the new scene's own text/assets — see
backend/instructions/video-prompt-generation.md "Continuity Inference".
"""

import logging

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider
from app.services.scene_assets import (
    assets_ready_for_storyboard,
    get_generation_settings,
    get_previous_scene_prompt,
    get_scene_text,
    resolve_scene_assets,
    to_asset_prompt_inputs,
)

logger = logging.getLogger(__name__)


def _make_provider(provider_type: str, provider_key: str):
    match provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=provider_key)
        case _:
            raise ValueError(f"Unknown provider_type '{provider_type}'.")


def run(payload: dict) -> None:
    """
    Execute one storyboard generation job.

    Expected payload keys (set by backend/app/routers/generation.py::generate_video_prompt):
        firebase_uid, job_id, project_slug, scene_index, provider_type, provider_key.

    Scene text, the resolved asset list, art_style, and subtitles are all
    read from Firestore here — not taken from the payload — so the job
    always reflects the current state at execution time.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    scene_index: int = payload["scene_index"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Video-prompt job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")

    try:
        assets = resolve_scene_assets(db, firebase_uid, project_slug, scene_index)
        if not assets_ready_for_storyboard(assets):
            raise ValueError(
                "All assets must have generated images before generating a storyboard."
            )

        scene_text = get_scene_text(db, firebase_uid, project_slug, scene_index)
        art_style, subtitles = get_generation_settings(db, firebase_uid, project_slug)
        previous_scene_prompt = get_previous_scene_prompt(db, firebase_uid, project_slug, scene_index)

        provider = _make_provider(provider_type, payload["provider_key"])
        storyboard = provider.generate_video_prompt(
            scene_text,
            to_asset_prompt_inputs(assets),
            art_style=art_style,
            subtitles=subtitles,
            previous_scene_prompt=previous_scene_prompt,
        )

        fs_path = f"users/{firebase_uid}/projects/{project_slug}/scenes/{scene_index}"
        db.document(fs_path).set(
            {
                "storyboard_body": storyboard,
                "scene_number": scene_index,
                "updated_at": SERVER_TIMESTAMP,
            },
            merge=True,
        )

        deduct_credits(db, firebase_uid, "video_prompt", provider_type)
        update_job(db, firebase_uid, job_id, "success")
        notify(db, firebase_uid, job_id, "video_prompt", project_slug, "completed", scene_index=str(scene_index))
        logger.info("Video-prompt job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Video-prompt job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "video_prompt", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "video_prompt", project_slug, "failed")
