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
    Receives Stripe webhook events and updates Firestore accordingly.
    Must NOT require platform-key auth — Stripe calls this directly.
    Validated via the Stripe-Signature header + STRIPE_WEBHOOK_SECRET.

Webhook events handled:
  customer.subscription.created  — first paid subscription; set tier + write sub data
  customer.subscription.updated  — tier change or renewal; sync tier + period_end
  customer.subscription.deleted  — cancellation took effect; revert to free tier
  invoice.paid                   — credit reset on each billing cycle anniversary
  invoice_payment.paid           — newer Stripe accounts (multi-payment-per-invoice
                                    API versions) send this instead of/alongside
                                    invoice.paid; fetches the Invoice and delegates
                                    to the same handler
  invoice.payment_failed         — mark subscription past_due (grace period begins)

Firestore reverse-index:
  stripe_customers/{customer_id}  →  {firebase_uid: uid}
  Written when a Stripe customer is first created so webhook handlers can
  resolve the user with a single O(1) document get rather than a collection scan.
"""

import logging
from datetime import datetime, timezone

import stripe
from fastapi import APIRouter, Header, HTTPException, Request, status
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.config import get_settings
from app.dependencies import _firestore, get_current_user
from app.firestore_paths import profile_path
from app.models.user import UserProfile
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
    user: UserProfile,
) -> str:
    """Return the Stripe customer_id for the user, creating one if needed.

    On first creation, persists the customer_id to the user's Firestore profile
    and writes a reverse-index document at ``stripe_customers/{customer_id}``
    for O(1) webhook resolution.
    """
    if user.stripe_customer_id:
        return user.stripe_customer_id

    customer = client.customers.create(
        params={
            "email": user.email,
            "metadata": {"arkmask_uid": user.firebase_uid},
        }
    )
    db = _firestore()
    uid = user.firebase_uid

    # Persist customer_id on the profile.
    db.document(profile_path(uid)).update({
        "stripe_customer_id": customer.id,
        "updated_at": SERVER_TIMESTAMP,
    })

    # Write reverse-index for webhook resolution.
    db.collection("stripe_customers").document(customer.id).set({
        "firebase_uid": uid,
        "created_at": SERVER_TIMESTAMP,
    })

    logger.info("Created Stripe customer: uid=%s customer_id=%s", uid, customer.id)
    return customer.id


def _resolve_uid_by_customer(customer_id: str) -> str | None:
    """Look up the firebase_uid for a Stripe customer_id (O(1) reverse-index get)."""
    doc = _firestore().collection("stripe_customers").document(customer_id).get()
    if not doc.exists:
        return None
    return doc.get("firebase_uid")


# ── POST /billing/checkout ────────────────────────────────────────────────────

from fastapi import Depends  # noqa: E402 — placed after router to keep import block tidy

@router.post("/checkout", response_model=BillingUrlResponse)
def create_checkout_session(
    body: CheckoutRequest,
    current_user: UserProfile = Depends(get_current_user),
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
    customer_id = _get_or_create_stripe_customer(client, current_user)

    session = client.checkout.sessions.create(
        params={
            "customer": customer_id,
            "mode": "subscription",
            "line_items": [{"price": body.price_id, "quantity": 1}],
            "success_url": settings.stripe_billing_success_url,
            "cancel_url": settings.stripe_billing_cancel_url,
            # Embed the firebase_uid so the webhook can resolve the user
            # without relying solely on the customer reverse-index.
            "metadata": {"arkmask_uid": current_user.firebase_uid},
            "subscription_data": {
                "metadata": {"arkmask_uid": current_user.firebase_uid},
            },
        }
    )
    logger.info(
        "Checkout session created: uid=%s tier=%s session_id=%s",
        current_user.firebase_uid, tier, session.id,
    )
    return BillingUrlResponse(url=session.url)


# ── POST /billing/portal ──────────────────────────────────────────────────────

@router.post("/portal", response_model=BillingUrlResponse)
def create_portal_session(
    current_user: UserProfile = Depends(get_current_user),
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
    logger.info("Portal session created: uid=%s", current_user.firebase_uid)
    return BillingUrlResponse(url=session.url)


# ── POST /billing/webhook ─────────────────────────────────────────────────────

@router.post("/webhook", status_code=status.HTTP_200_OK)
async def stripe_webhook(
    request: Request,
    stripe_signature: str = Header(..., alias="stripe-signature"),
) -> dict:
    """Receive and process Stripe webhook events.

    Stripe sends signed events to this endpoint.  We verify the signature
    using STRIPE_WEBHOOK_SECRET before processing.  Each event type maps to
    a specific Firestore update (tier change, credit reset, etc.).

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
    event_id: str = event["id"]
    logger.info("Stripe webhook received: event_type=%s event_id=%s", event_type, event_id)

    # Wrapped in try/except with a distinctive log message so a Cloud Logging
    # log-based metric can alert on webhook processing failures (see
    # infra/terraform/modules/monitoring — "STRIPE_WEBHOOK_PROCESSING_FAILED").
    # Returning 5xx also makes Stripe retry the event automatically.
    try:
        match event_type:
            case "customer.subscription.created" | "customer.subscription.updated":
                _handle_subscription_upsert(event["data"]["object"])
            case "customer.subscription.deleted":
                _handle_subscription_deleted(event["data"]["object"])
            case "invoice.paid":
                _handle_invoice_paid(event["data"]["object"])
            case "invoice_payment.paid":
                _handle_invoice_payment_paid(event["data"]["object"])
            case "invoice.payment_failed":
                _handle_invoice_payment_failed(event["data"]["object"])
            case _:
                # Unhandled event types are silently acknowledged.
                logger.debug("Unhandled Stripe event type: %s", event_type)
    except Exception:
        logger.error(
            "STRIPE_WEBHOOK_PROCESSING_FAILED: event_type=%s event_id=%s",
            event_type,
            event_id,
            exc_info=True,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Webhook processing failed.",
        )

    return {"received": True}


