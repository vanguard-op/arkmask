"""SQLAlchemy ORM models — maps exactly to the Cloud SQL schema in schema.md."""

import uuid
from datetime import datetime

from sqlalchemy import (
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    String,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class User(Base):
    """
    Stores ArkMask user accounts.

    The `platform_api_key` column holds a SHA-256 hex digest of the raw key.
    The raw key is returned to the client once at registration (or rotation)
    and never stored in plaintext.
    """

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    firebase_uid: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    # SHA-256 hex digest of the raw platform API key.
    platform_api_key: Mapped[str] = mapped_column(String(255), nullable=False)
    tier: Mapped[str] = mapped_column(
        Enum("free", "creator", "studio", name="user_tier"),
        nullable=False,
        default="free",
    )
    credit_balance: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    # FCM device token for push notifications. Updated on app startup.
    fcm_token: Mapped[str | None] = mapped_column(String(255), nullable=True)
    stripe_customer_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    usage_events: Mapped[list["UsageEvent"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )
    stripe_subscription: Mapped["StripeSubscription | None"] = relationship(
        back_populates="user", uselist=False, cascade="all, delete-orphan"
    )
    jobs: Mapped[list["Job"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class UsageEvent(Base):
    """
    Records every successful or refunded generation event.

    Credits are only deducted on terminal success (`status='success'`).
    Provider-side failures produce a refund row (`status='refunded'`,
    `credits_deducted=0`).
    """

    __tablename__ = "usage_events"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False
    )
    endpoint: Mapped[str] = mapped_column(String(50), nullable=False)
    provider: Mapped[str] = mapped_column(
        Enum("gemini", "byteplus", name="provider_type"), nullable=False
    )
    credits_deducted: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(
        Enum("success", "refunded", name="usage_status"), nullable=False
    )
    timestamp: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    user: Mapped["User"] = relationship(back_populates="usage_events")


class StripeSubscription(Base):
    """
    Tracks the Stripe subscription record for paid-tier users.
    Free-tier users have no row in this table.
    """

    __tablename__ = "stripe_subscriptions"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), primary_key=True
    )
    stripe_subscription_id: Mapped[str] = mapped_column(String(255), nullable=False)
    tier: Mapped[str] = mapped_column(
        Enum("creator", "studio", name="subscription_tier"), nullable=False
    )
    period_end: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    status: Mapped[str] = mapped_column(
        Enum("active", "past_due", "cancelled", name="subscription_status"),
        nullable=False,
    )

    user: Mapped["User"] = relationship(back_populates="stripe_subscription")


class Job(Base):
    """
    Tracks async generation jobs — image, video, and merge (FEAT-017).

    Created at enqueue time with status='pending'. Workers update status to
    'running' on start and 'success'/'failed' on completion. gcs_output_path
    is set on success and used by GET /job/{id}/status to return a presigned URL.

    This table replaces the in-memory _jobs dict from the old filesystem model.
    """
    __tablename__ = "jobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)   # UUID str
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False
    )
    type: Mapped[str] = mapped_column(
        Enum("image", "video", "merge", name="job_type"), nullable=False
    )
    status: Mapped[str] = mapped_column(
        Enum("pending", "running", "success", "failed", name="job_status"),
        nullable=False, default="pending",
    )
    project_slug: Mapped[str] = mapped_column(String(255), nullable=False)
    scene_index: Mapped[int | None] = mapped_column(Integer, nullable=True)
    asset_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # GCS object path of the job's output (set on success).
    gcs_output_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    error_message: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(),
        onupdate=func.now(), nullable=False
    )

    user: Mapped["User"] = relationship(back_populates="jobs")
