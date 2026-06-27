"""Firebase Admin SDK — token verification and lazy initialisation.

Initialisation is deferred to first call so tests can run without valid
Firebase credentials (just mock `verify_id_token`).
"""

import firebase_admin
from firebase_admin import auth, credentials

from app.config import get_settings

_initialized = False


def _ensure_initialized() -> None:
    """Initialise Firebase Admin SDK on first call (lazy singleton)."""
    global _initialized
    if _initialized or firebase_admin._apps:
        _initialized = True
        return

    settings = get_settings()
    if settings.firebase_credentials_path:
        cred = credentials.Certificate(settings.firebase_credentials_path)
    else:
        cred = credentials.ApplicationDefault()

    firebase_admin.initialize_app(cred, {"projectId": settings.firebase_project_id})
    _initialized = True


def verify_id_token(id_token: str) -> dict:
    """
    Verify a Firebase ID token and return the decoded claims.

    Raises `firebase_admin.auth.InvalidIdTokenError` (subclass of `ValueError`)
    if the token is missing, malformed, expired, or issued for a different project.
    The caller is responsible for catching and converting this to an HTTP 401.
    """
    _ensure_initialized()
    return auth.verify_id_token(id_token)
