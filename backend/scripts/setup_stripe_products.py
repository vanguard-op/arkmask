"""
One-off script to create ArkMask's Stripe products and prices.

Run once per Stripe account (test and production separately):

    python scripts/setup_stripe_products.py --key sk_test_...

Prints the Price IDs to add to your .env:
    STRIPE_PRICE_CREATOR_MONTHLY
    STRIPE_PRICE_CREATOR_ANNUAL
    STRIPE_PRICE_STUDIO_MONTHLY
    STRIPE_PRICE_STUDIO_ANNUAL
"""

import argparse
import sys

import stripe


def create_product_with_prices(
    name: str,
    description: str,
    monthly_usd_cents: int,
    annual_usd_cents: int,
) -> dict:
    """Create a Stripe product with monthly and annual recurring prices.

    Returns a dict with keys: product_id, monthly_price_id, annual_price_id.
    """
    product = stripe.Product.create(
        name=name,
        description=description,
    )
    print(f"  Created product: {product.id}  ({name})")

    monthly_price = stripe.Price.create(
        product=product.id,
        unit_amount=monthly_usd_cents,
        currency="usd",
        recurring={"interval": "month"},
        nickname=f"{name} — Monthly",
    )
    print(f"  Created monthly price: {monthly_price.id}  (${monthly_usd_cents / 100:.2f}/mo)")

    annual_price = stripe.Price.create(
        product=product.id,
        unit_amount=annual_usd_cents,
        currency="usd",
        recurring={"interval": "year"},
        nickname=f"{name} — Annual",
    )
    print(f"  Created annual price:  {annual_price.id}  (${annual_usd_cents / 100:.2f}/yr)")

    return {
        "product_id": product.id,
        "monthly_price_id": monthly_price.id,
        "annual_price_id": annual_price.id,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Create ArkMask Stripe products and prices.")
    parser.add_argument("--key", required=True, help="Stripe secret key (sk_test_... or sk_live_...)")
    args = parser.parse_args()

    stripe.api_key = args.key

    print("\n=== ArkMask Stripe Product Setup ===\n")

    print("Creating Creator tier...")
    creator = create_product_with_prices(
        name="ArkMask Creator",
        description="3,000 credits/month, unlimited projects, usage dashboard.",
        monthly_usd_cents=900,    # $9.00
        annual_usd_cents=7900,    # $79.00
    )

    print("\nCreating Studio tier...")
    studio = create_product_with_prices(
        name="ArkMask Studio",
        description="10,000 credits/month, unlimited projects, full usage dashboard + CSV export, API key regeneration, priority support.",
        monthly_usd_cents=2900,   # $29.00
        annual_usd_cents=24900,   # $249.00
    )

    print("\n=== Add these to your .env ===\n")
    print(f"STRIPE_PRICE_CREATOR_MONTHLY={creator['monthly_price_id']}")
    print(f"STRIPE_PRICE_CREATOR_ANNUAL={creator['annual_price_id']}")
    print(f"STRIPE_PRICE_STUDIO_MONTHLY={studio['monthly_price_id']}")
    print(f"STRIPE_PRICE_STUDIO_ANNUAL={studio['annual_price_id']}")
    print()


if __name__ == "__main__":
    main()
