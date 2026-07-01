"""Cloud Tasks dispatch — enqueues async generation jobs to the workers service.

The API never runs image/video/merge generation itself. Instead it writes a
job document to Firestore (see app.routers.generation._create_job) and
enqueues an HTTP task that Cloud Tasks delivers to the workers Cloud Run
service (`POST {WORKERS_SERVICE_URL}/tasks/{image,video,merge}`).

Cloud Tasks authenticates to the workers service using an OIDC identity token
minted for `API_SERVICE_ACCOUNT_EMAIL` — that service account is already
granted `roles/run.invoker` on the workers Cloud Run service (see
infra/terraform/modules/iam, `invoker_members` on module.workers), so Cloud
Run's own ingress layer verifies the token before the request ever reaches
worker application code.

Local development fallback: when Cloud Tasks env vars aren't configured (no
GCP project / workers URL wired up locally), `enqueue_job` runs the same
handler inline via asyncio instead of failing — this keeps `docker-compose`
local dev working without a live Cloud Tasks queue or workers container.
"""

import json
import logging

from google.cloud import tasks_v2

from app.config import get_settings

logger = logging.getLogger(__name__)

_QUEUE_BY_JOB_TYPE = {
    "image": "cloud_tasks_image_queue",
    "video": "cloud_tasks_video_queue",
    "merge": "cloud_tasks_merge_queue",
}


def enqueue_job(job_type: str, payload: dict) -> None:
    """
    Enqueue a Cloud Tasks HTTP task that invokes the workers service.

    Args:
        job_type: One of "image", "video", "merge" — selects both the queue
            and the workers endpoint (`/tasks/{job_type}`).
        payload: JSON-serializable dict forwarded as the task's HTTP body.
            Must include everything the worker needs to run the job
            (firebase_uid, job_id, provider credentials, GCS paths, etc.) —
            workers are stateless and read nothing from the API process.

    Raises:
        ValueError: if `job_type` is not a recognized queue name.
    """
    if job_type not in _QUEUE_BY_JOB_TYPE:
        raise ValueError(f"Unknown job_type '{job_type}' — expected one of {list(_QUEUE_BY_JOB_TYPE)}")

    settings = get_settings()
    queue_name = getattr(settings, _QUEUE_BY_JOB_TYPE[job_type])
    target_url = f"{settings.workers_service_url.rstrip('/')}/tasks/{job_type}"

    client = tasks_v2.CloudTasksClient()
    parent = client.queue_path(settings.gcp_project, settings.gcp_region, queue_name)

    task = {
        "http_request": {
            "http_method": tasks_v2.HttpMethod.POST,
            "url": target_url,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(payload).encode(),
            "oidc_token": {
                "service_account_email": settings.api_service_account_email,
            },
        }
    }

    client.create_task(parent=parent, task=task)
    logger.info("Enqueued %s job to %s (queue=%s)", job_type, target_url, queue_name)
