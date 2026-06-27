"""Auth endpoints — FEAT-001 (register) and FEAT-002 (login).

Both endpoints receive a Firebase ID token in the Authorization header.
Firebase is the source of truth for identity; ArkMask issues a separate
platform API key used for billing and generation request attribution.

Key lifecycle:
  - Registration: one key issued, returned once, hashed in DB.
  - Login: a new key is issued and replaces the old hash (rotation on login).
    This means the most recently logged-in device holds the valid key.
    This is intentional for MVP single-device use.
"""

import hashlib
import logging
import secrets

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import get_firebase_uid
from app.models.db import User
from app.schemas.auth import PlatformKeyResponse, RegisterRequest

router = APIRouter(tags=["auth"])
logger = logging.getLogger(__name__)

# Free tier starts with 100 credits.
FREE_TIER_CREDITS = 100


def _generate_platform_key() -> tuple[str, str]:
    """Return (raw_key, hashed_key). Raw key is 64 hex chars (256-bit entropy)."""
    raw = secrets.token_hex(32)
    hashed = hashlib.sha256(raw.encode()).hexdigest()
    return raw, hashed


@router.post("/register", response_model=PlatformKeyResponse, status_code=status.HTTP_201_CREATED)
def register(
    body: RegisterRequest,
    firebase_uid: str = Depends(get_firebase_uid),
    db: Session = Depends(get_db),
) -> PlatformKeyResponse:
    """
    Register a new ArkMask account.

    Verifies the Firebase ID token, creates a user record in Cloud SQL,
    issues a platform API key, and returns it to the app.

    The raw key is returned exactly once — it is hashed before storage.
    The app must store it in Flutter secure storage immediately.

    Returns 409 Conflict if the Firebase UID or email is already registered.
    """
    # Guard: existing Firebase UID (e.g. user already registered from another device).
    existing = db.query(User).filter(User.firebase_uid == firebase_uid).first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account is already registered with this Firebase account.",
        )

    # Guard: duplicate email (belt-and-suspenders; Firebase Auth also prevents this).
    if db.query(User).filter(User.email == str(body.email)).first():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account with this email already exists.",
        )

    raw_key, hashed_key = _generate_platform_key()
    user = User(
        email=str(body.email),
        firebase_uid=firebase_uid,
        platform_api_key=hashed_key,
        tier="free",
        credit_balance=FREE_TIER_CREDITS,
    )
    db.add(user)
    db.commit()

    # Log registration event without any PII beyond the internal user_id.
    logger.info("User registered: user_id=%s", user.id)

    return PlatformKeyResponse(platform_api_key=raw_key)


@router.post("/login", response_model=PlatformKeyResponse)
def login(
    firebase_uid: str = Depends(get_firebase_uid),
    db: Session = Depends(get_db),
) -> PlatformKeyResponse:
    """
    Authenticate a returning user and issue a fresh platform API key.

    The previous key hash is replaced — this is a rotation-on-login model.
    Only the device that most recently logged in can use generation endpoints.

    Returns 401 if the Firebase UID does not match any registered user.
    """
    user = db.query(User).filter(User.firebase_uid == firebase_uid).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No ArkMask account found for this Firebase account. "
                   "Please register first.",
        )

    raw_key, hashed_key = _generate_platform_key()
    user.platform_api_key = hashed_key
    db.commit()

    logger.info("User logged in: user_id=%s", user.id)

    return PlatformKeyResponse(platform_api_key=raw_key)
