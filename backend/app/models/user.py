"""UserProfile — in-memory representation of a Firestore user profile document.

Replaces the SQLAlchemy ``User`` ORM model.  Instances are constructed by
``get_current_user`` after reading ``users/{uid}/profile`` from Firestore
and are passed into route handlers via FastAPI ``Depends()``.

Not persisted directly — all writes go back through the Firestore client.
"""

from dataclasses import dataclass, field


@dataclass
class UserProfile:
    """Mirrors the fields stored in ``users/{uid}/profile``."""

    firebase_uid: str
    email: str
    tier: str                            # free | creator | studio
    credit_balance: int
    platform_api_key: str                # SHA-256 hex of the raw key (never the raw value)
    stripe_customer_id: str | None = None
    fcm_token: str | None = None

    @property
    def id(self) -> str:
        """Canonical user identifier — firebase_uid used everywhere.

        Provides backwards-compatible attribute access for code that
        previously referenced ``user.id`` on the SQLAlchemy model.
        """
        return self.firebase_uid
