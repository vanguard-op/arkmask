"""Pydantic schemas for billing endpoints."""

from pydantic import BaseModel


class CheckoutRequest(BaseModel):
    """Body for POST /billing/checkout."""
    price_id: str


class BillingUrlResponse(BaseModel):
    """Returned by /billing/checkout and /billing/portal — a hosted Stripe URL."""
    url: str
