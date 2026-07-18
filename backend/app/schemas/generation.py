"""Pydantic schemas for the five generation endpoints."""

from enum import Enum

from pydantic import BaseModel, Field


class AssetTypeEnum(str, Enum):
    CHARACTER = "character"
    BACKGROUND = "background"
    OBJECT = "object"


# ── POST /assets ──────────────────────────────────────────────────────────────

class AssetsRequest(BaseModel):
    project_slug: str
    story: str


class AssetItem(BaseModel):
    name: str
    type: AssetTypeEnum
    scene_number: int = Field(..., ge=0)
    description: str


class AssetsResponse(BaseModel):
    assets: list[AssetItem]


# ── POST /image-prompt ────────────────────────────────────────────────────────

class ImagePromptRequest(BaseModel):
    name: str
    type: AssetTypeEnum
    description: str


class ImagePromptResponse(BaseModel):
    prompt: str


# ── POST /image (multipart/form-data) ─────────────────────────────────────────

class ImageResponse(BaseModel):
    """GCS / MinIO presigned URL for the generated image."""
    url: str


# ── POST /video-prompt (application/json) ─────────────────────────────────────
#
# The request body is just {project_slug, scene_index} — see
# VideoPromptCloudRequest in app/routers/generation.py. Scene text, the
# resolved asset (name, prompt) list, art_style, and subtitles are all
# resolved server-side from Firestore by app.services.scene_assets, not sent
# by the client. See backend/instructions/video-prompt-generation.md for the
# exact shape passed to the AI provider.


class VideoPromptResponse(BaseModel):
    storyboard: str


# ── POST /video (multipart/form-data) ─────────────────────────────────────────
# VideoRequest and VideoRefImage are no longer needed — the /video endpoint
# now uses Form + File parameters directly (matching /image), so ref images
# are received as list[UploadFile] without a JSON wrapper.


class VideoEnqueueResponse(BaseModel):
    """Returned immediately after enqueueing the video generation job."""
    job_id: str


# ── GET /video/{job_id}/status ────────────────────────────────────────────────

class VideoStatusEnum(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"


class VideoStatusResponse(BaseModel):
    job_id: str
    status: VideoStatusEnum
    url: str | None = None     # present only when status = success
    error: str | None = None   # present only when status = failed


# ── POST /media/upload-url (FEAT-034) ─────────────────────────────────────────

class MediaUploadUrlRequest(BaseModel):
    project_slug: str
    object_path: str
    content_type: str


class MediaUploadUrlResponse(BaseModel):
    upload_url: str
    gcs_path: str


# ── POST /image-describe (FEAT-034) ───────────────────────────────────────────

class ImageDescribeRequest(BaseModel):
    gcs_path: str
    type: AssetTypeEnum


class ImageDescribeResponse(BaseModel):
    description: str


# ── DELETE /assets (FEAT-037) ─────────────────────────────────────────────────

class AssetsDeleteRequest(BaseModel):
    project_slug: str
    asset_path: str
    force: bool = False


class AssetsDeleteResponse(BaseModel):
    deleted: bool


class AssetDependent(BaseModel):
    asset_path: str
    name: str


class AssetsDeleteConflictResponse(BaseModel):
    dependents: list[AssetDependent]
