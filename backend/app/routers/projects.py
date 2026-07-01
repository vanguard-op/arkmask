"""Project management endpoints — FEAT-004 (create), FEAT-007 (delete),
FEAT-027 (storage summary), FEAT-028 (rename).

All endpoints require:
  X-Platform-Key  — validated by `get_current_user` (billing identity)
  Authorization   — Firebase ID token (Bearer <token>) for Firestore writes

Project identity:
  - `display_name` is the user-visible name (mutable).
  - `slug` is an immutable identifier generated once at creation: a URL-safe
    lowercase slug derived from the display name + 6-char random hex suffix.
    Used as the Firestore document ID and GCS folder prefix. Never changes.

Firestore path: `users/{firebase_uid}/projects/{slug}`
GCS prefix:     `{firebase_uid}/{slug}/`
"""

import logging
import re
import secrets

from fastapi import APIRouter, Depends, HTTPException, status
from firebase_admin import firestore
from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from pydantic import BaseModel, Field

from app.dependencies import get_current_user
from app.models.user import UserProfile
from app.services.firebase import _ensure_initialized
from app.services.media_store import MediaStore

router = APIRouter(tags=["projects"])
logger = logging.getLogger(__name__)


# ── Firestore client helper ───────────────────────────────────────────────────

def _firestore_client():
    """Return a Firestore client, ensuring Firebase Admin is initialised."""
    _ensure_initialized()
    return firestore.client()


# ── Slug generation ───────────────────────────────────────────────────────────

def _make_slug(display_name: str) -> str:
    """
    Derive a URL-safe slug from a display name.

    Converts to lowercase, replaces non-alphanumeric characters with hyphens,
    collapses consecutive hyphens, strips leading/trailing hyphens, then
    appends a 6-character random hex suffix to guarantee uniqueness.

    Example: "My Project!" → "my-project-3f9a1c"
    """
    base = display_name.lower()
    base = re.sub(r"[^a-z0-9]+", "-", base)
    base = base.strip("-")[:40]  # cap at 40 chars before the suffix
    base = base or "project"     # fallback if name was all special chars
    suffix = secrets.token_hex(3)  # 6 hex chars
    return f"{base}-{suffix}"


# ── Schemas ───────────────────────────────────────────────────────────────────

_DEFAULT_ART_STYLE = "painterly illustration with clean lines and rich color"


class GenerationSettingsInput(BaseModel):
    """Project-level generation settings that control image and video prompt style.

    ``art_style`` is injected into both image-prompt (rendering style) and
    video-prompt (closing block art style) by the generation router.
    ``video_subtitles`` controls whether the subtitle-free constraint is included
    in video prompts.
    """

    art_style: str = Field(
        default=_DEFAULT_ART_STYLE,
        min_length=1,
        max_length=200,
        description="Visual rendering style applied to image and video generation.",
    )
    video_subtitles: bool = Field(
        default=False,
        description="When True, subtitle syntax (【】) is allowed in video prompts.",
    )


class CreateProjectRequest(BaseModel):
    display_name: str = Field(..., min_length=1, max_length=60)
    generation_settings: GenerationSettingsInput = Field(
        default_factory=GenerationSettingsInput,
        description="Initial generation settings. Defaults applied if omitted.",
    )


class CreateProjectResponse(BaseModel):
    slug: str
    display_name: str


class RenameProjectRequest(BaseModel):
    display_name: str = Field(..., min_length=1, max_length=60)


class ProjectStorageSummaryResponse(BaseModel):
    slug: str
    total_bytes: int
    images_bytes: int
    videos_bytes: int
    export_bytes: int


# ── POST /projects ─────────────────────────────────────────────────────────────

