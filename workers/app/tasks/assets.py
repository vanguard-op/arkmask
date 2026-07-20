"""Asset extraction job handler — POST /tasks/assets (Cloud Tasks push target).

Extracts characters/backgrounds/objects from a story via the AI provider,
then writes the resulting asset documents directly to Firestore (see
app.services.asset_writer) — this used to be done client-side by the Flutter
app immediately after a synchronous `/assets` HTTP response. Moving the write
here means the app's existing real-time listeners on the assets/scenes
subcollections pick up the new documents automatically, with no client-side
parsing/writing logic needed at all.

This endpoint previously ran inline on the API's own Cloud Run service,
subject to its 60s request timeout — a slow provider response produced a hard
504 with no clean error path. See tasks/image.py for the same rationale
behind moving generation off the API's request path in general.
"""

import logging

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider
from app.services.asset_writer import write_extracted_assets

logger = logging.getLogger(__name__)


def _fetch_existing_assets(db, firebase_uid: str, project_slug: str) -> list[dict]:
    """
    Resolve every asset document already saved for this project — the
    project-level `assets/` subcollection plus every scene's local
    `scenes/{n}/assets/` subcollection — and shape each as
    ``{name, type, description, scene_number}`` for the provider's
    `existing_assets` input (see backend/instructions/asset-list-generation.md
    "Input Format").

    Mirrors the scan pattern already used by
    app.services.asset_manage.find_dependent_assets. Returns an empty list on
    a first-time extraction (no assets saved yet), which callers pass through
    as-is — the provider treats empty/omitted existing_assets as a normal
    first-time extraction.
    """
    project_path = f"users/{firebase_uid}/projects/{project_slug}"
    existing: list[dict] = []

    for doc in db.collection(f"{project_path}/assets").stream():
        data = doc.to_dict() or {}
        existing.append({
            "name": data.get("name", ""),
            "type": data.get("type", ""),
            "description": data.get("description", ""),
            "scene_number": data.get("scene_number", 0),
        })

    for scene_doc in db.collection(f"{project_path}/scenes").stream():
        scene_n = scene_doc.id
        for doc in db.collection(f"{project_path}/scenes/{scene_n}/assets").stream():
            data = doc.to_dict() or {}
            existing.append({
                "name": data.get("name", ""),
                "type": data.get("type", ""),
                "description": data.get("description", ""),
                "scene_number": data.get("scene_number", int(scene_n)),
            })

    return existing


def _make_provider(provider_type: str, provider_key: str):
    match provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=provider_key)
        case _:
            raise ValueError(f"Unknown provider_type '{provider_type}'.")


def run(payload: dict) -> None:
    """
    Execute one asset extraction job.

    Expected payload keys (set by backend/app/routers/generation.py::extract_assets):
        firebase_uid, job_id, project_slug, story, provider_type, provider_key.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Assets job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")

    try:
        provider = _make_provider(provider_type, payload["provider_key"])
        # FEAT-009 (incremental extraction) — resolve any assets already
        # saved for this project and pass them as context so the model only
        # extracts genuinely missing assets, never re-emitting (and thus
        # never touching) existing documents' prompt_body/gcs_image_path.
        existing_assets = _fetch_existing_assets(db, firebase_uid, project_slug)
        raw_assets = provider.generate_asset_list(payload["story"], existing_assets)

        write_extracted_assets(db, firebase_uid, project_slug, raw_assets)

        deduct_credits(db, firebase_uid, "assets", provider_type)
        update_job(db, firebase_uid, job_id, "success")
        notify(db, firebase_uid, job_id, "assets", project_slug, "completed")
        logger.info("Assets job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Assets job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "assets", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "assets", project_slug, "failed")
