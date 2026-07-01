"""Video generation job handler — POST /tasks/video (Cloud Tasks push target).

Executes the Video Worker steps from docs/ArkMask/architecture.md ("Generation
Workers (Cloud Tasks)"). See tasks/image.py for the rationale behind moving
this off the API's own in-process asyncio background task.
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
    """Fetch raw bytes for a list of GCS object paths (reference images)."""
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
    Execute one video generation job.

    Expected payload keys (set by backend/app/routers/generation.py::enqueue_video):
        firebase_uid, job_id, project_slug, scene_index,
        ref_image_gcs_paths, provider_type, provider_key.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    scene_index: int = payload["scene_index"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Video job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")
    fs_path = f"users/{firebase_uid}/projects/{project_slug}/scenes/{scene_index}"

    try:
        # 1. Read storyboard_body from Firestore.
        doc = db.document(fs_path).get()
        storyboard = (doc.get("storyboard_body") or "") if doc.exists else ""
        if not storyboard:
            raise ValueError("Scene has no storyboard_body — generate a storyboard first.")

        # 2. Fetch reference images directly from GCS (no phone round-trip).
        ref_images = _fetch_gcs_images(payload.get("ref_image_gcs_paths") or [])

        # 3. Generate video via AI provider.
        provider = _make_provider(provider_type, payload["provider_key"])
        video_bytes, mime_type = provider.generate_video(storyboard, ref_images)

        # 4. Save to GCS at deterministic path.
        gcs_key = f"{firebase_uid}/{project_slug}/scenes/{scene_index}/video.mp4"
        MediaStore().put_object(gcs_key, video_bytes, mime_type)

        # 5. Write gcs_video_path to Firestore scene doc.
        db.document(fs_path).set({"gcs_video_path": gcs_key, "updated_at": SERVER_TIMESTAMP}, merge=True)

        # 6. Deduct credits atomically + update job + notify.
        deduct_credits(db, firebase_uid, "video", provider_type)
        update_job(db, firebase_uid, job_id, "success", gcs_output_path=gcs_key)
        notify(db, firebase_uid, job_id, "video", project_slug, "completed", scene_index=str(scene_index))
        logger.info("Video job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Video job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "video", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "video", project_slug, "failed")
