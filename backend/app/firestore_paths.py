"""Centralized Firestore document path builders.

Firestore document references require an *even* number of "/"-separated
path segments (collection/doc/collection/doc/...) — an odd count is a
collection reference, not a document, and raises
``ValueError: A document must have an even number of path elements`` at
call time (only when actually constructed, not at import time — this bug
went unnoticed until the full deploy pipeline was working end-to-end).

``users/{uid}/profile`` looks like a single document per docs/ArkMask/
architecture.md, but as a literal path it's only 3 segments (odd) — an
invalid document reference. Since there's no natural per-item ID for a
"one profile per user" record, we nest it under a fixed singleton
document ID ("data") to make the path 4 segments (even) and valid.

Use these helpers instead of building "users/{uid}/profile" path strings
inline — this is exactly the class of bug that a single shared builder
prevents from recurring.
"""

# Fixed singleton document ID — arbitrary but must stay consistent across
# every reader/writer (backend, workers). Do not change without a migration.
_PROFILE_DOC_ID = "data"


def profile_path(uid: str) -> str:
    """Return the Firestore document path for a user's profile document."""
    return f"users/{uid}/profile/{_PROFILE_DOC_ID}"
