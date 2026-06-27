from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application configuration loaded from environment variables or .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Database
    database_url: str = "postgresql://arkmask:arkmask@localhost:5432/arkmask"

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

    # Environment
    app_env: str = "local"

    @property
    def is_local(self) -> bool:
        return self.app_env == "local"


@lru_cache
def get_settings() -> Settings:
    return Settings()


# Absolute path to the instructions directory (AI system prompts).
INSTRUCTIONS_DIR = Path(__file__).parent.parent / "instructions"