@router.post(
    "/projects",
    response_model=CreateProjectResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_project(
    body: CreateProjectRequest,
    current_user: UserProfile = Depends(get_current_user),
) -> CreateProjectResponse:
    """
    Create a new project (FEAT-004).

    Generates an immutable slug, writes the Firestore root document at
    `users/{firebase_uid}/projects/{slug}`, and returns the slug.

    The Cloud SQL `projects` table is not used in the current schema — Firestore
    is the source of truth for project documents. The platform API key validates
    the billing identity; firebase_uid is read from the User row in Cloud SQL
    (populated at registration via the Firebase token).

    Returns 409 if a project with the same display_name already exists for this
    user (checked against the Firestore collection).
    """
    firebase_uid = current_user.firebase_uid
    db_client = _firestore_client()
    projects_ref = db_client.collection(f"users/{firebase_uid}/projects")

    # Check for duplicate display_name within this user's project collection.
    existing = projects_ref.where("display_name", "==", body.display_name).limit(1).get()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A project named '{body.display_name}' already exists.",
        )

    slug = _make_slug(body.display_name)

    # Write the Firestore project root document.
    project_doc = {
        "display_name": body.display_name,
        "story_content": "",
        "scene_count": 0,
        "completed_scene_count": 0,
        "gcs_final_path": None,
        "generation_settings": {
            "art_style": body.generation_settings.art_style,
            "video_subtitles": body.generation_settings.video_subtitles,
        },
        "created_at": SERVER_TIMESTAMP,
        "updated_at": SERVER_TIMESTAMP,
    }
    projects_ref.document(slug).set(project_doc)

    logger.info(
        "Project created: user_id=%s slug=%s display_name=%r",
        current_user.id,
        slug,
        body.display_name,
    )

    return CreateProjectResponse(slug=slug, display_name=body.display_name)


# ── DELETE /projects/{slug} ────────────────────────────────────────────────────

@router.delete(
    "/projects/{slug}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def delete_project(
    slug: str,
    current_user: UserProfile = Depends(get_current_user),
) -> None:
    """
    Delete a project and all its generated media (FEAT-007).

    Deletes:
      1. All GCS objects under `{firebase_uid}/{slug}/`
      2. All Firestore documents under `users/{firebase_uid}/projects/{slug}`
         recursively (scenes, assets, scene-local assets)

    Returns 404 if the project document does not exist (idempotent-ish —
    GCS delete is attempted regardless).
    """
    firebase_uid = current_user.firebase_uid
    db_client = _firestore_client()
    project_ref = db_client.document(f"users/{firebase_uid}/projects/{slug}")

    # Verify the project exists and belongs to this user.
    if not project_ref.get().exists:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Project '{slug}' not found.",
        )

    # ── 1. Delete GCS objects ──────────────────────────────────────────────────
    try:
        store = MediaStore()
        store.delete_prefix(f"{firebase_uid}/{slug}/")
    except Exception as exc:
        # Log but don't abort — Firestore cleanup should still proceed.
        logger.warning(
            "GCS prefix delete failed for %s/%s: %s", firebase_uid, slug, exc
        )

    # ── 2. Delete Firestore documents recursively ──────────────────────────────
    # Firestore does not delete subcollections automatically; we must walk them.
    _delete_firestore_subtree(db_client, project_ref)

    logger.info(
        "Project deleted: user_id=%s slug=%s", current_user.id, slug
    )


def _delete_firestore_subtree(db_client, doc_ref) -> None:
    """
    Recursively delete a Firestore document and all its subcollections.

    Firestore batch writes are limited to 500 operations — this implementation
    deletes documents in batches to avoid hitting the limit on large projects.
    """
    batch = db_client.batch()
    batch_count = 0

    def _delete_doc(ref):
        nonlocal batch, batch_count
        # Delete all subcollections first (depth-first).
        for sub_col in ref.collections():
            for sub_doc in sub_col.stream():
                _delete_doc(sub_doc.reference)

        batch.delete(ref)
        batch_count += 1

        # Commit and start a fresh batch every 490 operations (safe margin).
        if batch_count >= 490:
            batch.commit()
            batch = db_client.batch()
            batch_count = 0

    _delete_doc(doc_ref)

    if batch_count > 0:
        batch.commit()


# ── PATCH /projects/{slug} ─────────────────────────────────────────────────────

