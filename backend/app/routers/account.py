"""Account management endpoints — credits, usage history, API key rotation."""

import hashlib
import logging
import secrets

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import get_current_user
from app.models.db import User
from app.schemas.auth import (
    CreditsResponse,
    PlatformKeyResponse,
    UsageEventResponse,
    UsageListResponse,
)

router = APIRouter(tags=["account"])
logger = logging.getLogger(__name__)


@router.get("/me/credits", response_model=CreditsResponse)
def get_credits(current_user: User = Depends(get_current_user)) -> CreditsResponse:
    """
    Return the authenticated user's current credit balance and subscription tier.

    Called by the Flutter app on home screen load to populate the credit pill
    and on settings screen load.
    """
    return CreditsResponse(
        credits=current_user.credit_balance,
        tier=current_user.tier,
    )


@router.get("/usage", response_model=UsageListResponse)
def get_usage(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UsageListResponse:
    """
    Return the authenticated user's generation event history (FEAT-024).

    Events are returned newest-first. The Flutter app uses this to render
    the Usage Dashboard screen.
    """
    events = (
        current_user.usage_events
        if current_user.usage_events
        else []
    )
    # Sort newest first; usage_events are lazy-loaded so we sort in Python.
    sorted_events = sorted(events, key=lambda e: e.timestamp, reverse=True)
    return UsageListResponse(
        events=[
            UsageEventResponse(
                endpoint=e.endpoint,
                provider=e.provider,
                credits_deducted=e.credits_deducted,
                status=e.status,
                timestamp=e.timestamp.isoformat(),
            )
            for e in sorted_events
        ]
    )


@router.post("/keys/regenerate", response_model=PlatformKeyResponse)
def regenerate_key(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> PlatformKeyResponse:
    """
    Rotate the authenticated user's platform API key (FEAT-025).

    Issues a new key, hashes it, replaces the old hash in the database, and
    returns the raw key to the app. The old key is immediately invalidated.
    Use this if a platform key is compromised.
    """
    raw = secrets.token_hex(32)
    current_user.platform_api_key = hashlib.sha256(raw.encode()).hexdigest()
    db.commit()
    logger.info("Platform key rotated: user_id=%s", current_user.id)
    return PlatformKeyResponse(platform_api_key=raw)
