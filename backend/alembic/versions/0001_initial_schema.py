"""Initial schema — users, usage_events, stripe_subscriptions.

Revision ID: 0001
Create Date: 2026-06-27
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # ── users ──────────────────────────────────────────────────────────────────
    # SQLAlchemy emits CREATE TYPE automatically for named Enum columns.
    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("email", sa.String(255), nullable=False, unique=True),
        sa.Column("firebase_uid", sa.String(128), nullable=False, unique=True),
        sa.Column("platform_api_key", sa.String(255), nullable=False),
        sa.Column(
            "tier",
            sa.Enum("free", "creator", "studio", name="user_tier"),
            nullable=False,
            server_default="free",
        ),
        sa.Column("credit_balance", sa.Integer, nullable=False, server_default="100"),
        sa.Column("fcm_token", sa.String(255), nullable=True),
        sa.Column("stripe_customer_id", sa.String(255), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
    )
    # Index for fast platform key lookup on every generation request.
    op.create_index("ix_users_platform_api_key", "users", ["platform_api_key"])

    # ── usage_events ──────────────────────────────────────────────────────────
    op.create_table(
        "usage_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("endpoint", sa.String(50), nullable=False),
        sa.Column(
            "provider",
            sa.Enum("gemini", "byteplus", name="provider_type"),
            nullable=False,
        ),
        sa.Column("credits_deducted", sa.Integer, nullable=False),
        sa.Column(
            "status",
            sa.Enum("success", "refunded", name="usage_status"),
            nullable=False,
        ),
        sa.Column(
            "timestamp",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_usage_events_user_id", "usage_events", ["user_id"])

    # ── stripe_subscriptions ──────────────────────────────────────────────────
    op.create_table(
        "stripe_subscriptions",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("stripe_subscription_id", sa.String(255), nullable=False),
        sa.Column(
            "tier",
            sa.Enum("creator", "studio", name="subscription_tier"),
            nullable=False,
        ),
        sa.Column("period_end", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "status",
            sa.Enum("active", "past_due", "cancelled", name="subscription_status"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )


def downgrade() -> None:
    op.drop_table("stripe_subscriptions")
    op.drop_index("ix_usage_events_user_id")
    op.drop_table("usage_events")
    op.drop_index("ix_users_platform_api_key")
    op.drop_table("users")
    op.execute("DROP TYPE IF EXISTS subscription_status")
    op.execute("DROP TYPE IF EXISTS subscription_tier")
    op.execute("DROP TYPE IF EXISTS usage_status")
    op.execute("DROP TYPE IF EXISTS provider_type")
    op.execute("DROP TYPE IF EXISTS user_tier")
