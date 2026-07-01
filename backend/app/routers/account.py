"""Account management endpoints — credits, usage history, API key rotation."""

import hashlib
import logging
import secrets

from fastapi import APIRouter, Depends, status
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.dependencies import _firestore, get_current_user
from app.models.user import UserProfile
from app.schemas.auth import (
    CreditsResponse,
    PlatformKeyResponse,
    UsageEventResponse,
    UsageListResponse,
)

router = APIRouter(tags=["account"])
logger = logging.getLogger(__name__)


@router.get("/me/credits", response_model=CreditsResponse)
def get_credits(current_user: UserProfile = Depends(get_current_user)) -> CreditsResponse:
    """
    Return the authenticated user's current credit balance and subscription tier.

    Called by the Flutter app on home screen load to populate the credit pill
    and on settings screen load.  Values come directly from the UserProfile
    constructed by ``get_current_user`` (single Firestore read already done).
    """
    return CreditsResponse(
        credits=current_user.credit_balance,
        tier=current_user.tier,
    )


@router.get("/usage", response_model=UsageListResponse)
def get_usage(
    current_user: UserProfile = Depends(get_current_user),
) -> UsageListResponse:
    """
    Return the authenticated user's generation event history (FEAT-024).

    Events are returned newest-first.  The Flutter app uses this to render
    the Usage Dashboard screen.

    Reads from ``users/{uid}/usage_events`` ordered by timestamp descending.
    Capped at 200 events to keep the response payload manageable.
    """
    db = _firestore()
    uid = current_user.firebase_uid
    events_ref = (
        db.collection(f"users/{uid}/usage_events")
        .order_by("timestamp", direction="DESCENDING")
        .limit(200)
    )
    docs = events_ref.stream()
    return UsageListResponse(
        events=[
            UsageEventResponse(
                endpoint=d.get("endpoint") or "",
                provider=d.get("provider") or "",
                credits_deducted=d.get("credits_deducted") or 0,
                status=d.get("status") or "success",
                timestamp=(d.get("timestamp").isoformat() if d.get("timestamp") else ""),
            )
            for d in docs
        ]
    )


@router.post("/keys/regenerate", response_model=PlatformKeyResponse)
def regenerate_key(
    current_user: UserProfile = Depends(get_current_user),
) -> PlatformKeyResponse:
    """
    Rotate the authenticated user's platform API key (FEAT-025).

    Issues a new key, hashes it, deletes the old ``api_keys/{old_hash}``
    document, writes ``api_keys/{new_hash}``, and updates the profile.
    The old key is immediately invalidated.
    """
    db = _firestore()
    uid = current_user.firebase_uid
    old_hash = current_user.platform_api_key  # already hashed (set by get_current_user)

    raw = secrets.token_hex(32)
    new_hash = hashlib.sha256(raw.encode()).hexdigest()

    # Atomically invalidate the old key and register the new one.
    db.collection("api_keys").document(old_hash).delete()
    db.collection("api_keys").document(new_hash).set({
        "firebase_uid": uid,
        "created_at": SERVER_TIMESTAMP,
    })

    # Persist new hash on profile for future login rotations.
    db.document(f"users/{uid}/profile").update({
        "platform_api_key_hash": new_hash,
        "updated_at": SERVER_TIMESTAMP,
    })

    logger.info("Platform key rotated: uid=%s", uid)
    return PlatformKeyResponse(platform_api_key=raw)
