"""Image generation job handler — POST /tasks/image (Cloud Tasks push target).

Executes the Image Worker steps from docs/ArkMask/architecture.md ("Generation
Workers (Cloud Tasks)"). This is the real production execution path — it
replaces the old in-process ``asyncio.create_task`` background job that used
to run inside the API's own Cloud Run container (fragile: Cloud Run can
freeze or recycle a container once its HTTP response has been sent, silently
dropping any in-flight background work started via ``asyncio.create_task``).
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


def _sniff_mime(data: bytes) -> str:
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    return "image/png"  # safe default


def _make_provider(provider_type: str, provider_key: str):
    """Instantiate the AI provider adapter — mirrors backend/app/dependencies.py::get_ai_provider."""
    match provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=provider_key)
        case _:
            raise ValueError(f"Unknown provider_type '{provider_type}'.")


def run(payload: dict) -> None:
    """
    Execute one image generation job.

    Expected payload keys (set by backend/app/routers/generation.py::enqueue_image):
        firebase_uid, job_id, project_slug, asset_path,
        conditioning_gcs_path (nullable), provider_type, provider_key.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    asset_path: str = payload["asset_path"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Image job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")
    fs_path = f"users/{firebase_uid}/projects/{project_slug}/{asset_path}"

    try:
        # 1. Read prompt_body from Firestore.
        doc = db.document(fs_path).get()
        if not doc.exists:
            raise ValueError(f"Asset document not found: {fs_path}")
        prompt = doc.get("prompt_body") or ""
        if not prompt:
            raise ValueError("Asset has no prompt_body — generate a prompt first.")

        # 2. Fetch conditioning image if provided (variant asset).
        ref_images: list[RefImage] = []
        conditioning_gcs_path = payload.get("conditioning_gcs_path")
        if conditioning_gcs_path:
            try:
                data = MediaStore().get_object_bytes(conditioning_gcs_path)
                ref_images.append(RefImage(data=data, mime_type=_sniff_mime(data)))
            except Exception as e:
                logger.warning("Could not fetch conditioning image %s: %s", conditioning_gcs_path, e)

        # 3. Generate image via AI provider.
        provider = _make_provider(provider_type, payload["provider_key"])
        img_bytes, mime_type = provider.generate_image(prompt, ref_images)

        # 4. Save to GCS at deterministic path.
        gcs_key = f"{firebase_uid}/{project_slug}/{asset_path}/image.png"
        MediaStore().put_object(gcs_key, img_bytes, mime_type)

        # 5. Write gcs_image_path to Firestore asset doc.
        db.document(fs_path).set({"gcs_image_path": gcs_key, "updated_at": SERVER_TIMESTAMP}, merge=True)

        # 6. Deduct credits atomically + update job + notify.
        deduct_credits(db, firebase_uid, "image", provider_type)
        update_job(db, firebase_uid, job_id, "success", gcs_output_path=gcs_key)
        notify(db, firebase_uid, job_id, "image", project_slug, "completed", asset_path=asset_path or "")
        logger.info("Image job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Image job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "image", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "image", project_slug, "failed")
