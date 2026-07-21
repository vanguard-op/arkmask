"""Generation endpoints — Phase 2+ cloud architecture.

Contract — every generation endpoint is now async (returns {job_id} immediately;
a worker does the actual work and writes results to Firestore, which the app's
existing real-time listeners pick up). This was a deliberate architecture
change: /assets, /image-prompt, and /video-prompt used to run their AI
provider call inline on this API service, subject to Cloud Run's 60s request
timeout — a slow provider response produced a hard 504 with no clean error
path (see the incident that prompted this change). Workers have an 1800s
timeout instead, so slow provider responses just take as long as they take.

  POST /assets          — async; returns {job_id}; worker writes new asset
                           documents directly (see app.services.asset_writer)
  POST /image-prompt     — async; returns {job_id}; worker writes prompt_body to Firestore
  POST /image            — async; returns {job_id}; worker writes gcs_image_path to Firestore
  POST /video-prompt     — async; returns {job_id}; worker writes storyboard_body to Firestore
  POST /video            — async; returns {job_id}; worker writes gcs_video_path to Firestore
  POST /merge            — async; returns {job_id}; worker writes gcs_final_path to Firestore
  GET  /job/{id}/status  — returns job status + presigned URL on success
  POST /media/presigned-url — returns fresh presigned URL for any GCS path

All endpoints:
  - Require X-Platform-Key (get_current_user)
  - Generation endpoints also need X-Provider-Type + X-Provider-Key (get_ai_provider)
  - firebase_uid comes from current_user.firebase_uid

Firestore write paths:
  - Jobs:         users/{uid}/jobs/{job_id}
  - Usage events: users/{uid}/usage_events/{event_id}
  - Credits:      users/{uid}/profile.credit_balance (atomic transaction)

NOTE: /merge requires FFmpeg to be installed on the server (ffmpeg binary in PATH).

SECURITY: X-Provider-Key must NEVER appear in any log statement.
"""

import asyncio
import logging
import subprocess
import tempfile
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, Header, HTTPException
from fastapi.responses import JSONResponse
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from google.cloud.firestore_v1.transaction import transactional
from pydantic import BaseModel

from app.config import get_settings
from app.dependencies import get_ai_provider, get_current_user, _firestore
from app.firestore_paths import profile_path
from app.models.user import UserProfile
from app.routers.projects import _firestore_client
from app.schemas.generation import (
    AssetDependent,
    AssetsDeleteRequest,
    AssetsDeleteResponse,
    AssetsRequest,
    ImageDescribeRequest,
    ImageDescribeResponse,
    MediaUploadUrlRequest,
    MediaUploadUrlResponse,
    VideoEnqueueResponse,
    VideoStatusEnum,
    VideoStatusResponse,
)
from app.services import cloud_tasks
from app.services import asset_manage
from app.services.ai.base import AIProvider, RefImage
from app.services.asset_writer import write_extracted_assets
from app.services.ffmpeg_merge import build_merge_filter_cmd
from app.services.firebase import send_fcm_notification
from app.services.media_store import MediaStore
from app.services.scene_assets import (
    assets_ready_for_storyboard,
    get_generation_settings,
    get_previous_scene_prompt,
    get_scene_text,
    ordered_gcs_image_paths,
    resolve_scene_assets,
    to_asset_prompt_inputs,
)
from app.services.scene_progress import write_video_result

router = APIRouter(tags=["generation"])
logger = logging.getLogger(__name__)

CREDIT_COSTS: dict[str, int] = {
    "/assets": 1,
    "/image-prompt": 1,
    "/video-prompt": 3,
    "/image": 5,
    "/video": 20,
    "/merge": 5,
    "/image-describe": 1,
    "/refine-story": 5,
}

# ── Request / Response schemas (endpoint-local) ───────────────────────────────

class ImagePromptCloudRequest(BaseModel):
    project_slug: str
    asset_path: str
    name: str
    type: str
    description: str


class ImageEnqueueRequest(BaseModel):
    project_slug: str
    asset_path: str
    conditioning_gcs_path: str | None = None


class RefineStoryCloudRequest(BaseModel):
    """
    Story-refinement request (FEAT-038). `story_content`, `generation_settings`,
    and existing character asset names are all resolved server-side from
    Firestore — the client only identifies *which* project, mirroring
    VideoPromptCloudRequest's "client doesn't assemble the payload" pattern.
    See backend/instructions/refine-story-generation.md "Input Format".
    """
    project_slug: str


class VideoPromptCloudRequest(BaseModel):
    """
    Storyboard-generation request. Scene text, the resolved (name, prompt)
    asset list, art_style, and subtitles are all resolved server-side from
    Firestore by app.services.scene_assets — the client only identifies
    *which* scene, it does not assemble the generation payload itself. See
    backend/instructions/video-prompt-generation.md "Input Format".
    """
    project_slug: str
    scene_index: int


class VideoEnqueueCloudRequest(BaseModel):
    """
    Video-generation request. The storyboard text and the ordered reference
    image GCS paths are resolved server-side from Firestore — see
    app.services.scene_assets.
    """
    project_slug: str
    scene_index: int


