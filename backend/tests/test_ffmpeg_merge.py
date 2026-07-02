"""Unit tests for app.services.ffmpeg_merge — the no-`xfade` transition
builder ported from the original on-device implementation (see that
module's docstring).

Pure string/list assertions against the generated ffmpeg argv — no ffmpeg
binary is invoked.
"""

from pathlib import Path

from app.services.ffmpeg_merge import build_merge_filter_cmd


def _filter_complex(cmd: list[str]) -> str:
    return cmd[cmd.index("-filter_complex") + 1]


def test_dissolve_never_uses_xfade():
    """The whole point of this module: xfade requires constant-frame-rate
    input and fails outright ("current rate of 1/0 is invalid") on
    AI-generated clips with missing/variable frame-rate metadata."""
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 4.0, "transition_to_next": "dissolve"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 3.0, "transition_to_next": "hard_cut"}),
    ]
    fc = _filter_complex(build_merge_filter_cmd(clips, Path("out.mp4")))
    assert "xfade" not in fc
    assert "overlay=format=auto" in fc
    assert "amix=inputs=2" in fc


def test_dissolve_overlap_fps_is_scoped_not_global():
    """fps=30 must appear only inside the small dissolve overlap segment
    (bounded by the transition duration), never on a clip's full body —
    forcing CFR on entire AI-generated clips was the earlier (wrong) fix."""
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 4.0, "transition_to_next": "dissolve"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 3.0, "transition_to_next": "hard_cut"}),
    ]
    fc = _filter_complex(build_merge_filter_cmd(clips, Path("out.mp4")))
    # Body segments (the non-overlap majority of each clip) must not carry fps=.
    body_segment = fc.split(";")[0]
    assert "fps=" not in body_segment
    # But the dissolve overlap chunks (dvNbase / dvNtop) must.
    assert "fps=30" in fc
    assert fc.count("fps=30") == 2  # once for A's tail, once for B's head


def test_fade_black_applies_fade_in_place_no_xfade():
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "fade_black"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "hard_cut"}),
    ]
    fc = _filter_complex(build_merge_filter_cmd(clips, Path("out.mp4")))
    assert "xfade" not in fc
    assert "fade=t=out" in fc
    assert "fade=t=in" in fc
    assert "afade=t=out" in fc
    assert "afade=t=in" in fc


def test_mixed_fade_black_and_dissolve_three_clips():
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "fade_black"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "dissolve"}),
        (Path("c.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "hard_cut"}),
    ]
    cmd = build_merge_filter_cmd(clips, Path("out.mp4"))
    fc = _filter_complex(cmd)
    assert "xfade" not in fc
    # 4 segments total: A body, B body, dissolve overlap, C body.
    assert "concat=n=4:v=1:a=1[vout][aout]" in fc
    assert cmd[cmd.index("-map") + 1] == "[vout]"


def test_transition_duration_clamped_to_40_percent_of_shorter_clip():
    """A very short clip (1s) adjacent to a dissolve must not let the 0.5s
    default transition consume more than 40% of it."""
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 1.0, "transition_to_next": "dissolve"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 5.0, "transition_to_next": "hard_cut"}),
    ]
    fc = _filter_complex(build_merge_filter_cmd(clips, Path("out.mp4")))
    # Clamped duration = min(0.5, 1.0*0.4, 5.0*0.4) = 0.4, not 0.5.
    assert "d=0.4000" in fc
    assert "d=0.5000" not in fc


def test_all_hard_cut_is_not_this_module_concern():
    """build_merge_filter_cmd is only for timelines with >=1 non-hard-cut
    transition — callers use the concat demuxer fast path otherwise. Sanity
    check that even a nominal call still produces a valid, xfade-free command
    (defensive; real callers never invoke this for all-hard-cut timelines)."""
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 3.0, "transition_to_next": "hard_cut"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 3.0, "transition_to_next": "hard_cut"}),
    ]
    fc = _filter_complex(build_merge_filter_cmd(clips, Path("out.mp4")))
    assert "xfade" not in fc
    assert "concat=n=2:v=1:a=1[vout][aout]" in fc


def test_output_encoding_flags():
    clips = [
        (Path("a.mp4"), {"trim_in": 0.0, "trim_out": 4.0, "transition_to_next": "dissolve"}),
        (Path("b.mp4"), {"trim_in": 0.0, "trim_out": 3.0, "transition_to_next": "hard_cut"}),
    ]
    cmd = build_merge_filter_cmd(clips, Path("out.mp4"))
    assert "-crf" in cmd and cmd[cmd.index("-crf") + 1] == "18"
    assert "-movflags" in cmd and cmd[cmd.index("-movflags") + 1] == "+faststart"
    assert cmd[-1] == "out.mp4"


def test_empty_clip_list_raises():
    import pytest
    with pytest.raises(ValueError):
        build_merge_filter_cmd([], Path("out.mp4"))