@router.patch(
    "/projects/{slug}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def rename_project(
    slug: str,
    body: RenameProjectRequest,
    current_user: UserProfile = Depends(get_current_user),
) -> None:
    """
    Rename a project's display name (FEAT-028).

    Updates only `display_name` and `updated_at` in the Firestore document.
    The slug, GCS folder, and all generated media are unaffected.

    Returns 404 if the project does not exist.
    Returns 409 if the new name conflicts with another project's display_name.
    """
    firebase_uid = current_user.firebase_uid
    db_client = _firestore_client()
    projects_ref = db_client.collection(f"users/{firebase_uid}/projects")
    project_ref = projects_ref.document(slug)

    if not project_ref.get().exists:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Project '{slug}' not found.",
        )

    # Check for name conflict (exclude this document).
    existing = projects_ref.where("display_name", "==", body.display_name).limit(1).get()
    if existing and existing[0].id != slug:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A project named '{body.display_name}' already exists.",
        )

    project_ref.update({
        "display_name": body.display_name,
        "updated_at": SERVER_TIMESTAMP,
    })

    logger.info(
        "Project renamed: user_id=%s slug=%s new_name=%r",
        current_user.id, slug, body.display_name,
    )


# ── PATCH /projects/{slug}/settings ───────────────────────────────────────────

@router.patch(
    "/projects/{slug}/settings",
    status_code=status.HTTP_204_NO_CONTENT,
)
def update_project_settings(
    slug: str,
    body: GenerationSettingsInput,
    current_user: UserProfile = Depends(get_current_user),
) -> None:
    """
    Update the generation settings for a project.

    Writes ``generation_settings.art_style`` and
    ``generation_settings.video_subtitles`` to the Firestore project document.
    The backend reads these values when ``/image-prompt`` and ``/video-prompt``
    are called — the mobile API request bodies are unaffected.

    Returns 404 if the project does not exist.
    """
    firebase_uid = current_user.firebase_uid
    db_client = _firestore_client()
    project_ref = db_client.document(f"users/{firebase_uid}/projects/{slug}")

    if not project_ref.get().exists:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Project '{slug}' not found.",
        )

    project_ref.update({
        "generation_settings": {
            "art_style": body.art_style,
            "video_subtitles": body.video_subtitles,
        },
        "updated_at": SERVER_TIMESTAMP,
    })

    logger.info(
        "Project settings updated: user_id=%s slug=%s art_style=%r subtitles=%s",
        current_user.id, slug, body.art_style, body.video_subtitles,
    )


# ── GET /projects/{slug}/storage ──────────────────────────────────────────────

@router.get(
    "/projects/{slug}/storage",
    response_model=ProjectStorageSummaryResponse,
)
def get_project_storage(
    slug: str,
    current_user: UserProfile = Depends(get_current_user),
) -> ProjectStorageSummaryResponse:
    """
    Return the GCS storage summary for a project (FEAT-027).

    Sums object sizes under `{firebase_uid}/{slug}/` and categorises them:
      - images_bytes: all `image.png` objects
      - videos_bytes: all `video.mp4` objects (scene clips)
      - export_bytes: `final.mp4`

    Returns zeros for all categories if the project has no generated media yet.
    """
    # Verify the project exists.
    firebase_uid = current_user.firebase_uid
    db_client = _firestore_client()
    project_ref = db_client.document(f"users/{firebase_uid}/projects/{slug}")
    if not project_ref.get().exists:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Project '{slug}' not found.",
        )

    try:
        store = MediaStore()
        summary = store.get_storage_summary(
            prefix=f"{firebase_uid}/{slug}/",
        )
    except Exception as exc:
        logger.warning(
            "Storage summary failed for %s/%s: %s", firebase_uid, slug, exc
        )
        # Return zeros rather than failing the request — non-blocking for the UI.
        return ProjectStorageSummaryResponse(
            slug=slug,
            total_bytes=0,
            images_bytes=0,
            videos_bytes=0,
            export_bytes=0,
        )

    return ProjectStorageSummaryResponse(
        slug=slug,
        total_bytes=summary["total_bytes"],
        images_bytes=summary["images_bytes"],
        videos_bytes=summary["videos_bytes"],
        export_bytes=summary["export_bytes"],
    )
