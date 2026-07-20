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
from typing import Callable

from fastapi import FastAPI, HTTPException, Request

from app.tasks import assets, image, image_prompt, merge, refine_story, video, video_prompt

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="ArkMask Workers")


@app.get("/")
def health() -> dict:
    """Liveness/startup check — Cloud Run's TCP probe only needs the port open,
    but a real endpoint makes manual verification and future HTTP health
    checks straightforward."""
    return {"status": "ok"}


def _make_handler(task_name: str, run: Callable[[dict], None]):
    """
    Build a POST /tasks/{task_name} handler with the shared retry contract
    (see module docstring): business-logic failures inside `run()` are
    already handled and logged by the task module itself (job marked
    "failed", FCM sent) and return 200; only an exception escaping `run()`
    entirely (unexpected bug, Firestore/GCS unreachable) becomes a 500 so
    Cloud Tasks retries.
    """
    async def handler(request: Request) -> dict:
        payload = await request.json()
        try:
            run(payload)
        except Exception as e:
            logger.error("Unhandled error in %s task: job_id=%s", task_name, payload.get("job_id"), exc_info=True)
            raise HTTPException(status_code=500, detail=str(e)) from e
        return {"status": "handled"}

    return handler


app.add_api_route("/tasks/image", _make_handler("image", image.run), methods=["POST"])
app.add_api_route("/tasks/video", _make_handler("video", video.run), methods=["POST"])
app.add_api_route("/tasks/merge", _make_handler("merge", merge.run), methods=["POST"])
app.add_api_route("/tasks/assets", _make_handler("assets", assets.run), methods=["POST"])
app.add_api_route("/tasks/image_prompt", _make_handler("image_prompt", image_prompt.run), methods=["POST"])
app.add_api_route("/tasks/video_prompt", _make_handler("video_prompt", video_prompt.run), methods=["POST"])
app.add_api_route("/tasks/refine", _make_handler("refine", refine_story.run), methods=["POST"])
