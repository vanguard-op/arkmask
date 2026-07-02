"""Shared job-lifecycle helpers used by all three Cloud Tasks task handlers
(image, video, merge).

Job *creation* happens on the API side (see
``backend/app/routers/generation.py::_create_job``) at enqueue time — workers
only ever transition an existing job document through running -> success/failed,
deduct credits on terminal success, and send the FCM completion push.
"""

import logging

from google.cloud.firestore_v1 import SERVER_TIMESTAMP
from google.cloud.firestore_v1.transaction import transactional

from app.firestore_paths import profile_path
from app.services.firebase import send_fcm_notification

logger = logging.getLogger(__name__)

# Must stay in sync with backend/app/routers/generation.py::CREDIT_COSTS.
# Duplicated rather than imported because the API and workers are built and
# deployed as independent Docker images (see workers/Dockerfile) — there is
# no shared installable package between them today.
CREDIT_COSTS: dict[str, int] = {
    "image": 5,
    "video": 20,
    "merge": 5,
    "assets": 1,
    "image_prompt": 1,
    "video_prompt": 3,
}


def already_terminal(db, firebase_uid: str, job_id: str) -> bool:
    """
    True if the job has already reached a terminal state (success/failed).

    Cloud Tasks guarantees *at-least-once* delivery — a task can be
    redelivered after an earlier attempt already completed all of its work
    (e.g. the container was recycled after committing Firestore writes but
    before Cloud Tasks received the 200 response). Checking this before doing
    any work makes job execution idempotent and prevents double-charging
    credits or re-running an expensive AI generation call on redelivery.
    """
    doc = db.document(f"users/{firebase_uid}/jobs/{job_id}").get()
    return doc.exists and doc.get("status") in ("success", "failed")


def update_job(
    db,
    firebase_uid: str,
    job_id: str,
    status_: str,
    gcs_output_path: str | None = None,
    error_message: str | None = None,
) -> None:
    """Transition a job document's status field (and optionally output/error)."""
    data: dict = {"status": status_, "updated_at": SERVER_TIMESTAMP}
    if gcs_output_path is not None:
        data["gcs_output_path"] = gcs_output_path
    if error_message is not None:
        data["error_message"] = error_message
    db.document(f"users/{firebase_uid}/jobs/{job_id}").update(data)


@transactional
def _deduct_in_txn(transaction, user_ref, credits: int) -> None:
    """Atomically decrement credit_balance inside a Firestore transaction."""
    snapshot = user_ref.get(transaction=transaction)
    if not snapshot.exists:
        return
    current: int = (snapshot.to_dict() or {}).get("credit_balance", 0)
    transaction.update(user_ref, {"credit_balance": max(0, current - credits)})


def deduct_credits(
    db,
    firebase_uid: str,
    job_type: str,
    provider: str,
    evt_status: str = "success",
) -> None:
    """
    Deduct credits for a terminal job and append a usage_events ledger entry.

    ``evt_status="refunded"`` (failed jobs) always deducts 0 credits — the
    usage event is still recorded for the Usage Dashboard (FEAT-024).
    """
    credits = CREDIT_COSTS.get(job_type, 0) if evt_status == "success" else 0
    if credits > 0:
        user_ref = db.document(profile_path(firebase_uid))
        txn = db.transaction()
        _deduct_in_txn(txn, user_ref, credits)

    db.collection(f"users/{firebase_uid}/usage_events").document().set({
        "endpoint": f"/{job_type}",
        "provider": provider,
        "credits_deducted": credits,
        "status": evt_status,
        "timestamp": SERVER_TIMESTAMP,
    })


def get_fcm_token(db, firebase_uid: str) -> str | None:
    """Fetch the latest FCM token from Firestore for push notification delivery."""
    try:
        doc = db.document(profile_path(firebase_uid)).get()
        return (doc.to_dict() or {}).get("fcm_token") if doc.exists else None
    except Exception:
        return None


def notify(
    db,
    firebase_uid: str,
    job_id: str,
    job_type: str,
    project_slug: str,
    status_: str,
    **extra: str,
) -> None:
    """Send the FCM job-completion push with full routing context."""
    payload = {"job_id": job_id, "type": job_type, "project_id": project_slug, "status": status_, **extra}
    send_fcm_notification(get_fcm_token(db, firebase_uid), payload)
