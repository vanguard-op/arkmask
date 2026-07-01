"""Auth endpoints — FEAT-001 (register) and FEAT-002 (login).

Both endpoints receive a Firebase ID token in the Authorization header.
Firebase is the source of truth for identity; ArkMask issues a separate
platform API key used for billing and generation request attribution.

Firestore document layout:
  users/{uid}/profile     — user account data (tier, credits, fcm_token, …)
  api_keys/{hashed_key}   — reverse-index: hashed_key → firebase_uid (O(1) lookup)

Key lifecycle:
  - Registration: one key issued, returned once, written as hash.
  - Login: new key issued, old api_keys doc deleted, new one written.
    This rotation-on-login model ensures only the most recently
    logged-in device holds a valid key (intentional for MVP single-device use).
"""

import hashlib
import logging
import secrets

from fastapi import APIRouter, Depends, HTTPException, status
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.dependencies import _firestore, get_firebase_uid
from app.schemas.auth import PlatformKeyResponse, RegisterRequest

router = APIRouter(tags=["auth"])
logger = logging.getLogger(__name__)

# Free tier starts with 100 credits.
FREE_TIER_CREDITS = 100


def _generate_platform_key() -> tuple[str, str]:
    """Return (raw_key, hashed_key).  Raw key is 64 hex chars (256-bit entropy)."""
    raw = secrets.token_hex(32)
    hashed = hashlib.sha256(raw.encode()).hexdigest()
    return raw, hashed


@router.post("/register", response_model=PlatformKeyResponse, status_code=status.HTTP_201_CREATED)
def register(
    body: RegisterRequest,
    firebase_uid: str = Depends(get_firebase_uid),
) -> PlatformKeyResponse:
    """
    Register a new ArkMask account.

    Verifies the Firebase ID token, creates ``users/{uid}/profile`` in Firestore,
    writes the key hash to ``api_keys/{hashed_key}``, and returns the raw key.

    The raw key is returned exactly once — it is hashed before storage.
    The app must store it in Flutter secure storage immediately.

    Returns 409 Conflict if the Firebase UID is already registered.
    """
    db = _firestore()

    # Guard: existing Firebase UID (e.g. user already registered from another device).
    profile_ref = db.document(f"users/{firebase_uid}/profile")
    if profile_ref.get().exists:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account is already registered with this Firebase account.",
        )

    raw_key, hashed_key = _generate_platform_key()

    # Write the user profile document.
    profile_ref.set({
        "email": str(body.email),
        "tier": "free",
        "credit_balance": FREE_TIER_CREDITS,
        "stripe_customer_id": None,
        "fcm_token": None,
        "created_at": SERVER_TIMESTAMP,
        "updated_at": SERVER_TIMESTAMP,
    })

    # Write the reverse-index document for O(1) platform key lookup.
    db.collection("api_keys").document(hashed_key).set({
        "firebase_uid": firebase_uid,
        "created_at": SERVER_TIMESTAMP,
    })

    logger.info("User registered: uid=%s", firebase_uid)
    return PlatformKeyResponse(platform_api_key=raw_key)


@router.post("/login", response_model=PlatformKeyResponse)
def login(
    firebase_uid: str = Depends(get_firebase_uid),
) -> PlatformKeyResponse:
    """
    Authenticate a returning user and issue a fresh platform API key.

    Rotates the key:
      1. Reads the old hashed key from the profile document.
      2. Deletes the old ``api_keys/{old_hash}`` document.
      3. Writes a new ``api_keys/{new_hash}`` document.
      4. Updates ``users/{uid}/profile`` with the new hash.

    Returns 401 if no profile exists for this Firebase UID.
    """
    db = _firestore()
    profile_ref = db.document(f"users/{firebase_uid}/profile")
    profile_snap = profile_ref.get()

    if not profile_snap.exists:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No ArkMask account found for this Firebase account. "
                   "Please register first.",
        )

    profile_data: dict = profile_snap.to_dict() or {}
    old_hash: str | None = profile_data.get("platform_api_key_hash")

    raw_key, new_hash = _generate_platform_key()

    # Delete old api_keys document so the previous key is immediately invalidated.
    if old_hash:
        db.collection("api_keys").document(old_hash).delete()

    # Write new reverse-index document.
    db.collection("api_keys").document(new_hash).set({
        "firebase_uid": firebase_uid,
        "created_at": SERVER_TIMESTAMP,
    })

    # Persist the new hash on the profile (used on next login rotation).
    profile_ref.update({
        "platform_api_key_hash": new_hash,
        "updated_at": SERVER_TIMESTAMP,
    })

    logger.info("User logged in: uid=%s", firebase_uid)
    return PlatformKeyResponse(platform_api_key=raw_key)
