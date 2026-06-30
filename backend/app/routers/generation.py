"""Generation endpoints — Phase 2+ cloud architecture.

Contract:
  POST /assets          — synchronous; returns extracted asset list
  POST /image-prompt    — synchronous; writes prompt_body to Firestore; returns 204
  POST /image           — async; returns {job_id}; worker writes gcs_image_path to Firestore
  POST /video-prompt    — synchronous; fetches ref images from GCS; writes storyboard_body to Firestore; returns 204
  POST /video           — async; returns {job_id}; worker writes gcs_video_path to Firestore
  POST /merge           — async; returns {job_id}; worker writes gcs_final_path to Firestore
  GET  /job/{id}/status — returns job status + presigned URL on success
  POST /media/presigned-url — returns fresh presigned URL for any GCS path

All endpoints:
  - Require X-Platform-Key (get_current_user)
  - Generation endpoints also need X-Provider-Type + X-Provider-Key (get_ai_provider)
  - firebase_uid comes from current_user.firebase_uid (already in DB — no extra token needed)

NOTE: /merge requires FFmpeg to be installed on the server (ffmpeg binary in PATH).

SECURITY: X-Provider-Key must NEVER appear in any log statement.
"""

import asyncio
import logging
import subprocess
import tempfile
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, status
from firebase_admin import firestore
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import get_ai_provider, get_current_user
from app.models.db import Job, UsageEvent, User
from app.routers.projects import _firestore_client
from app.schemas.generation import (
    AssetsRequest,
    AssetsResponse,
    AssetItem,
    VideoEnqueueResponse,
    VideoStatusEnum,
    VideoStatusResponse,
)
from app.services.ai.base import AIProvider, RefImage
from app.services.firebase import send_fcm_notification
from app.services.media_store import MediaStore

router = APIRouter(tags=["generation"])
logger = logging.getLogger(__name__)