# ── Webhook handlers ──────────────────────────────────────────────────────────

def _handle_subscription_upsert(subscription: dict) -> None:
    """Handle subscription.created and subscription.updated.

    Updates the user's tier and subscription sub-map in Firestore.
    Credits reset happens on invoice.paid, not here.
    """
    customer_id: str = subscription["customer"]
    sub_status: str = subscription["status"]

    # Resolve tier from the first line item's price ID.
    items = subscription.get("items", {}).get("data", [])
    if not items:
        logger.warning("Subscription has no line items: sub_id=%s", subscription["id"])
        return
    price_id: str = items[0]["price"]["id"]

    # current_period_end moved off the top-level Subscription object onto
    # each SubscriptionItem on newer Stripe API versions — present even for
    # accounts on "classic" billing_mode. `subscription["current_period_end"]`
    # raised a bare KeyError on any such account, which the outer handler in
    # stripe_webhook() turned into an HTTP 500 on *every* delivery attempt
    # (Stripe retries a 500 with the same payload, so it failed identically
    # every time) — meaning `tier` was never written for affected accounts,
    # not just delayed. Fall back to the item-level field.
    period_end_ts = subscription.get("current_period_end") or items[0].get("current_period_end")
    if period_end_ts is None:
        logger.warning(
            "Subscription has no current_period_end at top level or item "
            "level: sub_id=%s", subscription["id"],
        )
        return
    tier = _price_to_tier(price_id)
    if tier is None:
        # Price IDs are not secret (unlike the API key) — safe to log in
        # full, and doing so is what makes a monthly/annual price ID
        # transposition in the {env}-arkmask-config Secret Manager JSON
        # (see infra/SETUP.md Step 6) actually diagnosable from Cloud
        # Logging instead of a silent no-op.
        logger.warning(
            "Unknown price_id in subscription: price_id=%s sub_id=%s "
            "configured=%s",
            price_id, subscription["id"],
            {
                "creator_monthly": settings.stripe_price_creator_monthly,
                "creator_annual": settings.stripe_price_creator_annual,
                "studio_monthly": settings.stripe_price_studio_monthly,
                "studio_annual": settings.stripe_price_studio_annual,
            },
        )
        return

    uid = _resolve_uid_by_customer(customer_id)
    if uid is None:
        logger.warning("No user for Stripe customer: customer_id=%s", customer_id)
        return

    db_status = _map_subscription_status(sub_status)
    period_end_dt = datetime.fromtimestamp(period_end_ts, tz=timezone.utc)

    _firestore().document(profile_path(uid)).update({
        "tier": tier,
        "subscription": {
            "stripe_subscription_id": subscription["id"],
            "tier": tier,
            "period_end": period_end_dt.isoformat(),
            "status": db_status,
        },
        "updated_at": SERVER_TIMESTAMP,
    })
    logger.info(
        "Subscription upserted: uid=%s tier=%s status=%s period_end=%s",
        uid, tier, db_status, period_end_dt.isoformat(),
    )


def _handle_subscription_deleted(subscription: dict) -> None:
    """Handle subscription.deleted — revert the user to the Free tier."""
    customer_id: str = subscription["customer"]
    uid = _resolve_uid_by_customer(customer_id)
    if uid is None:
        logger.warning("No user for Stripe customer on deletion: customer_id=%s", customer_id)
        return

    _firestore().document(profile_path(uid)).update({
        "tier": "free",
        "credit_balance": TIER_CREDITS["free"],
        "subscription.status": "cancelled",
        "updated_at": SERVER_TIMESTAMP,
    })
    logger.info("Subscription cancelled — reverted to free: uid=%s", uid)


def _resolve_tier_from_invoice(invoice: dict) -> str | None:
    """Resolve the ArkMask tier directly from the invoice's own line items.

    Stripe does not guarantee that `customer.subscription.created/updated`
    is processed (or even delivered) before `invoice.paid` for the same
    checkout — they are separate webhook deliveries with no ordering
    guarantee, and even if delivered in order, each is handled by an
    independent async request with no synchronization between them. Reading
    a `tier` field that a *different* event handler was supposed to have
    already written is therefore racy: if invoice.paid runs first (or the
    subscription-upsert handler bailed early because `_price_to_tier`
    returned None for the price — see the warning logged there), this would
    silently reset a paying customer's credits to the still-default Free
    allowance while their profile is briefly (or permanently, in the
    price-mapping-failure case) stuck showing tier "free".

    Deriving the tier from this event's own `invoice["lines"]` instead makes
    invoice.paid self-contained — it no longer depends on any other event
    having already run successfully.
    """
    for line in invoice.get("lines", {}).get("data", []):
        price_id = (line.get("price") or {}).get("id")
        if not price_id:
            continue
        tier = _price_to_tier(price_id)
        if tier is not None:
            return tier
    return None


