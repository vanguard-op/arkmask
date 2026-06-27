"""Unit tests for auth endpoints (FEAT-001, FEAT-002).

Uses an in-memory SQLite database — no PostgreSQL required.
Firebase token verification is mocked via `app.dependencies.verify_id_token`.
"""

import hashlib
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

# Import Base and models BEFORE create_all so tables are registered.
from app.database import Base, get_db
from app.models.db import User  # noqa: F401 — registers User with Base.metadata
from app.main import app

# ── In-memory SQLite test database ───────────────────────────────────────────

# StaticPool reuses a single connection so all sessions share the same in-memory DB.
engine = create_engine(
    "sqlite://",
    connect_args={"check_same_thread": False},
    poolclass=StaticPool,
)

# SQLite does not enforce foreign key constraints by default.
@event.listens_for(engine, "connect")
def set_sqlite_pragma(conn, _):
    conn.execute("PRAGMA foreign_keys=ON")

Base.metadata.create_all(bind=engine)

TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def override_get_db():
    db = TestingSession()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db

client = TestClient(app)

# ── Fixtures / helpers ────────────────────────────────────────────────────────

FIREBASE_UID = "firebase-uid-abc123"
MOCK_CLAIMS = {"uid": FIREBASE_UID}

# Patch target: verify_id_token as imported into dependencies module.
PATCH_TARGET = "app.dependencies.verify_id_token"


def _auth_headers() -> dict:
    return {"Authorization": "Bearer mock_id_token"}


def _make_user(db, email: str, uid: str, raw_key: str = "a" * 64) -> User:
    """Insert a User directly into the test DB."""
    hashed = hashlib.sha256(raw_key.encode()).hexdigest()
    user = User(email=email, firebase_uid=uid, platform_api_key=hashed, tier="free", credit_balance=100)
    db.add(user)
    db.commit()
    return user


# ── Tests: GET /health ────────────────────────────────────────────────────────

def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ready"


# ── Tests: POST /register ─────────────────────────────────────────────────────

@patch(PATCH_TARGET, return_value=MOCK_CLAIMS)
def test_register_creates_user_and_returns_key(_mock):
    resp = client.post(
        "/register",
        json={"email": "kofi@example.com"},
        headers=_auth_headers(),
    )
    assert resp.status_code == 201
    body = resp.json()
    assert "platform_api_key" in body
    assert len(body["platform_api_key"]) == 64  # 32-byte hex


@patch(PATCH_TARGET, return_value=MOCK_CLAIMS)
def test_register_duplicate_firebase_uid_returns_409(_mock):
    """Second registration with same Firebase UID → 409."""
    client.post("/register", json={"email": "kofi@example.com"}, headers=_auth_headers())
    resp = client.post(
        "/register",
        json={"email": "kofi2@example.com"},
        headers=_auth_headers(),
    )
    assert resp.status_code == 409


@patch(PATCH_TARGET, return_value={"uid": "other-uid"})
def test_register_duplicate_email_returns_409(_mock):
    """Different Firebase UID but same email → 409."""
    resp = client.post(
        "/register",
        json={"email": "kofi@example.com"},  # already in DB from previous test
        headers=_auth_headers(),
    )
    assert resp.status_code == 409


def test_register_missing_auth_header_returns_422():
    resp = client.post("/register", json={"email": "x@example.com"})
    assert resp.status_code == 422


# ── Tests: POST /login ────────────────────────────────────────────────────────

@patch(PATCH_TARGET, return_value={"uid": "login-test-uid"})
def test_login_returns_new_key(_mock):
    """Login issues a new platform key."""
    db = TestingSession()
    _make_user(db, "logintest@example.com", "login-test-uid")
    db.close()

    resp = client.post("/login", headers=_auth_headers())
    assert resp.status_code == 200
    body = resp.json()
    assert "platform_api_key" in body
    assert len(body["platform_api_key"]) == 64


@patch(PATCH_TARGET, return_value={"uid": "nonexistent-uid"})
def test_login_unregistered_uid_returns_401(_mock):
    resp = client.post("/login", headers=_auth_headers())
    assert resp.status_code == 401


# ── Tests: GET /me/credits ────────────────────────────────────────────────────

def test_get_credits_invalid_key_returns_401():
    resp = client.get("/me/credits", headers={"X-Platform-Key": "bad_key"})
    assert resp.status_code == 401


def test_get_credits_returns_balance():
    raw_key = "b" * 64
    db = TestingSession()
    _make_user(db, "credits@example.com", "credits-uid", raw_key)
    db.close()

    resp = client.get("/me/credits", headers={"X-Platform-Key": raw_key})
    assert resp.status_code == 200
    body = resp.json()
    assert body["credits"] == 100
    assert body["tier"] == "free"


# ── Tests: POST /keys/regenerate ──────────────────────────────────────────────

def test_regenerate_key_returns_new_key():
    raw_key = "c" * 64
    db = TestingSession()
    _make_user(db, "regen@example.com", "regen-uid", raw_key)
    db.close()

    resp = client.post("/keys/regenerate", headers={"X-Platform-Key": raw_key})
    assert resp.status_code == 200
    new_key = resp.json()["platform_api_key"]
    assert new_key != raw_key
    assert len(new_key) == 64

    # Old key should now be invalid.
    resp2 = client.get("/me/credits", headers={"X-Platform-Key": raw_key})
    assert resp2.status_code == 401

    # New key should work.
    resp3 = client.get("/me/credits", headers={"X-Platform-Key": new_key})
    assert resp3.status_code == 200
