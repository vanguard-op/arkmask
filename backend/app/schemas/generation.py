"""Pydantic schemas for the five generation endpoints."""

from enum import Enum

from pydantic import BaseModel, Field


class AssetTypeEnum(str, Enum):
    CHARACTER = "character"
    BACKGROUND = "background"
    OBJECT = "object"


# ── POST /assets ──────────────────────────────────────────────────────────────

class AssetsRequest(BaseModel):
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

class AssetPrompt(BaseModel):
    """A single asset's name and its generated image prompt body."""
    name: str
    prompt: str


class VideoPromptRequest(BaseModel):
    """Input for /video-prompt — scene text and the asset prompts for that scene."""
    scene: str
    assets: list[AssetPrompt]


class VideoPromptResponse(BaseModel):
    storyboard: str


# ── POST /video (application/json) ────────────────────────────────────────────

class VideoRefImage(BaseModel):
    """A reference image sent as base64-encoded bytes with its MIME type.

    Pydantic v2 automatically decodes base64 strings to bytes when the field
    type is `bytes`, so the Flutter client just sends a base64 string.
    """
    data: bytes
    mime_type: str = "image/png"


class VideoRequest(BaseModel):
    """Input for /video — storyboard prompt and asset reference images."""
    prompt: str
    ref_images: list[VideoRefImage] = Field(default=[], min_length=1)


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
