"""FastAPI dependency functions.

Shared dependencies injected into route handlers via ``Depends()``.

Platform key lookup is O(1): the hashed key is the document ID in the
top-level ``api_keys`` Firestore collection, so no scan is needed.
"""

import hashlib
import logging

from fastapi import Depends, Header, HTTPException, status

from app.firestore_paths import profile_path
from app.models.user import UserProfile
from app.services.ai.base import AIProvider
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider
from app.services.firebase import _ensure_initialized, verify_id_token

logger = logging.getLogger(__name__)


def _hash_key(raw_key: str) -> str:
    """SHA-256 hex digest of a platform API key for safe storage in Firestore."""
    return hashlib.sha256(raw_key.encode()).hexdigest()


def _firestore():
    """Return a Firestore client, ensuring Firebase Admin is initialised."""
    from firebase_admin import firestore as _fs
    _ensure_initialized()
    return _fs.client()


# ── Firebase auth dependency ──────────────────────────────────────────────────

def get_firebase_uid(authorization: str = Header(...)) -> str:
    """
    Extract and verify the Firebase ID token from ``Authorization: Bearer <token>``.

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
) -> UserProfile:
    """
    Validate ``X-Platform-Key`` and return the authenticated UserProfile.

    Lookup path:
      1. Hash the raw key → document ID in ``api_keys/{hashed_key}``.
      2. Read ``firebase_uid`` from that document (O(1) get, no scan).
      3. Read the user's profile document (see app.firestore_paths.profile_path)
         to get the full user record.

    The raw key is never stored — only the SHA-256 hash.
    Raises HTTP 401 if the key is missing or does not match any user.
    """
    db = _firestore()
    key_hash = _hash_key(x_platform_key)

    # Step 1: resolve uid from hashed key (top-level collection — O(1) get).
    key_doc = db.collection("api_keys").document(key_hash).get()
    if not key_doc.exists:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired platform API key.",
        )
    uid: str = key_doc.get("firebase_uid")

    # Step 2: fetch the user profile document.
    profile_doc = db.document(profile_path(uid)).get()
    if not profile_doc.exists:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User profile not found.",
        )
    data: dict = profile_doc.to_dict() or {}
    return UserProfile(
        firebase_uid=uid,
        email=data.get("email", ""),
        tier=data.get("tier", "free"),
        credit_balance=data.get("credit_balance", 0),
        platform_api_key=key_hash,
        stripe_customer_id=data.get("stripe_customer_id"),
        fcm_token=data.get("fcm_token"),
    )


# ── AI provider dependency ────────────────────────────────────────────────────

def get_ai_provider(
    x_provider_type: str = Header(..., alias="X-Provider-Type"),
    x_provider_key: str = Header(..., alias="X-Provider-Key"),
) -> AIProvider:
    """
    Instantiate the correct AI provider adapter from the request headers.

    ``X-Provider-Key`` is the user's own AI API key (BYOK).  It is used
    in-flight only — never logged (the route handler must not log this header
    either), never written to the database.

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
