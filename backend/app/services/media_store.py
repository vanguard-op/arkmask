"""Object storage service — writes generated media to GCS (or MinIO locally)
and returns 2-hour TTL presigned download URLs.

In production, boto3 uses the GCS S3-compatible XML API.  In local dev, it
points at the MinIO container via STORAGE_ENDPOINT_URL.

Two-client strategy for local dev
----------------------------------
AWS S3 V4 signatures cover the `Host` header.  When the backend runs inside
Docker (STORAGE_ENDPOINT_URL = http://minio:9000), boto3 uses `minio` as the
Host when *both* uploading and presigning.  The resulting presigned URL contains
`minio` as the hostname — unreachable from Android emulators or physical devices.

Naively rewriting the hostname in the presigned URL after the fact breaks the
signature (the `Host` value the client sends no longer matches what was signed).

The correct fix: use two separate boto3 clients.
  • `_upload_client`  — endpoint = STORAGE_ENDPOINT_URL (http://minio:9000)
                        Used for put_object only.  Talks to MinIO inside Docker.
  • `_presign_client` — endpoint = STORAGE_PRESIGN_BASE_URL (http://10.0.2.2:9000)
                        Used for generate_presigned_url only.  Bakes the
                        externally-routable host into the signature so the URL
                        works from the emulator / physical device.

When STORAGE_PRESIGN_BASE_URL is empty (production / GCS), a single client
is used for both operations (standard behaviour).
"""

import uuid

import boto3
from botocore.config import Config

from app.config import get_settings


# GCS's S3-compatible XML API endpoint. When STORAGE_ENDPOINT_URL is unset
# (production), boto3 must be pointed here explicitly — leaving endpoint_url
# unset does NOT mean "use GCS"; boto3 falls back to its own default, which
# is real AWS S3. That mismatch previously caused every production upload to
# fail with "InvalidAccessKeyId" (the configured key really was invalid —
# just not because it was wrong, but because it was being sent to AWS
# instead of GCS in the first place).
_GCS_S3_ENDPOINT = "https://storage.googleapis.com"


def _make_client(endpoint_url: str, access_key: str, secret_key: str):
    """Return a boto3 S3 client, optionally scoped to a custom endpoint.

    ``endpoint_url`` empty means "use GCS" (see _GCS_S3_ENDPOINT above) —
    MinIO/local dev always passes an explicit endpoint (http://minio:9000).
    """
    kwargs: dict = dict(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        # botocore >= 1.36 defaults to computing request checksums
        # (x-amz-checksum-crc32 via aws-chunked/trailer encoding) on
        # PutObject. GCS's S3 XML compatibility layer doesn't support that
        # chunked-checksum scheme, so the extra header/trailer botocore signs
        # doesn't match what GCS validates, and every upload fails with
        # "SignatureDoesNotMatch". Forcing checksums to only be added when
        # the API truly requires them (and skipping response checksum
        # validation) restores the pre-1.36 signing behaviour that GCS
        # actually supports.
        config=Config(
            signature_version="s3v4",
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
        ),
        endpoint_url=endpoint_url or _GCS_S3_ENDPOINT,
    )
    return boto3.client("s3", **kwargs)