class SceneMergeEntry(BaseModel):
    scene_index: int
    trim_in: float
    trim_out: float
    transition_to_next: str = "hard_cut"  # hard_cut | fade_black | dissolve


class MergeRequest(BaseModel):
    project_slug: str
    scenes: list[SceneMergeEntry]


class PresignedUrlRequest(BaseModel):
    gcs_path: str


class PresignedUrlResponse(BaseModel):
    url: str


# ── Helpers ───────────────────────────────────────────────────────────────────

def _check_credits(user: UserProfile, endpoint: str) -> int:
    """Raise HTTP 402 if the user has insufficient credits.  Returns the cost."""
    cost = CREDIT_COSTS.get(endpoint, 0)
    if user.credit_balance < cost:
        raise HTTPException(
            status_code=402,
            detail=f"Insufficient credits. Required: {cost}, Available: {user.credit_balance}.",
        )
    return cost


@transactional
def _deduct_in_txn(transaction, user_ref, credits: int) -> None:
    """
    Atomically decrement credit_balance inside a Firestore transaction.

    Using a transaction prevents double-spend when concurrent requests hit the
    same user.  Balance floor is 0 — never goes negative.
    """
    snapshot = user_ref.get(transaction=transaction)
    if not snapshot.exists:
        return
    current: int = (snapshot.to_dict() or {}).get("credit_balance", 0)
    transaction.update(user_ref, {"credit_balance": max(0, current - credits)})


def _deduct_credits(
    firebase_uid: str,
    endpoint: str,
    provider: str,
    credits: int,
    evt_status: str = "success",
) -> None:
    """
    Deduct credits from the user profile via Firestore transaction and write
    a usage event document for the billing ledger.

    ``credits=0`` still writes the usage event (for tracking refunded calls).
    """
    db = _firestore()
    if credits > 0:
        user_ref = db.document(profile_path(firebase_uid))
        txn = db.transaction()
        _deduct_in_txn(txn, user_ref, credits)

    # Write usage event (eventual consistency is acceptable for the ledger).
    db.collection(f"users/{firebase_uid}/usage_events").document().set({
        "endpoint": endpoint,
        "provider": provider,
        "credits_deducted": credits,
        "status": evt_status,
        "timestamp": SERVER_TIMESTAMP,
    })


def _provider_name(provider: AIProvider) -> str:
    return type(provider).__name__.replace("Provider", "").lower()


def _create_job(
    firebase_uid: str,
    job_type: str,
    project_slug: str,
    scene_index: int | None = None,
    asset_path: str | None = None,
) -> str:
    """Write a job document to ``users/{uid}/jobs/{job_id}`` and return job_id."""
    job_id = str(uuid.uuid4())
    _firestore().document(f"users/{firebase_uid}/jobs/{job_id}").set({
        "id": job_id,
        "type": job_type,
        "status": "pending",
        "project_slug": project_slug,
        "scene_index": scene_index,
        "asset_path": asset_path,
        "gcs_output_path": None,
        "error_message": None,
        "created_at": SERVER_TIMESTAMP,
        "updated_at": SERVER_TIMESTAMP,
    })
    return job_id


def _update_job(
    firebase_uid: str,
    job_id: str,
    job_status: str,
    gcs_output_path: str | None = None,
    error_message: str | None = None,
) -> None:
    """Update job status fields in Firestore."""
    data: dict = {"status": job_status, "updated_at": SERVER_TIMESTAMP}
    if gcs_output_path is not None:
        data["gcs_output_path"] = gcs_output_path
    if error_message is not None:
        data["error_message"] = error_message
    _firestore().document(f"users/{firebase_uid}/jobs/{job_id}").update(data)


def _fetch_gcs_images(gcs_paths: list[str]) -> list[RefImage]:
    """Fetch raw bytes for a list of GCS object paths."""
    store = MediaStore()
    images = []
    for path in gcs_paths:
        try:
            data = store.get_object_bytes(path)
            mime = _sniff_mime(data)
            images.append(RefImage(data=data, mime_type=mime))
        except Exception as e:
            logger.warning("Failed to fetch GCS image %s: %s", path, e)
    return images


def _verify_gcs_ownership(firebase_uid: str, gcs_paths: list[str]) -> None:
    """
    Raise HTTP 403 if any GCS path is outside the caller's own namespace.

    Client-supplied GCS paths (conditioning images, video reference images)
    must be validated before being fetched or forwarded to a worker — without
    this check, a request with a valid platform key but a crafted GCS path
    could read another user's reference images (see docs/ArkMask/risk_log.md
    R-022). Mirrors the same check already applied on
    POST /media/presigned-url.
    """
    prefix = f"{firebase_uid}/"
    for path in gcs_paths:
        if path and not path.startswith(prefix):
            raise HTTPException(
                status_code=403,
                detail="Access denied: GCS path is not within your project namespace.",
            )


def _sniff_mime(data: bytes) -> str:
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return "image/png"
    if data[:3] == b'\xff\xd8\xff':
        return "image/jpeg"
    return "image/png"  # safe default


