"""Object storage service — writes generated media to GCS (or MinIO locally)
and returns 2-hour TTL presigned download URLs.

In production, boto3 uses the GCS S3-compatible XML API.  In local dev, it
points at the MinIO container via STORAGE_ENDPOINT_URL.
"""

import uuid

import boto3
from botocore.config import Config

from app.config import get_settings


class MediaStore:
    """
    Wraps an S3-compatible bucket (GCS or MinIO).

    Saves raw bytes under a UUID key and returns a presigned GET URL.
    All objects are deleted automatically by the bucket's lifecycle policy
    (2 hours in production; no expiry in local dev unless configured manually).
    """

    def __init__(self):
        settings = get_settings()
        kwargs: dict = dict(
            aws_access_key_id=settings.storage_access_key,
            aws_secret_access_key=settings.storage_secret_key,
            config=Config(signature_version="s3v4"),
        )
        if settings.storage_endpoint_url:
            # MinIO or any S3-compatible endpoint.
            kwargs["endpoint_url"] = settings.storage_endpoint_url
        self._client = boto3.client("s3", **kwargs)
        self._bucket = settings.storage_bucket
        self._ttl = settings.storage_presign_ttl

    def save(self, data: bytes, mime_type: str) -> str:
        """Upload `data` and return a presigned URL valid for `storage_presign_ttl` seconds."""
        ext = mime_type.split("/")[-1]
        key = f"{uuid.uuid4()}.{ext}"
        self._client.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=data,
            ContentType=mime_type,
        )
        return self._presign(key)

    def presign(self, key: str) -> str:
        """Generate a fresh presigned URL for an existing object (used when TTL expires)."""
        return self._presign(key)

    def _presign(self, key: str) -> str:
        return self._client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=self._ttl,
        )
