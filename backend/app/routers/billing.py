"""Billing endpoints — Stripe Checkout, Customer Portal, and webhook handler.

Three endpoints:

  POST /billing/checkout
    Creates a Stripe Checkout Session for a given price_id and returns the
    hosted URL.  The mobile app opens the URL in the system browser (iOS reader
    app exception — no native IAP). On completion Stripe fires a webhook.

  POST /billing/portal
    Creates a Stripe Customer Portal session and returns the URL.  Used by
    paying users to manage their subscription (cancel, downgrade, update card).

  POST /billing/webhook
    Receives Stripe webhook events and updates the database accordingly.
    Must NOT require platform-key auth — Stripe calls this directly.
    Validated via the Stripe-Signature header + STRIPE_WEBHOOK_SECRET.

Webhook events handled:
  customer.subscription.created  — first paid subscription; set tier + write sub row
  customer.subscription.updated  — tier change or renewal; sync tier + period_end
  customer.subscription.deleted  — cancellation took effect; revert to free tier
  invoice.paid                   — credit reset on each billing cycle anniversary
  invoice.payment_failed         — mark subscription past_due (grace period begins)
"""

import logging
from datetime import datetime, timezone

import stripe
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import get_db
from app.dependencies import get_current_user
from app.models.db import StripeSubscription, User
from app.schemas.billing import BillingUrlResponse, CheckoutRequest

router = APIRouter(prefix="/billing", tags=["billing"])
logger = logging.getLogger(__name__)

settings = get_settings()

# Monthly credit allowances per tier (see monetization.md).
TIER_CREDITS: dict[str, int] = {
    "free": 200,
    "creator": 3_000,
    "studio": 10_000,
}


def _stripe_client() -> stripe.StripeClient:
    """Return a configured Stripe client.  Raises 503 if the key is not set."""
    if not settings.stripe_secret_key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Billing is not configured on this server.",
        )
    return stripe.StripeClient(settings.stripe_secret_key)


def _price_to_tier(price_id: str) -> str | None:
    """Map a Stripe Price ID to an ArkMask tier name.  Returns None if unknown."""
    mapping = {
        settings.stripe_price_creator_monthly: "creator",
        settings.stripe_price_creator_annual: "creator",
        settings.stripe_price_studio_monthly: "studio",
        settings.stripe_price_studio_annual: "studio",
    }
    return mapping.get(price_id)


def _get_or_create_stripe_customer(
    client: stripe.StripeClient,
    user: User,
    db: Session,
) -> str:
    """Return the Stripe customer_id for the user, creating one if needed.

    Persists the customer_id to the database on first creation.
    """
    if user.stripe_customer_id:
        return user.stripe_customer_id

    customer = client.customers.create(params={"email": user.email, "metadata": {"arkmask_user_id": str(user.id)}})
    user.stripe_customer_id = customer.id
    db.commit()
    logger.info("Created Stripe customer: user_id=%s customer_id=%s", user.id, customer.id)
    return customer.id


# ── POST /billing/checkout ────────────────────────────────────────────────────

@router.post("/checkout", response_model=BillingUrlResponse)
def create_checkout_session(
    body: CheckoutRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BillingUrlResponse:
    """Create a Stripe Checkout Session for the given price and return its URL.

    The mobile app opens this URL in the system browser (iOS reader app
    exception — no native IAP).  After payment Stripe fires a webhook to
    POST /billing/webhook which updates the user's tier and credits.

    Raises 400 if the price_id is not one of the configured ArkMask prices.
    Raises 503 if Stripe is not configured.
    """
    tier = _price_to_tier(body.price_id)
    if tier is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown price_id '{body.price_id}'.",
        )

    client = _stripe_client()
    customer_id = _get_or_create_stripe_customer(client, current_user, db)

    session = client.checkout.sessions.create(
        params={
            "customer": customer_id,
            "mode": "subscription",
            "line_items": [{"price": body.price_id, "quantity": 1}],
            "success_url": settings.stripe_billing_success_url,
            "cancel_url": settings.stripe_billing_cancel_url,
            # Embed the ArkMask user_id so the webhook can resolve the user
            # without relying solely on customer_id lookup.
            "metadata": {"arkmask_user_id": str(current_user.id)},
            "subscription_data": {
                "metadata": {"arkmask_user_id": str(current_user.id)},
            },
        }
    )
    logger.info(
        "Checkout session created: user_id=%s tier=%s session_id=%s",
        current_user.id,
        tier,
        session.id,
    )
    return BillingUrlResponse(url=session.url)