def _get_fcm_token(firebase_uid: str) -> str | None:
    """Fetch the latest FCM token from Firestore for push notification delivery."""
    try:
        doc = _firestore().document(profile_path(firebase_uid)).get()
        return (doc.to_dict() or {}).get("fcm_token") if doc.exists else None
    except Exception:
        return None


# ── POST /assets ──────────────────────────────────────────────────────────────

@router.post("/assets", response_model=VideoEnqueueResponse)
async def extract_assets(
    body: AssetsRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue asset extraction from a story.  Returns job_id immediately.

    On Cloud Run, dispatches to the workers service via Cloud Tasks — the
    worker calls the AI provider, then writes the extracted asset documents
    directly to Firestore (see app.services.asset_writer), mirroring what the
    Flutter app used to do client-side after a synchronous response. The
    app's existing real-time listeners on the assets/scenes subcollections
    pick up the new documents automatically. Locally (no Cloud Tasks
    configured), runs inline via asyncio as a dev-only fallback.

    This endpoint previously ran the AI provider call inline on the API's own
    Cloud Run service, subject to its 60s request timeout — a slow provider
    response produced a hard 504 with no clean error path. Moving it onto the
    same async worker pattern already used for /image, /video, /merge removes
    that ceiling; workers have an 1800s timeout instead.
    Credits deducted: 1 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    _check_credits(user, "/assets")
    job_id = _create_job(firebase_uid, "assets", body.project_slug)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("assets", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "story": body.story,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")
            raw = await asyncio.to_thread(provider.generate_asset_list, body.story)
            write_extracted_assets(
                _firestore_client(), firebase_uid, body.project_slug, raw, story=body.story
            )
            _deduct_credits(firebase_uid, "/assets", pname, CREDIT_COSTS["/assets"])
            _update_job(firebase_uid, job_id, "success")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "assets",
                "project_id": body.project_slug,
                "status": "completed",
            })
            logger.info("Assets job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Assets job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            _deduct_credits(firebase_uid, "/assets", pname, 0, "refunded")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "assets",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /refine-story (FEAT-038) ───────────────────────────────────────────────

def _known_character_names(firebase_uid: str, project_slug: str) -> list[str]:
    """Names of already-extracted `type: "character"` assets for this project.

    Only the project's global `assets/` subcollection is consulted — mirrors
    the "if asset extraction has already run for this project" condition in
    FEAT-038. Kept in sync with workers/app/tasks/refine_story.py's identical
    helper (the API and workers are separate deployable images with no shared
    installable package — see AGENTS.md "Existing Backend Prototype").
    """
    names: list[str] = []
    project_path = f"users/{firebase_uid}/projects/{project_slug}"
    for doc in _firestore_client().collection(f"{project_path}/assets").stream():
        data = doc.to_dict() or {}
        if data.get("type") == "character":
            name = data.get("name") or doc.id
            if name and not name.startswith("@"):
                names.append(name)
    return names


@router.post("/refine-story", response_model=VideoEnqueueResponse)
async def refine_story(
    body: RefineStoryCloudRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue a full-story rewrite (FEAT-038). Returns job_id immediately.

    `story_content`, `generation_settings`, and (if extraction has already
    run) existing character asset names are all resolved server-side from
    Firestore — the client sends only `{project_slug}`. On completion, the
    worker writes the rewritten story to the project document's
    `refined_story_preview` field (never to `story_content` directly — see
    docs/ArkMask/risk_log.md R-026/R-027/R-028 for why this is preview-gated
    rather than auto-applied).

    On Cloud Run, dispatches to the workers service via Cloud Tasks (see
    workers/app/tasks/refine_story.py). Locally (no Cloud Tasks configured),
    runs inline via asyncio as a dev-only fallback, same pattern as /assets.
    Credits deducted: 5 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    _check_credits(user, "/refine-story")
    job_id = _create_job(firebase_uid, "refine", body.project_slug)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("refine", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")

            project_ref = _firestore_client().document(
                f"users/{firebase_uid}/projects/{body.project_slug}"
            )
            project_doc = project_ref.get()
            if not project_doc.exists:
                raise ValueError(f"Project not found: {body.project_slug}")
            project_data = project_doc.to_dict() or {}

            story_content: str = project_data.get("story_content") or ""
            gen_settings: dict = project_data.get("generation_settings") or {}
            _default_art_style = "painterly illustration with clean lines and rich color"
            art_style: str = gen_settings.get("art_style") or _default_art_style
            video_subtitles: bool = bool(gen_settings.get("video_subtitles", False))
            known_names = _known_character_names(firebase_uid, body.project_slug)

            refined_story = await asyncio.to_thread(
                provider.generate_refine_story,
                story_content,
                art_style=art_style,
                video_subtitles=video_subtitles,
                known_character_names=known_names,
            )

            project_ref.set(
                {
                    "refined_story_preview": refined_story,
                    "refined_story_generated_at": SERVER_TIMESTAMP,
                    "updated_at": SERVER_TIMESTAMP,
                },
                merge=True,
            )

            _deduct_credits(firebase_uid, "/refine-story", pname, CREDIT_COSTS["/refine-story"])
            _update_job(firebase_uid, job_id, "success")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "refine",
                "project_id": body.project_slug,
                "status": "completed",
            })
            logger.info("Refine-story job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Refine-story job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            _deduct_credits(firebase_uid, "/refine-story", pname, 0, "refunded")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "refine",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /image-prompt ────────────────────────────────────────────────────────

@router.post("/image-prompt", response_model=VideoEnqueueResponse)
async def generate_image_prompt(
    body: ImagePromptCloudRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue image prompt generation.  Returns job_id immediately.

    On Cloud Run, dispatches to the workers service via Cloud Tasks — the
    worker generates the prompt and writes it to the asset's Firestore
    document (prompt_body). The app's existing real-time listener on the
    asset document already fires on this field, so no mobile-side change is
    needed to *display* the result — only to stop awaiting the HTTP response
    for the loading spinner (see AssetEditorCubit.generatePrompt).

    Previously ran inline on this API service, subject to Cloud Run's 60s
    timeout. Locally (no Cloud Tasks configured), runs inline via asyncio as
    a dev-only fallback. Credits deducted: 1 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    _check_credits(user, "/image-prompt")
    job_id = _create_job(firebase_uid, "image_prompt", body.project_slug, asset_path=body.asset_path)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("image_prompt", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "asset_path": body.asset_path,
            "name": body.name,
            "type": body.type,
            "description": body.description,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")

            _default_art_style = "painterly illustration with clean lines and rich color"
            try:
                proj_doc = _firestore_client().document(
                    f"users/{firebase_uid}/projects/{body.project_slug}"
                ).get()
                gen_settings: dict = (proj_doc.get("generation_settings") or {}) if proj_doc.exists else {}
            except Exception:
                logger.warning("image-prompt: could not fetch generation_settings for %s", body.project_slug)
                gen_settings = {}
            art_style: str = gen_settings.get("art_style") or _default_art_style

            prompt = await asyncio.to_thread(
                provider.generate_image_prompt, body.name, body.type, body.description, art_style=art_style
            )

            fs_path = f"users/{firebase_uid}/projects/{body.project_slug}/{body.asset_path}"
            _firestore_client().document(fs_path).set(
                {"prompt_body": prompt, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            _deduct_credits(firebase_uid, "/image-prompt", pname, CREDIT_COSTS["/image-prompt"])
            _update_job(firebase_uid, job_id, "success")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "image_prompt",
                "project_id": body.project_slug,
                "status": "completed",
                "asset_path": body.asset_path or "",
            })
            logger.info("Image-prompt job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Image-prompt job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            _deduct_credits(firebase_uid, "/image-prompt", pname, 0, "refunded")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "image_prompt",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /image ───────────────────────────────────────────────────────────────

@router.post("/image", response_model=VideoEnqueueResponse)
async def enqueue_image(
    body: ImageEnqueueRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue an image generation job.  Returns job_id immediately.

    On Cloud Run, dispatches to the workers service via Cloud Tasks (see
    app.services.cloud_tasks) — the worker reads prompt_body from Firestore,
    generates the image, and writes gcs_image_path. Locally (no Cloud Tasks
    configured), runs the same steps inline via asyncio as a dev-only fallback.
    Credits deducted: 5 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    if body.conditioning_gcs_path:
        _verify_gcs_ownership(firebase_uid, [body.conditioning_gcs_path])
    _check_credits(user, "/image")
    job_id = _create_job(firebase_uid, "image", body.project_slug, asset_path=body.asset_path)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("image", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "asset_path": body.asset_path,
            "conditioning_gcs_path": body.conditioning_gcs_path,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")

            # 1. Read prompt_body from Firestore.
            fs_path = f"users/{firebase_uid}/projects/{body.project_slug}/{body.asset_path}"
            doc = _firestore_client().document(fs_path).get()
            if not doc.exists:
                raise ValueError(f"Asset document not found: {fs_path}")
            prompt = doc.get("prompt_body") or ""
            if not prompt:
                raise ValueError("Asset has no prompt_body — generate a prompt first.")

            # 2. Fetch conditioning image if provided (variant asset).
            ref_images: list[RefImage] = []
            if body.conditioning_gcs_path:
                try:
                    data = MediaStore().get_object_bytes(body.conditioning_gcs_path)
                    ref_images.append(RefImage(data=data, mime_type=_sniff_mime(data)))
                except Exception as e:
                    logger.warning("Could not fetch conditioning image %s: %s", body.conditioning_gcs_path, e)

            # 3. Generate image via AI provider.
            img_bytes, mime_type = await asyncio.to_thread(provider.generate_image, prompt, ref_images)

            # 4. Save to GCS at deterministic path.
            gcs_key = f"{firebase_uid}/{body.project_slug}/{body.asset_path}/image.png"
            await asyncio.to_thread(MediaStore().put_object, gcs_key, img_bytes, mime_type)

            # 5. Write gcs_image_path to Firestore asset doc.
            _firestore_client().document(fs_path).set(
                {"gcs_image_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            # 6. Deduct credits atomically.
            _deduct_credits(firebase_uid, "/image", pname, CREDIT_COSTS["/image"])

            # 7. Update job status.
            _update_job(firebase_uid, job_id, "success", gcs_output_path=gcs_key)

            # 8. Send FCM push with latest token from Firestore.
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "image",
                "project_id": body.project_slug,
                "status": "completed",
                "asset_path": body.asset_path or "",
            })
            logger.info("Image job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Image job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "image",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /video-prompt ────────────────────────────────────────────────────────

@router.post("/video-prompt", response_model=VideoEnqueueResponse)
async def generate_video_prompt(
    body: VideoPromptCloudRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue scene storyboard generation.  Returns job_id immediately.

    Scene text, the resolved (name, prompt) asset list, art_style, and
    subtitles are all resolved server-side from Firestore by
    app.services.scene_assets — not sent by the client (see
    VideoPromptCloudRequest). This endpoint reads Firestore once up front to
    fail fast (400) if the scene isn't ready; the worker (or the local-dev
    fallback below) re-resolves everything at execution time so the actual
    generation call always uses the freshest data, even if something changed
    between enqueue and the job actually running.

    On Cloud Run, dispatches to the workers service via Cloud Tasks — the
    worker resolves the scene, generates the storyboard, and writes it to the
    scene's Firestore document (storyboard_body). The app's existing
    real-time listener on the scene document already fires on this field.
    Previously ran inline on this API service, subject to Cloud Run's 60s
    timeout. Locally (no Cloud Tasks configured), runs inline via asyncio as
    a dev-only fallback.
    Credits deducted: 3 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    db = _firestore_client()

    assets = resolve_scene_assets(db, firebase_uid, body.project_slug, body.scene_index)
    if not assets_ready_for_storyboard(assets):
        raise HTTPException(
            status_code=400,
            detail="All assets must have generated images before generating a storyboard.",
        )

    _check_credits(user, "/video-prompt")
    job_id = _create_job(firebase_uid, "video_prompt", body.project_slug, scene_index=body.scene_index)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("video_prompt", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "scene_index": body.scene_index,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")

            # Re-resolve at execution time — matches the worker's behaviour
            # and stays correct even if something changed since enqueue.
            scene_text = get_scene_text(db, firebase_uid, body.project_slug, body.scene_index)
            run_assets = resolve_scene_assets(db, firebase_uid, body.project_slug, body.scene_index)
            art_style, subtitles = get_generation_settings(db, firebase_uid, body.project_slug)
            previous_scene_prompt = get_previous_scene_prompt(
                db, firebase_uid, body.project_slug, body.scene_index
            )

            storyboard = await asyncio.to_thread(
                provider.generate_video_prompt,
                scene_text,
                to_asset_prompt_inputs(run_assets),
                art_style=art_style,
                subtitles=subtitles,
                previous_scene_prompt=previous_scene_prompt,
            )

            fs_path = f"users/{firebase_uid}/projects/{body.project_slug}/scenes/{body.scene_index}"
            db.document(fs_path).set(
                {
                    "storyboard_body": storyboard,
                    "scene_number": body.scene_index,
                    "updated_at": SERVER_TIMESTAMP,
                },
                merge=True,
            )

            _deduct_credits(firebase_uid, "/video-prompt", pname, CREDIT_COSTS["/video-prompt"])
            _update_job(firebase_uid, job_id, "success")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "video_prompt",
                "project_id": body.project_slug,
                "status": "completed",
                "scene_index": str(body.scene_index),
            })
            logger.info("Video-prompt job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Video-prompt job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            _deduct_credits(firebase_uid, "/video-prompt", pname, 0, "refunded")
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "video_prompt",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /video ───────────────────────────────────────────────────────────────

@router.post("/video", response_model=VideoEnqueueResponse)
async def enqueue_video(
    body: VideoEnqueueCloudRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> VideoEnqueueResponse:
    """
    Enqueue a video generation job.  Returns job_id immediately.

    The ordered reference-image GCS paths are resolved server-side from
    Firestore by app.services.scene_assets — not sent by the client (see
    VideoEnqueueCloudRequest). This endpoint reads Firestore once up front to
    fail fast (400) if the scene has no storyboard yet; the worker (or the
    local-dev fallback below) re-resolves the image list at execution time.

    On Cloud Run, dispatches to the workers service via Cloud Tasks — the
    worker reads storyboard_body from Firestore, resolves and fetches ref
    images, and generates the video. Locally (no Cloud Tasks configured),
    runs inline via asyncio as a dev-only fallback.
    Credits deducted: 20 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    db = _firestore_client()

    fs_path = f"users/{firebase_uid}/projects/{body.project_slug}/scenes/{body.scene_index}"
    scene_doc = db.document(fs_path).get()
    if not scene_doc.exists or not (scene_doc.get("storyboard_body") or ""):
        raise HTTPException(
            status_code=400,
            detail="Scene has no storyboard_body — generate a storyboard first.",
        )

    _check_credits(user, "/video")
    job_id = _create_job(firebase_uid, "video", body.project_slug, scene_index=body.scene_index)
    pname = _provider_name(provider)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("video", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "scene_index": body.scene_index,
            "provider_type": x_provider_type,
            "provider_key": x_provider_key,
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")

            # 1. Read storyboard_body from Firestore (re-read at execution
            #    time for freshness, matching the worker's behaviour).
            doc = db.document(fs_path).get()
            storyboard = (doc.get("storyboard_body") or "") if doc.exists else ""
            if not storyboard:
                raise ValueError("Scene has no storyboard_body — generate a storyboard first.")

            # 2. Resolve this scene's reference assets and fetch their images
            #    directly from GCS — same resolution rules as /video-prompt
            #    (pass-through resolution, background->character->object
            #    ordering), but this step needs the actual image bytes.
            run_assets = resolve_scene_assets(db, firebase_uid, body.project_slug, body.scene_index)
            ref_images = _fetch_gcs_images(ordered_gcs_image_paths(run_assets))

            # 3. Generate video via AI provider (long-running, runs in thread).
            video_bytes, mime_type = await asyncio.to_thread(provider.generate_video, storyboard, ref_images)

            # 4. Save to GCS at deterministic path.
            gcs_key = f"{firebase_uid}/{body.project_slug}/scenes/{body.scene_index}/video.mp4"
            await asyncio.to_thread(MediaStore().put_object, gcs_key, video_bytes, mime_type)

            # 5. Write gcs_video_path to Firestore scene doc, and bump the
            #    project's completed_scene_count if this is the scene's
            #    first completion (see app.services.scene_progress).
            project_ref = db.document(f"users/{firebase_uid}/projects/{body.project_slug}")
            write_video_result(db.transaction(), db.document(fs_path), project_ref, gcs_key)

            # 6. Deduct credits + update job.
            _deduct_credits(firebase_uid, "/video", pname, CREDIT_COSTS["/video"])
            _update_job(firebase_uid, job_id, "success", gcs_output_path=gcs_key)

            # 7. Send FCM push.
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "video",
                "project_id": body.project_slug,
                "scene_index": str(body.scene_index),
                "status": "completed",
            })
            logger.info("Video job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Video job failed: job_id=%s", job_id, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "video",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /merge ───────────────────────────────────────────────────────────────

@router.post("/merge", response_model=VideoEnqueueResponse)
async def enqueue_merge(
    body: MergeRequest,
    user: UserProfile = Depends(get_current_user),
) -> VideoEnqueueResponse:
    """
    Enqueue a video merge job.  Returns job_id immediately.

    On Cloud Run, dispatches to the workers service via Cloud Tasks — the
    worker downloads scene videos from GCS, runs FFmpeg with trims and
    transitions, uploads final.mp4, and writes gcs_final_path. Locally (no
    Cloud Tasks configured), runs inline via asyncio as a dev-only fallback
    (requires the ffmpeg binary in PATH on the local machine/container).
    Credits deducted: 5 (on terminal success only).
    """
    _check_credits(user, "/merge")
    firebase_uid = user.firebase_uid
    job_id = _create_job(firebase_uid, "merge", body.project_slug)

    if get_settings().cloud_tasks_configured:
        cloud_tasks.enqueue_job("merge", {
            "firebase_uid": firebase_uid,
            "job_id": job_id,
            "project_slug": body.project_slug,
            "scenes": [s.model_dump() for s in body.scenes],
        })
        return VideoEnqueueResponse(job_id=job_id)

    # ── Local dev fallback: run inline instead of dispatching to Cloud Tasks ──
    async def _run():
        try:
            _update_job(firebase_uid, job_id, "running")
            store = MediaStore()

            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                # dict, not SceneMergeEntry, to match app.services.ffmpeg_merge's
                # interface — the same one workers/app/tasks/merge.py uses.
                clip_files: list[tuple[Path, dict]] = []

                # 1. Download each scene video from GCS to temp dir.
                for entry in body.scenes:
                    gcs_key = (
                        f"{firebase_uid}/{body.project_slug}"
                        f"/scenes/{entry.scene_index}/video.mp4"
                    )
                    try:
                        data = await asyncio.to_thread(store.get_object_bytes, gcs_key)
                    except Exception as e:
                        raise ValueError(f"Could not fetch video for scene {entry.scene_index}: {e}")
                    clip_path = tmp_path / f"scene_{entry.scene_index:04d}.mp4"
                    clip_path.write_bytes(data)
                    clip_files.append((clip_path, entry.model_dump()))

                # 2. Run FFmpeg to apply trims + transitions.
                final_path = tmp_path / "final.mp4"
                await asyncio.to_thread(_run_ffmpeg_merge, clip_files, final_path)

                # 3. Upload final.mp4 to GCS.
                gcs_key = f"{firebase_uid}/{body.project_slug}/final.mp4"
                final_bytes = final_path.read_bytes()
                await asyncio.to_thread(store.put_object, gcs_key, final_bytes, "video/mp4")

            # 4. Write gcs_final_path to Firestore project root doc.
            _firestore_client().document(
                f"users/{firebase_uid}/projects/{body.project_slug}"
            ).set(
                {"gcs_final_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            # 5. Deduct credits + update job.
            _deduct_credits(firebase_uid, "/merge", "server", CREDIT_COSTS["/merge"])
            _update_job(firebase_uid, job_id, "success", gcs_output_path=gcs_key)

            # 6. Send FCM push.
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "merge",
                "project_id": body.project_slug,
                "status": "completed",
            })
            logger.info("Merge job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Merge job failed: job_id=%s", job_id, exc_info=True)
            _update_job(firebase_uid, job_id, "failed", error_message=str(e)[:1024])
            send_fcm_notification(_get_fcm_token(firebase_uid), {
                "job_id": job_id,
                "type": "merge",
                "project_id": body.project_slug,
                "status": "failed",
            })

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


def _run_ffmpeg_merge(
    clip_files: list[tuple[Path, dict]],
    output: Path,
) -> None:
    """
    Run FFmpeg to trim clips and concatenate with transitions.

    Strategy:
    - For hard_cut-only timelines: use the concat demuxer (fast, no full re-encode).
    - For fade_black / dissolve transitions: use app.services.ffmpeg_merge's
      filter_complex builder — see that module's docstring for why this does
      NOT use the `xfade` filter (it did briefly; that regressed exactly the
      "current rate of 1/0 is invalid" xfade/VFR bug the original on-device
      implementation was written to avoid in the first place).

    Requires ffmpeg binary in PATH on the server.
    """
    if not clip_files:
        raise ValueError("No clips to merge.")

    all_hard_cut = all(
        entry["transition_to_next"] == "hard_cut"
        for _, entry in clip_files[:-1]
    )

    if all_hard_cut or len(clip_files) == 1:
        # Fast path: concat demuxer (minimal re-encode).
        concat_list = output.parent / "concat.txt"
        lines = []
        for clip_path, entry in clip_files:
            lines.append(f"file '{clip_path}'")
            lines.append(f"inpoint {entry['trim_in']}")
            lines.append(f"outpoint {entry['trim_out']}")
        concat_list.write_text("\n".join(lines))
        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0", "-i", str(concat_list),
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            str(output),
        ]
    else:
        cmd = build_merge_filter_cmd(clip_files, output)

    logger.info("FFmpeg command: %s ...", " ".join(cmd[:8]))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        logger.error("FFmpeg failed:\nstderr=%s", result.stderr[-2000:])
        raise RuntimeError(f"FFmpeg merge failed: {result.stderr[-500:]}")


# ── GET /job/{id}/status ──────────────────────────────────────────────────────

@router.get("/job/{job_id}/status", response_model=VideoStatusResponse)
def get_job_status(
    job_id: str,
    user: UserProfile = Depends(get_current_user),
) -> VideoStatusResponse:
    """
    Poll the status of any async generation job (image, video, merge).
    Returns a presigned URL when status = 'success'.

    Reads from ``users/{uid}/jobs/{job_id}`` — user-scoped so one user cannot
    poll another's job even if they guess the job_id UUID.
    """
    doc = _firestore().document(f"users/{user.firebase_uid}/jobs/{job_id}").get()
    if not doc.exists:
        raise HTTPException(404, f"Job '{job_id}' not found.")

    data: dict = doc.to_dict() or {}
    job_status = data.get("status", "pending")
    gcs_output_path: str | None = data.get("gcs_output_path")

    url = None
    if job_status == "success" and gcs_output_path:
        try:
            url = MediaStore().presign_path(gcs_output_path)
        except Exception:
            logger.warning("Could not generate presigned URL for job %s", job_id)

    return VideoStatusResponse(
        job_id=job_id,
        status=VideoStatusEnum(job_status),
        url=url,
        error=data.get("error_message"),
    )


# ── POST /media/presigned-url ─────────────────────────────────────────────────

@router.post("/media/presigned-url", response_model=PresignedUrlResponse)
def get_presigned_url(
    body: PresignedUrlRequest,
    user: UserProfile = Depends(get_current_user),
) -> PresignedUrlResponse:
    """
    Generate a fresh presigned GET URL for any GCS object path owned by this user.

    Used by the Flutter app when a previously-cached presigned URL expires
    (VideoPlayerScreen expired URL refresh) and when the video editor loads
    clip thumbnails.

    Security: gcs_path must start with ``{firebase_uid}/`` — paths outside the
    user's namespace are rejected with HTTP 403.
    """
    if not body.gcs_path.startswith(f"{user.firebase_uid}/"):
        raise HTTPException(
            status_code=403,
            detail="Access denied: gcs_path is not within your project namespace.",
        )
    try:
        url = MediaStore().presign_path(body.gcs_path)
    except Exception as e:
        logger.error("presigned-url failed: path=%s error=%s", body.gcs_path, e)
        raise HTTPException(502, "Failed to generate presigned URL.")
    return PresignedUrlResponse(url=url)


# ── POST /media/upload-url (FEAT-034) ───────────────────────────────────────────

@router.post("/media/upload-url", response_model=MediaUploadUrlResponse)
def get_upload_url(
    body: MediaUploadUrlRequest,
    user: UserProfile = Depends(get_current_user),
) -> MediaUploadUrlResponse:
    """
    Generate a presigned GCS PUT URL for a manual asset image upload (FEAT-034).

    Mirrors POST /media/presigned-url (GET) but for writes — the app performs
    an HTTP PUT of the raw file bytes directly to the returned URL. The
    device never sends image bytes through Cloud Run.

    Security: the resolved object path (`{uid}/{project_slug}/{object_path}`)
    is implicitly scoped to the caller's own namespace since it is built
    server-side from the authenticated uid — there is no way for the caller
    to escape their own prefix (see docs/ArkMask/risk_log.md R-024).
    """
    gcs_path = f"{user.firebase_uid}/{body.project_slug}/{body.object_path}"
    try:
        upload_url = MediaStore().presign_put(gcs_path, body.content_type)
    except Exception as e:
        logger.error("upload-url failed: path=%s error=%s", gcs_path, e)
        raise HTTPException(502, "Failed to generate upload URL.")
    return MediaUploadUrlResponse(upload_url=upload_url, gcs_path=gcs_path)


# ── POST /image-describe (FEAT-034) ─────────────────────────────────────────────

@router.post("/image-describe", response_model=ImageDescribeResponse)
async def describe_image(
    body: ImageDescribeRequest,
    user: UserProfile = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
) -> ImageDescribeResponse:
    """
    Generate a text description of an uploaded image (FEAT-034).

    Synchronous, single vision-model call — same response pattern as
    /image-prompt (text in/out, no job polling, no Firestore write). The
    caller presents the returned description for review/edit before saving
    the asset document; this endpoint never writes to Firestore itself.
    Credits deducted: 1 (on terminal success only).
    """
    firebase_uid = user.firebase_uid
    _verify_gcs_ownership(firebase_uid, [body.gcs_path])
    _check_credits(user, "/image-describe")
    pname = _provider_name(provider)

    try:
        data = await asyncio.to_thread(MediaStore().get_object_bytes, body.gcs_path)
    except Exception as e:
        logger.error("image-describe: could not fetch %s: %s", body.gcs_path, e)
        raise HTTPException(404, "Uploaded image not found — has the upload completed?")

    image = RefImage(data=data, mime_type=_sniff_mime(data))
    try:
        description = await asyncio.to_thread(provider.generate_image_description, image, body.type.value)
    except Exception as e:
        logger.error("image-describe: generation failed: %s", e, exc_info=True)
        _deduct_credits(firebase_uid, "/image-describe", pname, 0, "refunded")
        raise HTTPException(502, "Failed to generate an image description.")

    _deduct_credits(firebase_uid, "/image-describe", pname, CREDIT_COSTS["/image-describe"])
    return ImageDescribeResponse(description=description)


# ── DELETE /assets (FEAT-037) ───────────────────────────────────────────────────

@router.delete(
    "/assets",
    response_model=AssetsDeleteResponse,
    responses={409: {"model": None, "description": "Blocked by dependent references"}},
)
def delete_asset(
    body: AssetsDeleteRequest,
    user: UserProfile = Depends(get_current_user),
):
    """
    Hard-delete a manually created or extracted asset (FEAT-037).

    Requires the backend (rather than a direct Flutter Firestore write)
    because the client has no GCS delete credentials. Deletes the Firestore
    asset document and all GCS objects under its asset path (image.png, and
    original.<ext> if present).

    Blocks the delete (HTTP 409, listing dependents) if any other asset in
    the project has a `ref` field whose chain resolves through this one
    (FEAT-013), directly or transitively — unless `force` is set, in which
    case the delete proceeds regardless and any dependent reference is left
    dangling (see docs/ArkMask/risk_log.md R-025/R-029; the UI strongly
    discourages this path).
    """
    firebase_uid = user.firebase_uid
    db = _firestore_client()

    try:
        asset_manage.parse_asset_path(body.asset_path)
    except ValueError as e:
        raise HTTPException(400, str(e))

    if not body.force:
        dependents = asset_manage.find_dependent_assets(db, firebase_uid, body.project_slug, body.asset_path)
        if dependents:
            return JSONResponse(
                status_code=409,
                content={
                    "dependents": [
                        AssetDependent(
                            asset_path=d.asset_path, name=d.name, ref=d.ref
                        ).model_dump()
                        for d in dependents
                    ]
                },
            )

    try:
        asset_manage.delete_asset(db, MediaStore(), firebase_uid, body.project_slug, body.asset_path)
    except Exception as e:
        logger.error("delete_asset failed: asset_path=%s error=%s", body.asset_path, e, exc_info=True)
        raise HTTPException(502, "Failed to delete asset.")

    return AssetsDeleteResponse(deleted=True)
