"""Add jobs table for async generation job tracking.

Revision ID: 0002
Create Date: 2026-06-30
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Add 'server' to the provider_type enum so merge jobs can be tracked
    # without a BYOK provider.
    op.execute("ALTER TYPE provider_type ADD VALUE IF NOT EXISTS 'server'")

    op.create_table(
        "jobs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "type",
            sa.Enum("image", "video", "merge", name="job_type"),
            nullable=False,
        ),
        sa.Column(
            "status",
            sa.Enum("pending", "running", "success", "failed", name="job_status"),
            nullable=False,
            server_default="pending",
        ),
        sa.Column("project_slug", sa.String(255), nullable=False),
        sa.Column("scene_index", sa.Integer, nullable=True),
        sa.Column("asset_path", sa.String(512), nullable=True),
        sa.Column("gcs_output_path", sa.String(512), nullable=True),
        sa.Column("error_message", sa.String(1024), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_jobs_user_id", "jobs", ["user_id"])
    op.create_index("ix_jobs_status", "jobs", ["status"])


def downgrade() -> None:
    op.drop_index("ix_jobs_status")
    op.drop_index("ix_jobs_user_id")
    op.drop_table("jobs")
    op.execute("DROP TYPE IF EXISTS job_status")
    op.execute("DROP TYPE IF EXISTS job_type")