# ── POST /billing/portal ──────────────────────────────────────────────────────

@router.post("/portal", response_model=BillingUrlResponse)
def create_portal_session(
    current_user: User = Depends(get_current_user),
) -> BillingUrlResponse:
    """Create a Stripe Customer Portal session and return its URL.

    Used by paying users to manage their subscription (cancel, downgrade,
    update payment method).  Raises 402 if the user has no Stripe customer
    record (i.e. they are on the Free tier and have never paid).
    """
    if not current_user.stripe_customer_id:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail="No active subscription found. Upgrade to a paid plan first.",
        )

    client = _stripe_client()
    session = client.billing_portal.sessions.create(
        params={
            "customer": current_user.stripe_customer_id,
            "return_url": settings.stripe_billing_portal_return_url,
        }
    )
    logger.info("Portal session created: user_id=%s", current_user.id)
    return BillingUrlResponse(url=session.url)


# ── POST /billing/webhook ─────────────────────────────────────────────────────

@router.post("/webhook", status_code=status.HTTP_200_OK)
async def stripe_webhook(
    request: Request,
    stripe_signature: str = Header(..., alias="stripe-signature"),
    db: Session = Depends(get_db),
) -> dict:
    """Receive and process Stripe webhook events.

    Stripe sends signed events to this endpoint.  We verify the signature
    using STRIPE_WEBHOOK_SECRET before processing.  Each event type maps to
    a specific database update (tier change, credit reset, etc.).

    Returns 200 on success.  Returns 400 if the signature is invalid (Stripe
    will retry on 4xx/5xx).
    """
    if not settings.stripe_webhook_secret:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Webhook secret not configured.",
        )

    payload = await request.body()

    try:
        event = stripe.Webhook.construct_event(
            payload=payload,
            sig_header=stripe_signature,
            secret=settings.stripe_webhook_secret,
        )
    except stripe.error.SignatureVerificationError:
        logger.warning("Stripe webhook signature verification failed")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid webhook signature.",
        )

    event_type: str = event["type"]
    logger.info("Stripe webhook received: event_type=%s event_id=%s", event_type, event["id"])

    match event_type:
        case "customer.subscription.created" | "customer.subscription.updated":
            _handle_subscription_upsert(event["data"]["object"], db)
        case "customer.subscription.deleted":
            _handle_subscription_deleted(event["data"]["object"], db)
        case "invoice.paid":
            _handle_invoice_paid(event["data"]["object"], db)
        case "invoice.payment_failed":
            _handle_invoice_payment_failed(event["data"]["object"], db)
        case _:
            # Unhandled event types are silently acknowledged.
            logger.debug("Unhandled Stripe event type: %s", event_type)

    return {"received": True}


# ── Webhook handlers ──────────────────────────────────────────────────────────

def _resolve_user_by_customer(customer_id: str, db: Session) -> User | None:
    """Find a User by their Stripe customer_id.  Returns None if not found."""
    return db.query(User).filter(User.stripe_customer_id == customer_id).first()


