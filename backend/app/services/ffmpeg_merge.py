"""Builds the FFmpeg command for merging scene clips with trims + transitions.

Ported from the original on-device implementation
(`mobile/lib/features/editor/cubit/editor_cubit.dart::_buildFfmpegCommand`,
see git history at commit 376af06, before the Phase 3 migration moved
merging server-side) — NOT from the `xfade`-based version that briefly
replaced it in `backend/app/routers/generation.py` /
`workers/app/tasks/merge.py`. That `xfade` version reintroduced a bug the
original mobile implementation's own doc comment already named and worked
around: **`xfade` requires constant-frame-rate input and silently produces
black frames (or, as observed in production, fails outright with "current
rate of 1/0 is invalid") on AI-generated clips**, which frequently have
missing or variable frame-rate metadata.

None of the three transition types need `xfade` at all:

- **Hard Cut** — trim + concat, no filters (handled entirely by the
  concat-demuxer fast path in the caller — this module only builds the
  filter_complex command for timelines containing at least one non-hard-cut
  transition).
- **Fade to Black** — `fade=out` on clip A's tail + `fade=in` on clip B's
  head, applied in-place on each clip's own body segment, then concat.
- **Dissolve** — the tail of clip A and the head of clip B are extracted as
  a separate short overlap segment. Clip B's head is converted to RGBA and
  faded in from transparent, then `overlay`ed on top of clip A's tail
  (converted to yuv420p). Both streams are forced to the same constant
  frame rate (`fps=30`) *only within this small overlap segment* — not
  globally — so `overlay` receives matching frame counts; this is
  deliberately scoped to the two ~0.5s overlap clips, not applied to entire
  clip bodies, which stay at their native frame rate. The result is
  concatenated between clip A's body and clip B's body, producing a true
  simultaneous cross-dissolve without ever invoking `xfade`.

This module is shared (not duplicated) between
`backend/app/routers/generation.py` (local-dev fallback) and
`workers/app/tasks/merge.py` (the real Cloud Tasks production path) — the
same sharing arrangement as `app/services/scene_assets.py`. The previous
`xfade` version existed twice, independently, explicitly marked "kept
byte-for-byte equivalent" in a comment — exactly the kind of duplication
that let this exact regression slip in.
"""

from __future__ import annotations

from pathlib import Path

# Frame rate forced onto the two small overlap chunks (clip A's tail, clip
# B's head) that feed a dissolve's `overlay` filter — never applied to a
# clip's full body. Overlay (unlike xfade) does not itself require CFR
# input, but two streams with mismatched/variable frame rates being overlaid
# together can still drift or produce an inconsistent frame count across the
# overlap; forcing both sides to the same rate for just this short segment
# keeps them in lockstep. 30fps is a safe general-purpose default.
_DISSOLVE_OVERLAP_FPS = 30

# Default cross-transition duration, clamped below to at most 40% of either
# adjacent clip's trimmed length so a transition never consumes more of a
# clip than is actually available.
_DEFAULT_TRANSITION_DURATION = 0.5


