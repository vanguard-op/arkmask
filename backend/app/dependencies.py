"""FastAPI dependency functions.

Shared dependencies injected into route handlers via `Depends()`.
"""

import hashlib
import logging

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.db import User
from app.services.ai.base import AIProvider
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider
from app.services.firebase import verify_id_token

logger = logging.getLogger(__name__)


def _hash_key(raw_key: str) -> str:
    """SHA-256 hex digest of a platform API key for safe storage in DB."""
    return hashlib.sha256(raw_key.encode()).hexdigest()


# ── Firebase auth dependency ──────────────────────────────────────────────────

def get_firebase_uid(authorization: str = Header(...)) -> str:
    """
    Extract and verify the Firebase ID token from `Authorization: Bearer <token>`.

    Returns the Firebase UID from the verified token claims.
    Raises HTTP 401 on missing, malformed, or expired token.
    """
    if not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authorization header must be 'Bearer <firebase_id_token>'.",
        )
    id_token = authorization.removeprefix("Bearer ").strip()
    try:
        claims = verify_id_token(id_token)
        return claims["uid"]
    except Exception as e:
        # Log the exception type and message but never the token itself.
        logger.warning(
            "Firebase token verification failed: %s — %s",
            type(e).__name__,
            str(e),
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Firebase ID token is invalid or expired.",
        )


# ── Platform key auth dependency ──────────────────────────────────────────────

def get_current_user(
    x_platform_key: str = Header(..., alias="X-Platform-Key"),
    db: Session = Depends(get_db),
) -> User:
    """
    Validate `X-Platform-Key` and return the authenticated User.

    The header value is hashed and compared against the stored hash — the raw
    key is never stored in the database.

    Raises HTTP 401 if the key is missing or does not match any user.
    """
    key_hash = _hash_key(x_platform_key)
    user = db.query(User).filter(User.platform_api_key == key_hash).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired platform API key.",
        )
    return user


# ── AI provider dependency ────────────────────────────────────────────────────

def get_ai_provider(
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> AIProvider:
    """
    Instantiate the correct AI provider adapter from the request headers.

    `X-Provider-Key` is the user's own AI API key (BYOK). It is used in-flight
    only — never logged (the route handler must not log this header either),
    never written to the database.

    Raises HTTP 400 for an unrecognised provider type.
    """
    match x_provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=x_provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=x_provider_key)
        case _:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unknown provider type '{x_provider_type}'. "
                       "Supported values: gemini, byteplus.",
            )
