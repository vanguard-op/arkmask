"""Video merge job handler — POST /tasks/merge (Cloud Tasks push target).

Executes the Merge Worker steps from docs/ArkMask/architecture.md ("Generation
Workers (Cloud Tasks)"): downloads each scene's video.mp4 from GCS, runs
FFmpeg to apply per-scene trim points and transitions, concatenates into
final.mp4, and uploads the result. Requires the ``ffmpeg`` binary (bundled in
workers/Dockerfile — see architecture.md "FFmpeg is bundled in the merge
worker container image; no on-device FFmpeg dependency").
"""

import logging
import subprocess
import tempfile
from pathlib import Path

from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from app.firestore_client import get_firestore
from app.jobs import already_terminal, deduct_credits, notify, update_job
from app.services.ffmpeg_merge import build_merge_filter_cmd
from app.services.media_store import MediaStore

logger = logging.getLogger(__name__)


def _run_ffmpeg_merge(clip_files: list[tuple[Path, dict]], output: Path) -> None:
    """
    Run FFmpeg to trim clips and concatenate with transitions.

    Strategy:
    - For hard_cut-only timelines: use the concat demuxer (fast, no full re-encode).
    - For fade_black / dissolve transitions: use app.services.ffmpeg_merge's
      filter_complex builder — see that module's docstring for why this does
      NOT use the `xfade` filter (it did briefly; that regressed exactly the
      "current rate of 1/0 is invalid" xfade/VFR bug the original on-device
      implementation was written to avoid in the first place).
    """
    if not clip_files:
        raise ValueError("No clips to merge.")

    all_hard_cut = all(
        entry["transition_to_next"] == "hard_cut"
        for _, entry in clip_files[:-1]
    )

    if all_hard_cut or len(clip_files) == 1:
        # Fast path: concat demuxer (minimal re-encode).
        concat_list = output.parent / "concat.txt"
        lines = []
        for clip_path, entry in clip_files:
            lines.append(f"file '{clip_path}'")
            lines.append(f"inpoint {entry['trim_in']}")
            lines.append(f"outpoint {entry['trim_out']}")
        concat_list.write_text("\n".join(lines))
        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0", "-i", str(concat_list),
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            str(output),
        ]
    else:
        cmd = build_merge_filter_cmd(clip_files, output)

    logger.info("FFmpeg command: %s ...", " ".join(cmd[:8]))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        logger.error("FFmpeg failed:\nstderr=%s", result.stderr[-2000:])
        raise RuntimeError(f"FFmpeg merge failed: {result.stderr[-500:]}")


def run(payload: dict) -> None:
    """
    Execute one merge job.

    Expected payload keys (set by backend/app/routers/generation.py::enqueue_merge):
        firebase_uid, job_id, project_slug,
        scenes: list of {scene_index, trim_in, trim_out, transition_to_next}.
    """
    db = get_firestore()
    firebase_uid: str = payload["firebase_uid"]
    job_id: str = payload["job_id"]
    project_slug: str = payload["project_slug"]
    scenes: list[dict] = payload["scenes"]

    if already_terminal(db, firebase_uid, job_id):
        logger.info("Merge job %s already terminal — skipping redelivered task.", job_id)
        return

    update_job(db, firebase_uid, job_id, "running")

    try:
        store = MediaStore()
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            clip_files: list[tuple[Path, dict]] = []

            # 1. Download each scene video from GCS to temp dir.
            for entry in scenes:
                gcs_key = f"{firebase_uid}/{project_slug}/scenes/{entry['scene_index']}/video.mp4"
                try:
                    data = store.get_object_bytes(gcs_key)
                except Exception as e:
                    raise ValueError(f"Could not fetch video for scene {entry['scene_index']}: {e}")
                clip_path = tmp_path / f"scene_{entry['scene_index']:04d}.mp4"
                clip_path.write_bytes(data)
                clip_files.append((clip_path, entry))

            # 2. Run FFmpeg to apply trims + transitions.
            final_path = tmp_path / "final.mp4"
            _run_ffmpeg_merge(clip_files, final_path)

            # 3. Upload final.mp4 to GCS.
            gcs_key = f"{firebase_uid}/{project_slug}/final.mp4"
            store.put_object(gcs_key, final_path.read_bytes(), "video/mp4")

        # 4. Write gcs_final_path to Firestore project root doc.
        db.document(f"users/{firebase_uid}/projects/{project_slug}").set(
            {"gcs_final_path": gcs_key, "updated_at": SERVER_TIMESTAMP},
            merge=True,
        )

        # 5. Deduct credits atomically + update job + notify.
        deduct_credits(db, firebase_uid, "merge", "server")
        update_job(db, firebase_uid, job_id, "success", gcs_output_path=gcs_key)
        notify(db, firebase_uid, job_id, "merge", project_slug, "completed")
        logger.info("Merge job complete: job_id=%s", job_id)
    except Exception as e:
        logger.error("Merge job failed: job_id=%s error=%s", job_id, e, exc_info=True)
        update_job(db, firebase_uid, job_id, "failed", error_message=str(e)[:1024])
        deduct_credits(db, firebase_uid, "merge", "server", evt_status="refunded")
        notify(db, firebase_uid, job_id, "merge", project_slug, "failed")