def build_merge_filter_cmd(
    clip_files: list[tuple[Path, dict]],
    output: Path,
) -> list[str]:
    """Build the `ffmpeg` argv for a timeline containing at least one
    fade_black or dissolve transition (i.e. NOT all-hard-cut).

    Callers should use the concat-demuxer fast path instead when every gap
    is `hard_cut` (or there is only one clip) — that path needs no filters
    at all and is unaffected by anything in this module.

    Each entry in `clip_files` is `(clip_path, entry)` where `entry` has:
        trim_in: float, trim_out: float, transition_to_next: str
            ('hard_cut' | 'fade_black' | 'dissolve') — describes the
            transition from this clip to the *next* one; ignored on the
            last entry.
    """
    n = len(clip_files)
    if n == 0:
        raise ValueError("No clips to merge.")

    # ── 1. Compute each gap's transition duration ──────────────────────────
    # Clamped to 40% of each adjacent clip's trimmed duration so a
    # transition never consumes more of a clip than is available.
    gap_fd: dict[int, float] = {}
    for g in range(n - 1):
        gap_type = clip_files[g][1]["transition_to_next"]
        if gap_type == "hard_cut":
            gap_fd[g] = 0.0
            continue
        duration_a = clip_files[g][1]["trim_out"] - clip_files[g][1]["trim_in"]
        duration_b = clip_files[g + 1][1]["trim_out"] - clip_files[g + 1][1]["trim_in"]
        gap_fd[g] = min(
            _DEFAULT_TRANSITION_DURATION,
            duration_a * 0.4,
            duration_b * 0.4,
        )

    inputs: list[str] = []
    for clip_path, _ in clip_files:
        inputs += ["-i", str(clip_path)]

    filter_parts: list[str] = []
    v_labels: list[str] = []
    a_labels: list[str] = []
    seg = 0  # increments for every output segment (body or dissolve overlap)

    for i in range(n):
        entry = clip_files[i][1]
        in_pt = entry["trim_in"]
        out_pt = entry["trim_out"]

        prev_type = clip_files[i - 1][1]["transition_to_next"] if i > 0 else "hard_cut"
        next_type = entry["transition_to_next"] if i < n - 1 else "hard_cut"
        prev_fd = gap_fd[i - 1] if i > 0 else 0.0
        next_fd = gap_fd[i] if i < n - 1 else 0.0

        # Body of this clip. Dissolve overlaps "consume" the ends, so shrink.
        body_in = in_pt + (prev_fd if prev_type == "dissolve" else 0.0)
        body_out = out_pt - (next_fd if next_type == "dissolve" else 0.0)

        # Fade-to-black fades live on the body (dissolve fades live in the
        # separate overlap segment built below instead).
        fade_in_dur = prev_fd if prev_type == "fade_black" else 0.0
        fade_out_dur = next_fd if next_type == "fade_black" else 0.0

        # ── Body segment ────────────────────────────────────────────────
        if body_out > body_in + 0.001:
            body_dur = body_out - body_in
            vl, al = f"s{seg}v", f"s{seg}a"
            in_s, out_s = f"{body_in:.4f}", f"{body_out:.4f}"

            v_fade_in = f",fade=t=in:st=0:d={fade_in_dur:.4f}" if fade_in_dur > 0 else ""
            fo_st = f"{(body_dur - fade_out_dur):.4f}"
            v_fade_out = (
                f",fade=t=out:st={fo_st}:d={fade_out_dur:.4f}" if fade_out_dur > 0 else ""
            )
            filter_parts.append(
                f"[{i}:v]trim=start={in_s}:end={out_s},setpts=PTS-STARTPTS"
                f"{v_fade_in}{v_fade_out},format=yuv420p[{vl}];"
            )

            a_fade_in = f",afade=t=in:st=0:d={fade_in_dur:.4f}" if fade_in_dur > 0 else ""
            a_fade_out = (
                f",afade=t=out:st={fo_st}:d={fade_out_dur:.4f}" if fade_out_dur > 0 else ""
            )
            filter_parts.append(
                f"[{i}:a]atrim=start={in_s}:end={out_s},asetpts=PTS-STARTPTS"
                f"{a_fade_in}{a_fade_out}[{al}];"
            )

            v_labels.append(f"[{vl}]")
            a_labels.append(f"[{al}]")
            seg += 1

        # ── Dissolve segment (inserted between clip[i] body and clip[i+1] body) ─
        # Overlay B (fading in from transparent) on top of A for the overlap
        # duration — a true simultaneous cross-dissolve without xfade.
        if next_type == "dissolve" and i < n - 1:
            fd = next_fd
            fd_s = f"{fd:.4f}"
            next_entry = clip_files[i + 1][1]
            tail_in_s, tail_out_s = f"{(out_pt - fd):.4f}", f"{out_pt:.4f}"
            head_in_s = f"{next_entry['trim_in']:.4f}"
            head_out_s = f"{(next_entry['trim_in'] + fd):.4f}"
            vl, al = f"s{seg}v", f"s{seg}a"

            # Video: A_tail at yuv420p (base) + B_head fading in as rgba
            # (overlay). fps normalises both streams to the same frame rate
            # so overlay receives matching frame counts over the overlap.
            filter_parts.append(
                f"[{i}:v]trim=start={tail_in_s}:end={tail_out_s},setpts=PTS-STARTPTS,"
                f"fps={_DISSOLVE_OVERLAP_FPS},scale=trunc(iw/2)*2:trunc(ih/2)*2,"
                f"format=yuv420p[dv{seg}base];"
            )
            filter_parts.append(
                f"[{i + 1}:v]trim=start={head_in_s}:end={head_out_s},setpts=PTS-STARTPTS,"
                f"fps={_DISSOLVE_OVERLAP_FPS},scale=trunc(iw/2)*2:trunc(ih/2)*2,"
                f"format=rgba,fade=t=in:st=0:d={fd_s}:alpha=1[dv{seg}top];"
            )
            filter_parts.append(
                f"[dv{seg}base][dv{seg}top]overlay=format=auto,format=yuv420p[{vl}];"
            )

            # Audio: A_tail fades out, B_head fades in, amix combines them.
            filter_parts.append(
                f"[{i}:a]atrim=start={tail_in_s}:end={tail_out_s},asetpts=PTS-STARTPTS,"
                f"afade=t=out:st=0:d={fd_s}[da{seg}a];"
            )
            filter_parts.append(
                f"[{i + 1}:a]atrim=start={head_in_s}:end={head_out_s},asetpts=PTS-STARTPTS,"
                f"afade=t=in:st=0:d={fd_s}[da{seg}b];"
            )
            filter_parts.append(
                f"[da{seg}a][da{seg}b]amix=inputs=2:normalize=0:duration=longest[{al}];"
            )

            v_labels.append(f"[{vl}]")
            a_labels.append(f"[{al}]")
            seg += 1

    # ── Concat all collected segments ───────────────────────────────────────
    n_seg = len(v_labels)
    pairs = "".join(f"{v_labels[k]}{a_labels[k]}" for k in range(n_seg))
    filter_complex = "".join(filter_parts) + f"{pairs}concat=n={n_seg}:v=1:a=1[vout][aout]"

    return [
        "ffmpeg", "-y",
        *inputs,
        "-filter_complex", filter_complex,
        "-map", "[vout]", "-map", "[aout]",
        # CRF 18 — near-source quality (default CRF 23 is noticeably softer
        # than the high-bitrate clips produced by AI video generators).
        "-c:v", "libx264", "-crf", "18", "-preset", "fast",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        str(output),
    ]