def _handle_invoice_paid(invoice: dict) -> None:
    """Handle invoice.paid — reset credits to the current tier's monthly allowance.

    Fires on first payment and on every billing cycle anniversary.
    Credits always reset to the full allowance; unused credits do not roll over.
    """
    customer_id: str = invoice["customer"]
    uid = _resolve_uid_by_customer(customer_id)
    if uid is None:
        logger.warning("No user for Stripe customer on invoice.paid: customer_id=%s", customer_id)
        return

    tier = _resolve_tier_from_invoice(invoice)
    if tier is not None:
        # Also (re-)write tier here — not just credit_balance — so this
        # event alone is enough to leave the profile correct even if
        # customer.subscription.created/updated hasn't landed yet, or never
        # will because its own price_id lookup failed (see
        # _handle_subscription_upsert's "Unknown price_id" warning; if you
        # see both that warning and this fallback firing for the same
        # subscription, the configured Stripe price ID for that tier/period
        # doesn't match stripe_price_{tier}_{monthly,annual} in the
        # {env}-arkmask-config Secret Manager JSON — double check it against
        # the Dashboard, especially for annual prices, which are easy to
        # transpose with the monthly price ID).
        update = {"tier": tier}
    else:
        # Could not resolve a tier from this invoice's own line items (e.g.
        # a $0 invoice with no price line, or a payload shape without
        # `lines`). Fall back to whatever tier is already on the profile
        # rather than guessing — this should be rare; log loudly so it's
        # visible in Cloud Logging if it does happen.
        profile_doc = _firestore().document(profile_path(uid)).get()
        tier = (profile_doc.to_dict() or {}).get("tier", "free") if profile_doc.exists else "free"
        update = {}
        logger.warning(
            "invoice.paid: could not resolve tier from invoice line items — "
            "falling back to profile tier=%s uid=%s invoice_id=%s",
            tier, uid, invoice.get("id"),
        )

    new_balance = TIER_CREDITS.get(tier, TIER_CREDITS["free"])
    update.update({
        "credit_balance": new_balance,
        "updated_at": SERVER_TIMESTAMP,
    })
    _firestore().document(profile_path(uid)).update(update)
    logger.info(
        "Credits reset on invoice.paid: uid=%s tier=%s new_balance=%d",
        uid, tier, new_balance,
    )


def _handle_invoice_payment_paid(invoice_payment: dict) -> None:
    """Handle invoice_payment.paid.

    Newer Stripe accounts (API versions supporting multiple payment attempts
    per invoice — see Stripe's "Invoice Payments" docs) send this
    `invoice_payment` object instead of, or alongside, the classic
    `invoice.paid` event. Its payload is much thinner than a full Invoice —
    just `{id, invoice, payment, amount_paid, status, ...}`, no `customer`
    or `lines` — so it can't be routed through `_resolve_uid_by_customer` /
    `_resolve_tier_from_invoice` directly.

    Fetch the referenced Invoice object (which does have `customer` and
    `lines`) and delegate to `_handle_invoice_paid` so both event shapes
    converge on one crediting implementation. Safe to run even if
    `invoice.paid` also fires for the same invoice — `_handle_invoice_paid`
    always sets an absolute credit balance, not an increment, so handling
    both is idempotent rather than double-crediting.
    """
    invoice_id = invoice_payment.get("invoice")
    if not invoice_id:
        logger.warning(
            "invoice_payment.paid missing invoice reference: id=%s",
            invoice_payment.get("id"),
        )
        return

    invoice = _stripe_client().invoices.retrieve(invoice_id)
    # The Stripe SDK returns a StripeObject; _handle_invoice_paid only reads
    # dict-style keys (invoice["customer"], invoice.get("lines"), etc.),
    # which StripeObject supports directly — no dict() conversion needed.
    _handle_invoice_paid(invoice)


def _handle_invoice_payment_failed(invoice: dict) -> None:
    """Handle invoice.payment_failed — mark the subscription as past_due.

    Stripe retries 3 times over 7 days.  If all retries fail, Stripe fires
    customer.subscription.deleted which then reverts the user to Free tier.
    We only update the sub status here; we do not downgrade immediately.
    """
    customer_id: str = invoice["customer"]
    uid = _resolve_uid_by_customer(customer_id)
    if uid is None:
        return

    _firestore().document(profile_path(uid)).update({
        "subscription.status": "past_due",
        "updated_at": SERVER_TIMESTAMP,
    })
    logger.warning("Payment failed — subscription marked past_due: uid=%s", uid)


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
