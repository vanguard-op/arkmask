"""Firestore client accessor for workers.

Mirrors ``backend/app/dependencies.py::_firestore()`` — kept as a separate,
tiny module here (rather than importing dependencies.py directly) since that
module pulls in FastAPI request/header dependencies that workers don't need
and that aren't part of the shared service code copied into this image (see
workers/Dockerfile).
"""

from app.services.firebase import _ensure_initialized


def get_firestore():
    """Return a Firestore client, ensuring Firebase Admin is initialised."""
    from firebase_admin import firestore as _fs
    _ensure_initialized()
    return _fs.client()
