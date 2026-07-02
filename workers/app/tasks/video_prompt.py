"""Storyboard generation job handler — POST /tasks/video_prompt (Cloud Tasks push target).

Fetches reference images from GCS, generates a scene storyboard via the AI
provider, and writes it to the scene's Firestore document (storyboard_body).
Mirrors the logic that used to run inline on the API service — see
tasks/assets.py for the shared rationale.
"""

import logging

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ai.base import RefImage
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider
from app.services.media_store import MediaStore

logger = logging.getLogger(__name__)

_DEFAULT_ART_STYLE = "painterly illustration with clean lines and rich color"


def _sniff_mime(data: bytes) -> str:
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    return "image/png"


def _make_provider(provider_type: str, provider_key: str):
    match provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=provider_key)
        case _:
            raise ValueError(f"Unknown provider_type '{provider_type}'.")


def _fetch_gcs_images(gcs_paths: list[str]) -> list[RefImage]:
    store = MediaStore()
    images: list[RefImage] = []
    for path in gcs_paths:
        try:
            data = store.get_object_bytes(path)
            images.append(RefImage(data=data, mime_type=_sniff_mime(data)))
        except Exception as e:
            logger.warning("Failed to fetch GCS image %s: %s", path, e)
    return images


def run(payload: dict) -> None:
    """
    Execute one storyboard generation job.

    Expected payload keys (set by backend/app/routers/generation.py::generate_video_prompt):
        firebase_uid, job_id, project_slug, scene_index, scene,
        ref_image_gcs_paths, provider_type, provider_key.
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
        try:
            proj_doc = db.document(f"users/{firebase_uid}/projects/{project_slug}").get()
            gen_settings: dict = (proj_doc.get("generation_settings") or {}) if proj_doc.exists else {}
        except Exception:
            logger.warning("video_prompt: could not fetch generation_settings for %s", project_slug)
            gen_settings = {}
        art_style: str = gen_settings.get("art_style") or _DEFAULT_ART_STYLE
        subtitles: bool = bool(gen_settings.get("video_subtitles", False))

        ref_images = _fetch_gcs_images(payload.get("ref_image_gcs_paths") or [])

        provider = _make_provider(provider_type, payload["provider_key"])
        storyboard = provider.generate_video_prompt(
            payload["scene"], ref_images, art_style=art_style, subtitles=subtitles
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