def _handle_subscription_upsert(subscription: dict, db: Session) -> None:
    """Handle subscription.created and subscription.updated.

    Updates the user's tier, writes or updates the stripe_subscriptions row,
    and does NOT reset credits here — credits reset happens on invoice.paid.
    """
    customer_id: str = subscription["customer"]
    status_str: str = subscription["status"]  # active, past_due, canceled, etc.
    period_end_ts: int = subscription["current_period_end"]

    # Resolve tier from the first line item's price ID.
    items = subscription.get("items", {}).get("data", [])
    if not items:
        logger.warning("Subscription has no line items: sub_id=%s", subscription["id"])
        return
    price_id: str = items[0]["price"]["id"]
    tier = _price_to_tier(price_id)
    if tier is None:
        logger.warning("Unknown price_id in subscription: price_id=%s", price_id)
        return

    user = _resolve_user_by_customer(customer_id, db)
    if user is None:
        logger.warning("No user for Stripe customer: customer_id=%s", customer_id)
        return

    # Map Stripe subscription status to our enum.
    db_status = _map_subscription_status(status_str)

    # Upsert the stripe_subscriptions row.
    sub_row = user.stripe_subscription
    period_end_dt = datetime.fromtimestamp(period_end_ts, tz=timezone.utc)
    if sub_row is None:
        sub_row = StripeSubscription(
            user_id=user.id,
            stripe_subscription_id=subscription["id"],
            tier=tier,
            period_end=period_end_dt,
            status=db_status,
        )
        db.add(sub_row)
    else:
        sub_row.stripe_subscription_id = subscription["id"]
        sub_row.tier = tier
        sub_row.period_end = period_end_dt
        sub_row.status = db_status

    # Update the user's tier.
    old_tier = user.tier
    user.tier = tier
    db.commit()
    logger.info(
        "Subscription upserted: user_id=%s tier=%s→%s status=%s period_end=%s",
        user.id, old_tier, tier, db_status, period_end_dt.isoformat(),
    )


def _handle_subscription_deleted(subscription: dict, db: Session) -> None:
    """Handle subscription.deleted — revert the user to the Free tier.

    The subscription row is marked 'cancelled' but kept for audit purposes.
    Credits are reset to the Free allowance.
    """
    customer_id: str = subscription["customer"]
    user = _resolve_user_by_customer(customer_id, db)
    if user is None:
        logger.warning("No user for Stripe customer on deletion: customer_id=%s", customer_id)
        return

    user.tier = "free"
    user.credit_balance = TIER_CREDITS["free"]

    sub_row = user.stripe_subscription
    if sub_row:
        sub_row.status = "cancelled"

    db.commit()
    logger.info("Subscription cancelled — reverted to free: user_id=%s", user.id)


def _handle_invoice_paid(invoice: dict, db: Session) -> None:
    """Handle invoice.paid — reset credits to the current tier's monthly allowance.

    This fires on the first payment (new sub) and on every subsequent billing
    cycle anniversary.  Credits always reset to the full allowance; unused
    credits do not roll over (per monetization.md).
    """
    customer_id: str = invoice["customer"]
    user = _resolve_user_by_customer(customer_id, db)
    if user is None:
        logger.warning("No user for Stripe customer on invoice.paid: customer_id=%s", customer_id)
        return

    new_balance = TIER_CREDITS.get(user.tier, TIER_CREDITS["free"])
    user.credit_balance = new_balance
    db.commit()
    logger.info(
        "Credits reset on invoice.paid: user_id=%s tier=%s new_balance=%d",
        user.id, user.tier, new_balance,
    )


def _handle_invoice_payment_failed(invoice: dict, db: Session) -> None:
    """Handle invoice.payment_failed — mark the subscription as past_due.

    Stripe retries 3 times over 7 days.  If all retries fail, Stripe fires
    customer.subscription.deleted which then reverts the user to Free tier.
    We only update the sub status here; we do not downgrade immediately.
    """
    customer_id: str = invoice["customer"]
    user = _resolve_user_by_customer(customer_id, db)
    if user is None:
        return

    sub_row = user.stripe_subscription
    if sub_row:
        sub_row.status = "past_due"
        db.commit()
        logger.warning(
            "Payment failed — subscription marked past_due: user_id=%s", user.id
        )


def _map_subscription_status(stripe_status: str) -> str:
    """Map a Stripe subscription status string to our subscription_status enum."""
    return {
        "active": "active",
        "past_due": "past_due",
        "canceled": "cancelled",
        "cancelled": "cancelled",
        "incomplete": "past_due",
        "incomplete_expired": "cancelled",
        "trialing": "active",
        "unpaid": "past_due",
    }.get(stripe_status, "past_due")