CREDIT_COSTS: dict[str, int] = {
    "/assets": 1,
    "/image-prompt": 1,
    "/video-prompt": 3,
    "/image": 5,
    "/video": 20,
    "/merge": 5,
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


class VideoPromptCloudRequest(BaseModel):
    project_slug: str
    scene_index: int
    scene: str
    ref_image_gcs_paths: list[str] = Field(default_factory=list)


class VideoEnqueueCloudRequest(BaseModel):
    project_slug: str
    scene_index: int
    ref_image_gcs_paths: list[str] = Field(default_factory=list)


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

def _check_credits(user: User, endpoint: str) -> int:
    cost = CREDIT_COSTS.get(endpoint, 0)
    if user.credit_balance < cost:
        raise HTTPException(
            status_code=402,
            detail=f"Insufficient credits. Required: {cost}, Available: {user.credit_balance}.",
        )
    return cost


def _deduct_credits(
    db: Session,
    user: User,
    endpoint: str,
    provider: str,
    credits: int,
    evt_status: str = "success",
) -> None:
    event = UsageEvent(
        user_id=user.id,
        endpoint=endpoint,
        provider=provider,
        credits_deducted=credits,
        status=evt_status,
    )
    db.add(event)
    if credits > 0:
        user.credit_balance = User.credit_balance - credits
    db.commit()


def _provider_name(provider: AIProvider) -> str:
    return type(provider).__name__.replace("Provider", "").lower()


def _create_job(
    db: Session,
    user: User,
    job_type: str,
    project_slug: str,
    scene_index: int | None = None,
    asset_path: str | None = None,
) -> Job:
    """Create a Job record in DB with status='pending' and return it."""
    job = Job(
        id=str(uuid.uuid4()),
        user_id=user.id,
        type=job_type,
        status="pending",
        project_slug=project_slug,
        scene_index=scene_index,
        asset_path=asset_path,
    )
    db.add(job)
    db.commit()
    db.refresh(job)
    return job


def _update_job(
    db: Session,
    job_id: str,
    status: str,
    gcs_output_path: str | None = None,
    error_message: str | None = None,
) -> None:
    """Update job status and optional output path."""
    db.query(Job).filter(Job.id == job_id).update({
        "status": status,
        "gcs_output_path": gcs_output_path,
        "error_message": error_message,
    })
    db.commit()


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


def _sniff_mime(data: bytes) -> str:
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return "image/png"
    if data[:3] == b'\xff\xd8\xff':
        return "image/jpeg"
    return "image/png"  # safe default


# ── POST /assets ──────────────────────────────────────────────────────────────

@router.post("/assets", response_model=AssetsResponse)
def extract_assets(
    body: AssetsRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> AssetsResponse:
    """
    Extract visual assets from a story — returns structured asset list.
    Credits deducted: 1 (on success only).
    """
    cost = _check_credits(user, "/assets")
    pname = _provider_name(provider)
    try:
        raw = provider.generate_asset_list(body.story)
    except Exception as e:
        logger.error("Asset extraction failed: user_id=%s", user.id, exc_info=True)
        _deduct_credits(db, user, "/assets", pname, 0, "refunded")
        raise HTTPException(502, "AI provider error during asset extraction.")
    _deduct_credits(db, user, "/assets", pname, cost)
    return AssetsResponse(assets=[AssetItem(**a) for a in raw])


# ── POST /image-prompt ────────────────────────────────────────────────────────

@router.post("/image-prompt", status_code=status.HTTP_204_NO_CONTENT)
def generate_image_prompt(
    body: ImagePromptCloudRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> None:
    """
    Generate an image prompt and write it to Firestore as prompt_body.
    Credits deducted: 1 (on success only). Returns 204.
    """
    cost = _check_credits(user, "/image-prompt")
    pname = _provider_name(provider)

    # Read generation_settings from the Firestore project document.
    # Falls back to the provider default if the field is absent (older projects).
    _default_art_style = "painterly illustration with clean lines and rich color"
    try:
        proj_fs_path = f"users/{user.firebase_uid}/projects/{body.project_slug}"
        proj_doc = _firestore_client().document(proj_fs_path).get()
        gen_settings: dict = (proj_doc.get("generation_settings") or {}) if proj_doc.exists else {}
    except Exception:
        logger.warning("image-prompt: could not fetch generation_settings for %s", body.project_slug)
        gen_settings = {}
    art_style: str = gen_settings.get("art_style") or _default_art_style

    try:
        prompt = provider.generate_image_prompt(body.name, body.type, body.description, art_style=art_style)
    except Exception as e:
        logger.error("image-prompt failed: user_id=%s", user.id, exc_info=True)
        _deduct_credits(db, user, "/image-prompt", pname, 0, "refunded")
        raise HTTPException(502, "AI provider error during prompt generation.")

    fs_path = f"users/{user.firebase_uid}/projects/{body.project_slug}/{body.asset_path}"
    try:
        _firestore_client().document(fs_path).set(
            {"prompt_body": prompt, "updated_at": SERVER_TIMESTAMP},
            merge=True,
        )
    except Exception as e:
        logger.error("Firestore write failed for image-prompt: path=%s error=%s", fs_path, e)
        raise HTTPException(502, "Failed to save prompt to project.")

    _deduct_credits(db, user, "/image-prompt", pname, cost)


# ── POST /image ───────────────────────────────────────────────────────────────

@router.post("/image", response_model=VideoEnqueueResponse)
async def enqueue_image(
    body: ImageEnqueueRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> VideoEnqueueResponse:
    """
    Enqueue an image generation job. Returns job_id immediately.
    Worker reads prompt_body from Firestore, generates image, writes gcs_image_path.
    Credits deducted: 5 (on terminal success only).
    """
    _check_credits(user, "/image")
    job = _create_job(db, user, "image", body.project_slug, asset_path=body.asset_path)

    firebase_uid = user.firebase_uid
    job_id = job.id
    pname = _provider_name(provider)
    user_id = user.id

    async def _run():
        from app.database import SessionLocal
        bg_db = SessionLocal()
        try:
            _update_job(bg_db, job_id, "running")

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
                    logger.warning(
                        "Could not fetch conditioning image %s: %s",
                        body.conditioning_gcs_path, e,
                    )

            # 3. Generate image via AI provider.
            img_bytes, mime_type = await asyncio.to_thread(
                provider.generate_image, prompt, ref_images
            )

            # 4. Save to GCS at deterministic path.
            gcs_key = f"{firebase_uid}/{body.project_slug}/{body.asset_path}/image.png"
            store = MediaStore()
            await asyncio.to_thread(store.put_object, gcs_key, img_bytes, mime_type)

            # 5. Write gcs_image_path to Firestore asset doc.
            _firestore_client().document(fs_path).set(
                {"gcs_image_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            # 6. Deduct credits.
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            if db_user:
                _deduct_credits(bg_db, db_user, "/image", pname, CREDIT_COSTS["/image"])

            # 7. Update job status.
            _update_job(bg_db, job_id, "success", gcs_output_path=gcs_key)

            # 8. Send FCM push.
            db_user = db_user or bg_db.query(User).filter(User.id == user_id).first()
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "image",
                "project_id": body.project_slug,
                "status": "completed",
                "asset_path": body.asset_path or "",
            })
            logger.info("Image job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Image job failed: job_id=%s error=%s", job_id, e, exc_info=True)
            _update_job(bg_db, job_id, "failed", error_message=str(e)[:1024])
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "image",
                "project_id": body.project_slug,
                "status": "failed",
            })
        finally:
            bg_db.close()

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /video-prompt ────────────────────────────────────────────────────────

@router.post("/video-prompt", status_code=status.HTTP_204_NO_CONTENT)
def generate_video_prompt(
    body: VideoPromptCloudRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> None:
    """
    Generate a scene storyboard and write it to Firestore as storyboard_body.
    Fetches reference images from GCS synchronously before calling the AI provider.
    Credits deducted: 3 (on success only). Returns 204.
    """
    cost = _check_credits(user, "/video-prompt")
    pname = _provider_name(provider)

    # Read generation_settings from the Firestore project document.
    # Falls back to provider defaults if the field is absent (older projects).
    _default_art_style = "painterly illustration with clean lines and rich color"
    try:
        proj_fs_path = f"users/{user.firebase_uid}/projects/{body.project_slug}"
        proj_doc = _firestore_client().document(proj_fs_path).get()
        gen_settings: dict = (proj_doc.get("generation_settings") or {}) if proj_doc.exists else {}
    except Exception:
        logger.warning("video-prompt: could not fetch generation_settings for %s", body.project_slug)
        gen_settings = {}
    art_style: str = gen_settings.get("art_style") or _default_art_style
    subtitles: bool = bool(gen_settings.get("video_subtitles", False))

    # Fetch reference images from GCS synchronously.
    ref_images = _fetch_gcs_images(body.ref_image_gcs_paths)

    try:
        storyboard = provider.generate_video_prompt(body.scene, ref_images, art_style=art_style, subtitles=subtitles)
    except Exception as e:
        logger.error("video-prompt failed: user_id=%s", user.id, exc_info=True)
        _deduct_credits(db, user, "/video-prompt", pname, 0, "refunded")
        raise HTTPException(502, "AI provider error during storyboard generation.")

    fs_path = f"users/{user.firebase_uid}/projects/{body.project_slug}/scenes/{body.scene_index}"
    try:
        _firestore_client().document(fs_path).set(
            {
                "storyboard_body": storyboard,
                "scene_number": body.scene_index,
                "updated_at": SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception as e:
        logger.error("Firestore write failed for video-prompt: path=%s", fs_path, exc_info=True)
        raise HTTPException(502, "Failed to save storyboard to project.")

    _deduct_credits(db, user, "/video-prompt", pname, cost)


# ── POST /video ───────────────────────────────────────────────────────────────

@router.post("/video", response_model=VideoEnqueueResponse)
async def enqueue_video(
    body: VideoEnqueueCloudRequest,
    user: User = Depends(get_current_user),
    provider: AIProvider = Depends(get_ai_provider),
    db: Session = Depends(get_db),
) -> VideoEnqueueResponse:
    """
    Enqueue a video generation job. Returns job_id immediately.
    Worker reads storyboard_body from Firestore, fetches ref images, generates video.
    Credits deducted: 20 (on terminal success only).
    """
    _check_credits(user, "/video")
    job = _create_job(db, user, "video", body.project_slug, scene_index=body.scene_index)

    firebase_uid = user.firebase_uid
    job_id = job.id
    pname = _provider_name(provider)
    user_id = user.id

    async def _run():
        from app.database import SessionLocal
        bg_db = SessionLocal()
        try:
            _update_job(bg_db, job_id, "running")

            # 1. Read storyboard_body from Firestore.
            fs_path = (
                f"users/{firebase_uid}/projects/{body.project_slug}"
                f"/scenes/{body.scene_index}"
            )
            doc = _firestore_client().document(fs_path).get()
            storyboard = (doc.get("storyboard_body") or "") if doc.exists else ""
            if not storyboard:
                raise ValueError(
                    "Scene has no storyboard_body — generate a storyboard first."
                )

            # 2. Fetch reference images from GCS.
            ref_images = _fetch_gcs_images(body.ref_image_gcs_paths)

            # 3. Generate video via AI provider (long-running, runs in thread).
            video_bytes, mime_type = await asyncio.to_thread(
                provider.generate_video, storyboard, ref_images
            )

            # 4. Save to GCS at deterministic path.
            gcs_key = (
                f"{firebase_uid}/{body.project_slug}"
                f"/scenes/{body.scene_index}/video.mp4"
            )
            store = MediaStore()
            await asyncio.to_thread(store.put_object, gcs_key, video_bytes, mime_type)

            # 5. Write gcs_video_path to Firestore scene doc.
            _firestore_client().document(fs_path).set(
                {"gcs_video_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            # 6. Deduct credits + update job.
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            if db_user:
                _deduct_credits(bg_db, db_user, "/video", pname, CREDIT_COSTS["/video"])
            _update_job(bg_db, job_id, "success", gcs_output_path=gcs_key)

            # 7. Send FCM push.
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "video",
                "project_id": body.project_slug,
                "scene_index": str(body.scene_index),
                "status": "completed",
            })
            logger.info("Video job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Video job failed: job_id=%s", job_id, exc_info=True)
            _update_job(bg_db, job_id, "failed", error_message=str(e)[:1024])
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "video",
                "project_id": body.project_slug,
                "status": "failed",
            })
        finally:
            bg_db.close()

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


# ── POST /merge ───────────────────────────────────────────────────────────────

@router.post("/merge", response_model=VideoEnqueueResponse)
async def enqueue_merge(
    body: MergeRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> VideoEnqueueResponse:
    """
    Enqueue a video merge job. Returns job_id immediately.
    Worker downloads scene videos from GCS, runs FFmpeg with trims + transitions,
    uploads final.mp4 to GCS, writes gcs_final_path to Firestore project doc.
    Credits deducted: 5 (on terminal success only).
    NOTE: Requires ffmpeg binary in PATH on the server.
    """
    _check_credits(user, "/merge")
    job = _create_job(db, user, "merge", body.project_slug)

    firebase_uid = user.firebase_uid
    job_id = job.id
    user_id = user.id

    async def _run():
        from app.database import SessionLocal
        bg_db = SessionLocal()
        try:
            _update_job(bg_db, job_id, "running")
            store = MediaStore()

            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                clip_files: list[tuple[Path, SceneMergeEntry]] = []

                # 1. Download each scene video from GCS to temp dir.
                for entry in body.scenes:
                    gcs_key = (
                        f"{firebase_uid}/{body.project_slug}"
                        f"/scenes/{entry.scene_index}/video.mp4"
                    )
                    try:
                        data = await asyncio.to_thread(store.get_object_bytes, gcs_key)
                    except Exception as e:
                        raise ValueError(
                            f"Could not fetch video for scene {entry.scene_index}: {e}"
                        )
                    clip_path = tmp_path / f"scene_{entry.scene_index:04d}.mp4"
                    clip_path.write_bytes(data)
                    clip_files.append((clip_path, entry))

                # 2. Run FFmpeg to apply trims + transitions.
                final_path = tmp_path / "final.mp4"
                await asyncio.to_thread(_run_ffmpeg_merge, clip_files, final_path)

                # 3. Upload final.mp4 to GCS.
                gcs_key = f"{firebase_uid}/{body.project_slug}/final.mp4"
                final_bytes = final_path.read_bytes()
                await asyncio.to_thread(
                    store.put_object, gcs_key, final_bytes, "video/mp4"
                )

            # 4. Write gcs_final_path to Firestore project root doc.
            fs_path = f"users/{firebase_uid}/projects/{body.project_slug}"
            _firestore_client().document(fs_path).set(
                {"gcs_final_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
                merge=True,
            )

            # 5. Deduct credits + update job.
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            if db_user:
                _deduct_credits(
                    bg_db, db_user, "/merge", "server", CREDIT_COSTS["/merge"]
                )
            _update_job(bg_db, job_id, "success", gcs_output_path=gcs_key)

            # 6. Send FCM push.
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "merge",
                "project_id": body.project_slug,
                "status": "completed",
            })
            logger.info("Merge job complete: job_id=%s", job_id)
        except Exception as e:
            logger.error("Merge job failed: job_id=%s", job_id, exc_info=True)
            _update_job(bg_db, job_id, "failed", error_message=str(e)[:1024])
            db_user = bg_db.query(User).filter(User.id == user_id).first()
            send_fcm_notification(db_user.fcm_token if db_user else None, {
                "job_id": job_id,
                "type": "merge",
                "project_id": body.project_slug,
                "status": "failed",
            })
        finally:
            bg_db.close()

    asyncio.create_task(_run())
    return VideoEnqueueResponse(job_id=job_id)


def _run_ffmpeg_merge(
    clip_files: list[tuple[Path, SceneMergeEntry]],
    output: Path,
) -> None:
    """
    Run FFmpeg to trim clips and concatenate with transitions.

    Strategy:
    - For hard_cut-only timelines: use the concat demuxer (fast, no full re-encode).
    - For fade_black / dissolve transitions: use filter_complex with xfade.

    Requires ffmpeg binary in PATH on the server.
    """
    if not clip_files:
        raise ValueError("No clips to merge.")

    all_hard_cut = all(
        entry.transition_to_next == "hard_cut"
        for _, entry in clip_files[:-1]
    )

    if all_hard_cut or len(clip_files) == 1:
        # Fast path: concat demuxer (minimal re-encode).
        concat_list = output.parent / "concat.txt"
        lines = []
        for clip_path, entry in clip_files:
            lines.append(f"file '{clip_path}'")
            lines.append(f"inpoint {entry.trim_in}")
            lines.append(f"outpoint {entry.trim_out}")
        concat_list.write_text("\n".join(lines))
        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0", "-i", str(concat_list),
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            str(output),
        ]
    else:
        # Slow path: filter_complex with xfade for non-hard-cut transitions.
        inputs: list[str] = []
        for clip_path, _ in clip_files:
            inputs += ["-i", str(clip_path)]

        filter_parts: list[str] = []
        for i, (_, entry) in enumerate(clip_files):
            filter_parts.append(
                f"[{i}:v]trim=start={entry.trim_in}:end={entry.trim_out},"
                f"setpts=PTS-STARTPTS[v{i}];"
                f"[{i}:a]atrim=start={entry.trim_in}:end={entry.trim_out},"
                f"asetpts=PTS-STARTPTS[a{i}]"
            )

        prev_v, prev_a = "v0", "a0"
        for i in range(1, len(clip_files)):
            _, prev_entry = clip_files[i - 1]
            trans = prev_entry.transition_to_next
            xfade_type = {
                "fade_black": "fadeblack",
                "dissolve": "dissolve",
            }.get(trans, "fade")
            duration = 0.5
            offset = (prev_entry.trim_out - prev_entry.trim_in) - duration
            out_v = f"xfv{i}" if i < len(clip_files) - 1 else "vout"
            out_a = f"xfa{i}" if i < len(clip_files) - 1 else "aout"
            filter_parts.append(
                f"[{prev_v}][v{i}]xfade=transition={xfade_type}"
                f":duration={duration}:offset={offset}[{out_v}];"
                f"[{prev_a}][a{i}]acrossfade=d={duration}[{out_a}]"
            )
            prev_v, prev_a = out_v, out_a

        filter_complex = ";".join(filter_parts)
        cmd = [
            "ffmpeg", "-y",
            *inputs,
            "-filter_complex", filter_complex,
            "-map", f"[{prev_v}]", "-map", f"[{prev_a}]",
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            str(output),
        ]

    logger.info("FFmpeg command: %s ...", " ".join(cmd[:8]))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        logger.error("FFmpeg failed:\nstderr=%s", result.stderr[-2000:])
        raise RuntimeError(f"FFmpeg merge failed: {result.stderr[-500:]}")


# ── GET /job/{id}/status ──────────────────────────────────────────────────────

@router.get("/job/{job_id}/status", response_model=VideoStatusResponse)
def get_job_status(
    job_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> VideoStatusResponse:
    """
    Poll the status of any async generation job (image, video, merge).
    Returns a presigned URL when status = 'success'.
    """
    job = db.query(Job).filter(Job.id == job_id, Job.user_id == user.id).first()
    if job is None:
        raise HTTPException(404, f"Job '{job_id}' not found.")

    url = None
    if job.status == "success" and job.gcs_output_path:
        try:
            url = MediaStore().presign_path(job.gcs_output_path)
        except Exception:
            logger.warning("Could not generate presigned URL for job %s", job_id)

    return VideoStatusResponse(
        job_id=job_id,
        status=VideoStatusEnum(job.status),
        url=url,
        error=job.error_message,
    )


# ── POST /media/presigned-url ─────────────────────────────────────────────────

@router.post("/media/presigned-url", response_model=PresignedUrlResponse)
def get_presigned_url(
    body: PresignedUrlRequest,
    user: User = Depends(get_current_user),
) -> PresignedUrlResponse:
    """
    Generate a fresh presigned GET URL for any GCS object path owned by this user.

    Used by the Flutter app when a previously-cached presigned URL expires
    (VideoPlayerScreen expired URL refresh) and when the video editor loads
    clip thumbnails.

    Security: gcs_path must start with `{firebase_uid}/` — paths outside the
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
