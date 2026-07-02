"""Keeps a project's denormalized `completed_scene_count` in sync with its
scenes' actual `gcs_video_path` state.

`completed_scene_count` drives the project card's progress bar
(`ProjectDocument.completionFraction` in the Flutter app,
`mobile/lib/core/models/models.dart`). It was written once at project
creation (hardcoded to `0` — see `app/routers/projects.py`) and never
updated anywhere afterward, so every project's progress bar stayed
empty/stuck no matter how many scenes actually finished generating.

Shared between `backend/app/routers/generation.py` (local-dev fallback) and
`workers/app/tasks/video.py` (the real Cloud Tasks production path) — same
sharing arrangement as `app.services.scene_assets` / `app.services.ffmpeg_merge`.
"""

from google.cloud.firestore_v1 import SERVER_TIMESTAMP, Increment
from google.cloud.firestore_v1.transaction import Transaction, transactional


@transactional
def write_video_result(
    transaction: Transaction,
    scene_ref,
    project_ref,
    gcs_key: str,
) -> None:
    """Write `gcs_video_path` to the scene doc and, only on the scene's
    first-ever completion (`gcs_video_path` was previously unset),
    atomically increment the project doc's `completed_scene_count`.

    Guards against double-counting on video *regeneration* — an
    already-complete scene's video.mp4 being regenerated writes a new
    `gcs_video_path` value, not a null->non-null transition — by checking
    the scene doc's current state inside the same transaction before
    writing, so the increment and the write are atomic with respect to each
    other (no window where a concurrent read could see one without the
    other, and no double-increment from a retried transaction).
    """
    scene_snap = scene_ref.get(transaction=transaction)
    was_incomplete = not (scene_snap.to_dict() or {}).get("gcs_video_path")

    transaction.set(
        scene_ref,
        {"gcs_video_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
        merge=True,
    )
    if was_incomplete:
        transaction.update(project_ref, {
            "completed_scene_count": Increment(1),
            "updated_at": SERVER_TIMESTAMP,
        })
