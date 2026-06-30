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


def send_fcm_notification(fcm_token: str | None, data: dict[str, str]) -> None:
    """
    Send an FCM data-only push notification to a device token.

    All values in `data` must be strings (FCM data payload requirement).
    Silently skips if `fcm_token` is None or empty — not all users have
    registered a token (e.g. first launch before FCM init).

    Used by generation workers to notify the app of job completion so the
    Hive CE registry can be resolved and a toast shown.
    """
    if not fcm_token:
        return
    _ensure_initialized()
    from firebase_admin import messaging
    message = messaging.Message(
        data={k: str(v) for k, v in data.items()},
        token=fcm_token,
    )
    try:
        messaging.send(message)
    except Exception as e:
        # FCM failures are non-fatal — the Firestore listener is the primary
        # completion signal; FCM is a secondary convenience channel.
        import logging
        logging.getLogger(__name__).warning(
            "FCM send failed: token_prefix=%s error=%s",
            fcm_token[:8] if fcm_token else "none",
            type(e).__name__,
        )


def verify_id_token(id_token: str) -> dict:
    """
    Verify a Firebase ID token and return the decoded claims.

    Raises `firebase_admin.auth.InvalidIdTokenError` (subclass of `ValueError`)
    if the token is missing, malformed, expired, or issued for a different project.
    The caller is responsible for catching and converting this to an HTTP 401.
    """
    _ensure_initialized()
    return auth.verify_id_token(id_token)
