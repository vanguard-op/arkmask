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
from app.services.media_store import MediaStore

logger = logging.getLogger(__name__)


def _run_ffmpeg_merge(clip_files: list[tuple[Path, dict]], output: Path) -> None:
    """
    Run FFmpeg to trim clips and concatenate with transitions.

    Strategy:
    - For hard_cut-only timelines: use the concat demuxer (fast, no full re-encode).
    - For fade_black / dissolve transitions: use filter_complex with xfade.

    Ported from backend/app/routers/generation.py::_run_ffmpeg_merge (the
    original inline implementation) — kept byte-for-byte equivalent so merge
    output doesn't change behavior when moving execution to this worker.
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
        # Slow path: filter_complex with xfade for non-hard-cut transitions.
        inputs: list[str] = []
        for clip_path, _ in clip_files:
            inputs += ["-i", str(clip_path)]

        filter_parts: list[str] = []
        for i, (_, entry) in enumerate(clip_files):
            filter_parts.append(
                f"[{i}:v]trim=start={entry['trim_in']}:end={entry['trim_out']},"
                f"setpts=PTS-STARTPTS[v{i}];"
                f"[{i}:a]atrim=start={entry['trim_in']}:end={entry['trim_out']},"
                f"asetpts=PTS-STARTPTS[a{i}]"
            )

        prev_v, prev_a = "v0", "a0"
        for i in range(1, len(clip_files)):
            _, prev_entry = clip_files[i - 1]
            trans = prev_entry["transition_to_next"]
            xfade_type = {
                "fade_black": "fadeblack",
                "dissolve": "dissolve",
            }.get(trans, "fade")
            duration = 0.5
            offset = (prev_entry["trim_out"] - prev_entry["trim_in"]) - duration
            out_v = f"xfv{i}" if i < len(clip_files) - 1 else "vout"
            out_a = f"xfa{i}" if i < len(clip_files) - 1 else "aout"
            filter_parts.append(
                f"[{prev_v}][v{i}]xfade=transition={xfade_type}"
                f":duration={duration}:offset={offset}[{out_v}];"
                f"[{prev_a}][a{i}]acrossfade=d={duration}[{out_a}]"
            )
            prev_v, prev_a = out_v, out_a

        filter_complex = ";".join(filter_parts)
        cmd = [
            "ffmpeg", "-y",
            *inputs,
            "-filter_complex", filter_complex,
            "-map", f"[{prev_v}]", "-map", f"[{prev_a}]",
            "-c:v", "libx264", "-preset", "fast", "-c:a", "aac",
            str(output),
        ]

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