class MediaStore:
    """
    Wraps an S3-compatible bucket (GCS or MinIO).

    Saves raw bytes under a UUID key and returns a presigned GET URL valid for
    `STORAGE_PRESIGN_TTL` seconds.

    In local dev with Docker, two boto3 clients are used so that:
      - uploads go to the internal Docker endpoint (http://minio:9000)
      - presigned URLs are signed with the externally-routable endpoint
        (http://10.0.2.2:9000) so Android clients can actually fetch them.
    """

    def __init__(self):
        settings = get_settings()
        upload_endpoint = settings.storage_endpoint_url
        presign_endpoint = settings.storage_presign_base_url.rstrip("/")

        self._upload_client = _make_client(
            upload_endpoint,
            settings.storage_access_key,
            settings.storage_secret_key,
        )

        # If a separate presign base URL is configured, build a dedicated client
        # whose endpoint matches what external clients will use.  This ensures
        # the Host header baked into the SigV4 signature matches the request
        # the Android emulator / device actually sends.
        if presign_endpoint and presign_endpoint != upload_endpoint:
            self._presign_client = _make_client(
                presign_endpoint,
                settings.storage_access_key,
                settings.storage_secret_key,
            )
        else:
            self._presign_client = self._upload_client

        self._bucket = settings.storage_bucket
        self._ttl = settings.storage_presign_ttl

    def save(self, data: bytes, mime_type: str) -> str:
        """Upload `data` to the bucket and return a presigned download URL."""
        ext = mime_type.split("/")[-1]
        key = f"{uuid.uuid4()}.{ext}"
        self._upload_client.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=data,
            ContentType=mime_type,
        )
        return self._presign(key)

    def presign(self, key: str) -> str:
        """Generate a fresh presigned URL for an existing object (e.g. after TTL expiry)."""
        return self._presign(key)

    def get_object_bytes(self, gcs_path: str) -> bytes:
        """
        Download raw bytes for a GCS object identified by its object path.

        `gcs_path` is the raw object key within the bucket — NOT a presigned URL.
        Example: "users/uid/project-abc/assets/hero/image.png"

        Used by generation workers to fetch reference images and scene videos
        directly from GCS without going through the presigned URL flow.
        """
        response = self._upload_client.get_object(
            Bucket=self._bucket,
            Key=gcs_path,
        )
        return response["Body"].read()

    def put_object(self, gcs_path: str, data: bytes, content_type: str) -> None:
        """
        Upload raw bytes to a specific GCS object path (key).

        Used by generation workers to write generated media at deterministic
        paths (e.g. `{uid}/{slug}/assets/hero/image.png`) rather than the
        random UUID keys used by the legacy `save()` method.
        """
        self._upload_client.put_object(
            Bucket=self._bucket,
            Key=gcs_path,
            Body=data,
            ContentType=content_type,
        )

    def presign_path(self, gcs_path: str) -> str:
        """Generate a fresh presigned URL for an object at a known GCS path."""
        return self._presign(gcs_path)

    def _presign(self, key: str) -> str:
        return self._presign_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=self._ttl,
        )

    def delete_prefix(self, prefix: str) -> None:
        """
        Delete all objects under `prefix` in the bucket (FEAT-007).

        Uses the S3 list-then-delete pattern in batches of 1000 (the S3 API
        maximum for delete_objects). Safe to call if the prefix has no objects.
        """
        paginator = self._upload_client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self._bucket, Prefix=prefix):
            objects = page.get("Contents", [])
            if not objects:
                continue
            self._upload_client.delete_objects(
                Bucket=self._bucket,
                Delete={"Objects": [{"Key": obj["Key"]} for obj in objects]},
            )

    def get_storage_summary(self, prefix: str) -> dict:
        """
        Return GCS storage consumption broken down by media category (FEAT-027).

        Walks all objects under `prefix` and categorises by filename:
          - `image.png`  → images_bytes
          - `video.mp4`  → videos_bytes (scene clips)
          - `final.mp4`  → export_bytes
          - anything else → counted in total only

        Returns a dict with keys: total_bytes, images_bytes, videos_bytes,
        export_bytes.
        """
        total = 0
        images = 0
        videos = 0
        export = 0

        paginator = self._upload_client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self._bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                size = obj.get("Size", 0)
                key: str = obj["Key"]
                total += size
                if key.endswith("image.png"):
                    images += size
                elif key.endswith("final.mp4"):
                    export += size
                elif key.endswith("video.mp4"):
                    videos += size

        return {
            "total_bytes": total,
            "images_bytes": images,
            "videos_bytes": videos,
            "export_bytes": export,
        }
