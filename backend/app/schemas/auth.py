"""Pydantic schemas for auth and account endpoints."""

from pydantic import BaseModel, EmailStr


class RegisterRequest(BaseModel):
    """Body for POST /register. Firebase ID token comes in the Authorization header."""
    email: EmailStr


class PlatformKeyResponse(BaseModel):
    """Returned by POST /register and POST /login."""
    platform_api_key: str


class CreditsResponse(BaseModel):
    """Returned by GET /me/credits."""
    credits: int
    tier: str


class UsageEventResponse(BaseModel):
    """A single usage event entry for GET /usage."""
    endpoint: str
    provider: str
    credits_deducted: int
    status: str
    timestamp: str   # ISO 8601


class UsageListResponse(BaseModel):
    events: list[UsageEventResponse]
