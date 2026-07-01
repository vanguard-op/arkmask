"""ArkMask Workers — Cloud Tasks push-target service.

Not publicly accessible (see infra/terraform/modules/cloud-run —
allow_unauthenticated=false for this service). Cloud Tasks is the only
caller, authenticating via an OIDC identity token that Cloud Run's own
ingress layer verifies against IAM (roles/run.invoker) before any request
reaches this application code — see app.services.cloud_tasks on the API side
for how tasks are enqueued with that token.

Each endpoint below corresponds to one Cloud Tasks queue (see
infra/terraform/modules/cloud-tasks) and runs a single job to completion,
matching the "Generation Workers (Cloud Tasks)" component in
docs/ArkMask/architecture.md.

Response contract for Cloud Tasks retry semantics:
  - 200: job handled (whether it succeeded or failed business-logic-wise —
    the task handler itself already wrote status="failed" to Firestore and
    sent an FCM failure push; retrying would not help and could double-charge
    credits).
  - 5xx: unexpected/unhandled error (e.g. Firestore or GCS unreachable, a bug)
    — Cloud Tasks retries per the queue's retry_config (exponential backoff,
    see infra/terraform/modules/cloud-tasks/main.tf).
"""

import logging

from fastapi import FastAPI, HTTPException, Request

from app.tasks import image, merge, video

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="ArkMask Workers")


@app.get("/")
def health() -> dict:
    """Liveness/startup check — Cloud Run's TCP probe only needs the port open,
    but a real endpoint makes manual verification and future HTTP health
    checks straightforward."""
    return {"status": "ok"}


@app.post("/tasks/image")
async def handle_image_task(request: Request) -> dict:
    payload = await request.json()
    try:
        image.run(payload)
    except Exception as e:
        logger.error("Unhandled error in image task: job_id=%s", payload.get("job_id"), exc_info=True)
        raise HTTPException(status_code=500, detail=str(e)) from e
    return {"status": "handled"}


@app.post("/tasks/video")
async def handle_video_task(request: Request) -> dict:
    payload = await request.json()
    try:
        video.run(payload)
    except Exception as e:
        logger.error("Unhandled error in video task: job_id=%s", payload.get("job_id"), exc_info=True)
        raise HTTPException(status_code=500, detail=str(e)) from e
    return {"status": "handled"}


@app.post("/tasks/merge")
async def handle_merge_task(request: Request) -> dict:
    payload = await request.json()
    try:
        merge.run(payload)
    except Exception as e:
        logger.error("Unhandled error in merge task: job_id=%s", payload.get("job_id"), exc_info=True)
        raise HTTPException(status_code=500, detail=str(e)) from e
    return {"status": "handled"}
