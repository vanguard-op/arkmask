"""Generation endpoints — the five AI pipeline steps (Phase 2+, FEAT-009 to FEAT-016).

All endpoints require three headers:
  X-Platform-Key    — validated by `get_current_user` (billing identity)
  X-Provider-Type   — 'gemini' or 'byteplus'
  X-Provider-Key    — user's own AI API key (BYOK, never stored)

Credit deduction is atomic: a `usage_events` row is only written after the
AI provider call reaches terminal success. Provider-side failures produce a
zero-credit refund event. Credits are never deducted speculatively.

IMPORTANT: `X-Provider-Key` must never appear in any log statement.
The logging in this file uses user_id (not the key) for attribution.
"""

import logging
import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from google.genai._gaos.lib.compat_errors import BadRequestError

from app.services.ai.gemini import ContentBlockedError
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import get_ai_provider, get_current_user
from app.models.db import UsageEvent, User
from app.schemas.generation import (
    AssetsRequest,
    AssetsResponse,
    AssetItem,
    ImagePromptRequest,
    ImagePromptResponse,
    ImageResponse,
    VideoEnqueueResponse,
    VideoPromptResponse,
    VideoStatusEnum,
    VideoStatusResponse,
)
from app.services.ai.base import AIProvider, RefImage
from app.services.media_store import MediaStore


def _extract_provider_message(e: BadRequestError) -> str:
    """Pull the human-readable message out of a BadRequestError.

    The SDK serialises the error as:
        "Error code: 400 - {'error': {'message': '...', 'code': '...'}}"
    The inner dict uses Python repr (single quotes), not JSON, so json.loads
    fails.  We use ast.literal_eval which handles Python dict/str literals.
    Falls back to the raw string if parsing fails.
    """
    import ast
    msg = str(e)
    try:
        start = msg.index("{")
        end = msg.rindex("}") + 1
        payload = ast.literal_eval(msg[start:end])
        return str(payload["error"]["message"])
    except Exception:
        # Already a clean string or unparseable — return as-is.
        return msg


def _provider_error_http(e: Exception, fallback_detail: str) -> HTTPException:
    """Convert an AI provider exception to an appropriate HTTPException.

    - BadRequestError (400 from the provider API): content rejected by the
      provider's safety API — return 400 with the provider's message.
    - ContentBlockedError: prompt blocked by the model's content policy before
      generation — also a client-side issue, return 400.
    - Anything else: opaque provider or server failure → 502 Bad Gateway.
    """
    if isinstance(e, BadRequestError):
        detail = _extract_provider_message(e)
        return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)
    if isinstance(e, ContentBlockedError):
        return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=fallback_detail)

router = APIRouter(tags=["generation"])
logger = logging.getLogger(__name__)

# Credit costs per endpoint (see architecture.md provider model mapping).
CREDIT_COSTS: dict[str, int] = {
    "/assets": 1,
    "/image-prompt": 1,
    "/video-prompt": 3,
    "/image": 5,
    "/video": 20,
}


def _deduct_credits(
    db: Session,
    user: User,
    endpoint: str,
    provider: str,
    credits: int,
    status: str = "success",
) -> None:
    """
    Atomically write a usage event and decrement the user's credit balance.

    Both operations are committed in a single transaction.
    `status='refunded'` is used when a provider error triggers a zero-credit event.
    """
    event = UsageEvent(
        user_id=user.id,
        endpoint=endpoint,
        provider=provider,
        credits_deducted=credits,
        status=status,
    )
    db.add(event)
    if credits > 0:
        user.credit_balance = User.credit_balance - credits
    db.commit()


def _check_credits(user: User, endpoint: str) -> int:
    """
    Return the credit cost for `endpoint` and raise HTTP 402 if balance is insufficient.
    """
    cost = CREDIT_COSTS.get(endpoint, 0)
    if user.credit_balance < cost:
        raise HTTPException(
            status_code=402,
            detail=f"Insufficient credits. Required: {cost}, Available: {user.credit_balance}.",
            headers={"credit_balance": str(user.credit_balance)},
        )
    return cost


# ── POST /assets ──────────────────────────────────────────────────────────────

