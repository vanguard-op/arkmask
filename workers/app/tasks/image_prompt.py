"""Image prompt generation job handler — POST /tasks/image_prompt (Cloud Tasks push target).

Generates an image prompt via the AI provider and writes it to the asset's
Firestore document (prompt_body). Mirrors the logic that used to run inline
on the API service — see tasks/assets.py for the shared rationale.
"""

import logging

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider

logger = logging.getLogger(__name__)

_DEFAULT_ART_STYLE = "painterly illustration with clean lines and rich color"


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
    Execute one image-prompt generation job.

    Expected payload keys (set by backend/app/routers/generation.py::generate_image_prompt):
        firebase_uid, job_id, project_slug, asset_path, name, type,
        description, provider_type, provider_key.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    asset_path: str = payload["asset_path"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Image-prompt job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")

    try:
        # Read generation_settings for art_style (same as the old inline logic).
        try:
            proj_doc = db.document(f"users/{firebase_uid}/projects/{project_slug}").get()
            gen_settings: dict = (proj_doc.get("generation_settings") or {}) if proj_doc.exists else {}
        except Exception:
            logger.warning("image_prompt: could not fetch generation_settings for %s", project_slug)
            gen_settings = {}
        art_style: str = gen_settings.get("art_style") or _DEFAULT_ART_STYLE

        provider = _make_provider(provider_type, payload["provider_key"])
        prompt = provider.generate_image_prompt(
            payload["name"], payload["type"], payload["description"], art_style=art_style
        )

        fs_path = f"users/{firebase_uid}/projects/{project_slug}/{asset_path}"
        db.document(fs_path).set({"prompt_body": prompt, "updated_at": SERVER_TIMESTAMP}, merge=True)

        deduct_credits(db, firebase_uid, "image_prompt", provider_type)
        update_job(db, firebase_uid, job_id, "success")
        notify(db, firebase_uid, job_id, "image_prompt", project_slug, "completed", asset_path=asset_path or "")
        logger.info("Image-prompt job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Image-prompt job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "image_prompt", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "image_prompt", project_slug, "failed")
