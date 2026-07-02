"""Application configuration.

In Cloud Run, all sensitive values arrive as a single JSON blob in
``ARKMASK_SECRET`` (Secret Manager → single secret, mounted as env var).
We parse that blob once at import time and inject each key into the
environment so that pydantic-settings can read them the usual way.

Locally, use a ``.env`` file with the same keys (no ``ARKMASK_SECRET``
needed — pydantic-settings reads individual vars directly).
"""

import json
import logging
import os
from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

_log = logging.getLogger(__name__)

# Parse ARKMASK_SECRET JSON blob and inject each key into the environment
# before pydantic-settings reads. Individual vars already set in the
# environment (or via .env) take precedence (setdefault).
_secret_raw = os.environ.get("ARKMASK_SECRET", "")
if _secret_raw:
    try:
        for _k, _v in json.loads(_secret_raw).items():
            os.environ.setdefault(_k.upper(), str(_v))
    except Exception as _exc:
        _log.warning("Failed to parse ARKMASK_SECRET: %s", _exc)


class Settings(BaseSettings):
    """Application configuration loaded from environment variables or .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Object storage (GCS in production; MinIO locally)
    storage_bucket: str = "arkmask-local"
    storage_endpoint_url: str = ""        # empty = real GCS; set to MinIO URL locally
    storage_access_key: str = "minioadmin"
    storage_secret_key: str = "minioadmin"
    storage_presign_ttl: int = 7200       # 2 hours
    # Optional: override the host used in presigned URLs.
    # boto3 bakes storage_endpoint_url's hostname into presigned URLs.
    # When the backend runs in Docker (endpoint = http://minio:9000) but clients
    # are Android emulators or physical devices that can't resolve 'minio', set
    # this to the externally reachable address, e.g. http://10.0.2.2:9000.
    # Leave empty to use the URL boto3 produces unchanged (correct for production GCS).
    storage_presign_base_url: str = ""

    # Firebase
    firebase_project_id: str = "arkmask-dev"
    firebase_credentials_path: str = ""   # path to service account JSON; empty = ADC

    # Stripe billing
    stripe_secret_key: str = ""
    stripe_publishable_key: str = ""   # not used server-side; stored so .env is valid
    stripe_webhook_secret: str = ""
    stripe_price_creator_monthly: str = ""
    stripe_price_creator_annual: str = ""
    stripe_price_studio_monthly: str = ""
    stripe_price_studio_annual: str = ""
    # URLs Stripe redirects to after hosted checkout completes or is cancelled.
    stripe_billing_success_url: str = "https://arkmask.app/billing/success"
    stripe_billing_cancel_url: str = "https://arkmask.app/billing/cancel"
    # URL shown as the "Return to app" link inside the Customer Portal.
    stripe_billing_portal_return_url: str = "https://arkmask.app/billing"

    # Cloud Tasks (async image/video/merge job dispatch to the workers service).
    # In Cloud Run these come from Terraform-injected env vars (see
    # infra/terraform/envs/*/main.tf); locally, async jobs run inline instead
    # (see app.services.cloud_tasks.enqueue_job).
    gcp_project_id: str = ""              # falls back to firebase_project_id if unset
    gcp_region: str = "europe-west1"
    cloud_tasks_image_queue: str = ""
    cloud_tasks_video_queue: str = ""
    cloud_tasks_merge_queue: str = ""
    cloud_tasks_text_queue: str = ""
    workers_service_url: str = ""
    # Service account whose OIDC identity Cloud Tasks presents to the workers
    # Cloud Run service. Must already be granted roles/run.invoker on workers
    # (see infra/terraform/modules/iam — invoker_members on module.workers).
    api_service_account_email: str = ""

    # Environment
    app_env: str = "local"

    @property
    def is_local(self) -> bool:
        return self.app_env == "local"

    @property
    def gcp_project(self) -> str:
        """Project ID for Cloud Tasks — same GCP project as Firebase (see architecture.md)."""
        return self.gcp_project_id or self.firebase_project_id

    @property
    def cloud_tasks_configured(self) -> bool:
        """True once all Cloud Tasks env vars are present (i.e. running on Cloud Run)."""
        return bool(
            self.workers_service_url
            and self.cloud_tasks_image_queue
            and self.cloud_tasks_video_queue
            and self.cloud_tasks_merge_queue
            and self.cloud_tasks_text_queue
            and self.api_service_account_email
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()


# Absolute path to the instructions directory (AI system prompts).
INSTRUCTIONS_DIR = Path(__file__).parent.parent / "instructions"