@router.post("/assets", response_model=AssetsResponse)
def extract_assets(
    body: AssetsRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> AssetsResponse:
    """
    Extract all visual assets (characters, backgrounds, objects) from a story.

    Sends the full story.mdx content to the AI provider and returns a structured
    list of assets with scene assignments. The Flutter app uses this list to create
    the on-device asset directory tree. (FEAT-009)

    Credits deducted: 1 (on success only).
    """
    cost = _check_credits(user, "/assets")
    provider_name = type(provider).__name__.replace("Provider", "").lower()

    try:
        raw_assets = provider.generate_asset_list(body.story)
    except Exception as e:
        logger.error("Asset extraction failed: user_id=%s error=%s", user.id, type(e).__name__, exc_info=True)
        _deduct_credits(db, user, "/assets", provider_name, 0, "refunded")
        raise _provider_error_http(e, "AI provider error during asset extraction.")

    _deduct_credits(db, user, "/assets", provider_name, cost)
    return AssetsResponse(assets=[AssetItem(**a) for a in raw_assets])


# ── POST /image-prompt ────────────────────────────────────────────────────────

@router.post("/image-prompt", response_model=ImagePromptResponse)
def generate_image_prompt(
    body: ImagePromptRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> ImagePromptResponse:
    """
    Generate an image prompt for an asset from its name, type, and description.

    The prompt is written to the body of the asset's `prompt.mdx` file on-device.
    (FEAT-011)

    Credits deducted: 1 (on success only).
    """
    cost = _check_credits(user, "/image-prompt")
    provider_name = type(provider).__name__.replace("Provider", "").lower()

    try:
        prompt = provider.generate_image_prompt(body.name, body.type.value, body.description)
    except Exception as e:
        logger.error("Image prompt generation failed: user_id=%s error=%s", user.id, type(e).__name__, exc_info=True)
        _deduct_credits(db, user, "/image-prompt", provider_name, 0, "refunded")
        raise _provider_error_http(e, "AI provider error during image prompt generation.")

    _deduct_credits(db, user, "/image-prompt", provider_name, cost)
    return ImagePromptResponse(prompt=prompt)


# ── POST /image ───────────────────────────────────────────────────────────────

@router.post("/image", response_model=ImageResponse)
async def generate_image(
    prompt: str = Form(...),
    ref_images: list[UploadFile] = File(default=[]),
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> ImageResponse:
    """
    Generate a reference image for an asset from its prompt (and optional ref images).

    The generated image is uploaded to GCS/MinIO and a presigned URL (2-hour TTL)
    is returned. The Flutter app downloads the image and saves it as `image.png`
    on-device. (FEAT-012)

    Credits deducted: 5 (on success only).
    """
    cost = _check_credits(user, "/image")
    provider_name = type(provider).__name__.replace("Provider", "").lower()

    ref = [
        RefImage(data=await f.read(), mime_type=f.content_type or "image/png")
        for f in ref_images
    ]

    try:
        img_bytes, mime_type = provider.generate_image(prompt, ref)
    except Exception as e:
        logger.error("Image generation failed: user_id=%s error=%s", user.id, type(e).__name__, exc_info=True)
        _deduct_credits(db, user, "/image", provider_name, 0, "refunded")
        raise _provider_error_http(e, "AI provider error during image generation.")

    store = MediaStore()
    url = store.save(img_bytes, mime_type)
    _deduct_credits(db, user, "/image", provider_name, cost)
    return ImageResponse(url=url)


# ── POST /video-prompt ────────────────────────────────────────────────────────

@router.post("/video-prompt", response_model=VideoPromptResponse)
async def generate_video_prompt(
    scene_text: str = Form(...),
    asset_names: list[str] = Form(default=[], alias="asset_names[]"),
    asset_types: list[str] = Form(default=[], alias="asset_types[]"),
    asset_images: list[UploadFile] = File(default=[], alias="asset_images[]"),
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> VideoPromptResponse:
    """
    Generate a scene storyboard prompt (written to ark.mdx body).

    Accepts the scene's story text and up to 4 asset images as reference.
    The storyboard prompt includes subtitle suppression instructions.
    (FEAT-014)

    Credits deducted: 3 (on success only).
    """
    cost = _check_credits(user, "/video-prompt")
    provider_name = type(provider).__name__.replace("Provider", "").lower()

    assets_meta = [
        {"name": name, "type": type_}
        for name, type_ in zip(asset_names, asset_types)
    ]

    # Read the uploaded asset images.
    ref_images = [
        RefImage(data=await f.read(), mime_type=f.content_type or "image/png")
        for f in asset_images[:4]  # cap at 4 per architecture constraint
    ]

    try:
        storyboard = provider.generate_video_prompt(scene_text, assets_meta)
    except Exception as e:
        logger.error("Video prompt generation failed: user_id=%s error=%s", user.id, type(e).__name__)
        _deduct_credits(db, user, "/video-prompt", provider_name, 0, "refunded")
        raise HTTPException(status_code=502, detail="AI provider error during storyboard generation.")

    _deduct_credits(db, user, "/video-prompt", provider_name, cost)
    return VideoPromptResponse(storyboard=storyboard)


# ── POST /video ───────────────────────────────────────────────────────────────
#
# Video generation is long-running (typically 2–5 minutes). In production
# this endpoint enqueues a Google Cloud Task and returns a job_id immediately.
# The Flutter app polls GET /video/{job_id}/status for completion.
#
# For Phase 1 / local dev, the endpoint runs the generation synchronously in a
# FastAPI BackgroundTask to avoid blocking the HTTP response. The job status is
# stored in-memory (suitable for local dev only; Cloud Tasks replaces this in
# production to survive Cloud Run scale-to-zero events).

import asyncio
from contextlib import asynccontextmanager
from typing import Any

# In-memory job store for local dev. Replaced by Cloud SQL in production.
_jobs: dict[str, dict[str, Any]] = {}


@router.post("/video", response_model=VideoEnqueueResponse)
async def generate_video(
    storyboard: str = Form(...),
    asset_names: list[str] = Form(default=[], alias="asset_names[]"),
    asset_images: list[UploadFile] = File(default=[], alias="asset_images[]"),
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> VideoEnqueueResponse:
    """
    Enqueue a scene video generation job.

    Returns a `job_id` immediately. The Flutter app polls
    `GET /video/{job_id}/status` every 10 seconds until `status = 'success'`
    or `status = 'failed'`.

    Credits deducted: 20 (on terminal success only — not on enqueue).
    (FEAT-016)
    """
    _check_credits(user, "/video")
    provider_name = type(provider).__name__.replace("Provider", "").lower()
    job_id = str(uuid.uuid4())
    _jobs[job_id] = {"status": "pending", "url": None, "error": None}

    ref_images = [
        RefImage(data=await f.read(), mime_type=f.content_type or "image/png")
        for f in asset_images[:4]
    ]

    async def _run_job():
        _jobs[job_id]["status"] = "running"
        try:
            video_bytes, mime_type = await asyncio.to_thread(
                provider.generate_video, storyboard, ref_images
            )
            store = MediaStore()
            url = await asyncio.to_thread(store.save, video_bytes, mime_type)
            _deduct_credits(db, user, "/video", provider_name, CREDIT_COSTS["/video"])
            _jobs[job_id]["status"] = "success"
            _jobs[job_id]["url"] = url
            logger.info("Video job complete: job_id=%s user_id=%s", job_id, user.id)
        except Exception as e:
            logger.error("Video job failed: job_id=%s user_id=%s error=%s", job_id, user.id, type(e).__name__, exc_info=True)
            _deduct_credits(db, user, "/video", provider_name, 0, "refunded")
            _jobs[job_id]["status"] = "failed"
            err_msg = str(e) if isinstance(e, BadRequestError) else "Video generation failed. Credits not deducted."
            _jobs[job_id]["error"] = err_msg

    asyncio.create_task(_run_job())
    return VideoEnqueueResponse(job_id=job_id)


@router.get("/video/{job_id}/status", response_model=VideoStatusResponse)
def get_video_status(job_id: str) -> VideoStatusResponse:
    """
    Poll the status of a video generation job.

    The Flutter app calls this every 10 seconds while the app is in the foreground.
    Returns the GCS presigned URL when `status = 'success'` (2-hour TTL).
    """
    job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found.")
    return VideoStatusResponse(
        job_id=job_id,
        status=VideoStatusEnum(job["status"]),
        url=job.get("url"),
        error=job.get("error"),
    )
