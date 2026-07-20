"""Story refinement job handler — POST /tasks/refine (Cloud Tasks push target).

Rewrites the project's entire `story_content` for video-generation clarity
(scene splitting, cross-scene continuity, explicit dialogue attribution,
fully-specified action/staging) via
`backend/instructions/refine-story-generation.md`, then writes the result to
the project document's `refined_story_preview` field — never to
`story_content` directly (FEAT-038). The app only copies the preview into
`story_content` when the user explicitly taps "Apply" on the Refine Story
Preview screen (see docs/ArkMask/screens.md Screen 8a).

See tasks/assets.py for the same rationale behind moving generation off the
API's request path (Cloud Run 60s timeout) onto this async worker pattern.
"""

import logging

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ai.byteplus import BytePlusProvider
from app.services.ai.gemini import GeminiProvider

logger = logging.getLogger(__name__)


def _make_provider(provider_type: str, provider_key: str):
    match provider_type.lower():
        case "gemini":
            return GeminiProvider(api_key=provider_key)
        case "byteplus" | "bytedance":
            return BytePlusProvider(api_key=provider_key)
        case _:
            raise ValueError(f"Unknown provider_type '{provider_type}'.")


def _known_character_names(db, firebase_uid: str, project_slug: str) -> list[str]:
    """Names of already-extracted `type: "character"` assets for this project.

    Only the project's global `assets/` subcollection is consulted — mirrors
    the "if asset extraction has already run for this project" condition in
    FEAT-038; scene-local-only characters are not surfaced here since the
    project may not have run extraction consistently across scenes yet, and
    the instruction only needs a best-effort name list for consistency, not
    an exhaustive one.
    """
    names: list[str] = []
    project_path = f"users/{firebase_uid}/projects/{project_slug}"
    for doc in db.collection(f"{project_path}/assets").stream():
        data = doc.to_dict() or {}
        if data.get("type") == "character":
            name = data.get("name") or doc.id
            if name and not name.startswith("@"):
                names.append(name)
    return names


def run(payload: dict) -> None:
    """
    Execute one story refinement job.

    Expected payload keys (set by backend/app/routers/generation.py::refine_story):
        firebase_uid, job_id, project_slug, provider_type, provider_key.

    Unlike /assets, the story text, generation_settings, and known character
    names are all re-resolved here from Firestore at execution time (not
    forwarded in the payload) — matching the freshness pattern already used
    by /video-prompt and /video (see app.services.scene_assets) so the
    rewrite always reflects the latest story_content, even if it changed
    between enqueue and the job actually running.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    provider_type: str = payload["provider_type"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Refine job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")

    try:
        project_ref = db.document(f"users/{firebase_uid}/projects/{project_slug}")
        project_doc = project_ref.get()
        if not project_doc.exists:
            raise ValueError(f"Project not found: {project_slug}")
        project_data = project_doc.to_dict() or {}

        story_content: str = project_data.get("story_content") or ""
        gen_settings: dict = project_data.get("generation_settings") or {}
        art_style: str = gen_settings.get("art_style") or (
            "painterly illustration with clean lines and rich color"
        )
        video_subtitles: bool = bool(gen_settings.get("video_subtitles", False))
        known_character_names = _known_character_names(db, firebase_uid, project_slug)

        provider = _make_provider(provider_type, payload["provider_key"])
        refined_story = provider.generate_refine_story(
            story_content,
            art_style=art_style,
            video_subtitles=video_subtitles,
            known_character_names=known_character_names,
        )

        # Preview-gated write — story_content is never touched here (FEAT-038,
        # R-026/R-027/R-028). The Flutter Firestore listener on the project
        # document fires when refined_story_preview is set and the Story
        # Editor shows the "ready to review" banner.
        project_ref.set(
            {
                "refined_story_preview": refined_story,
                "refined_story_generated_at": SERVER_TIMESTAMP,
                "updated_at": SERVER_TIMESTAMP,
            },
            merge=True,
        )

        deduct_credits(db, firebase_uid, "refine", provider_type)
        update_job(db, firebase_uid, job_id, "success")
        notify(db, firebase_uid, job_id, "refine", project_slug, "completed")
        logger.info("Refine job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Refine job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "refine", provider_type, evt_status="refunded")
        notify(db, firebase_uid, job_id, "refine", project_slug, "failed")
