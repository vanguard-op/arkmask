"""Unit tests for app.services.scene_progress.write_video_result.

Exercises the `@transactional`-decorated function's underlying logic
(`.to_wrap`, the raw undecorated callable) against a lightweight fake
Firestore transaction — real `Transaction` objects require a live Firestore
client to construct, but the write_video_result logic itself only calls
`transaction.get(...)`, `.set(...)`, and `.update(...)`, so a fake covering
just that surface is sufficient and avoids needing a Firestore emulator.
"""

from app.services.scene_progress import write_video_result


class _FakeSnapshot:
    def __init__(self, data: dict | None):
        self._data = data

    def to_dict(self):
        return self._data


class _FakeRef:
    """Minimal stand-in for a Firestore DocumentReference — just enough
    identity (`path`) for assertions on which ref a given call targeted."""

    def __init__(self, path: str, data: dict | None = None):
        self.path = path
        self._data = data


class _FakeTransaction:
    """Minimal stand-in for a Firestore Transaction — write_video_result
    only ever calls `.set(...)` / `.update(...)` on it; the read happens via
    `scene_ref.get(transaction=...)` (see `_make_scene_ref`), not via a
    `transaction.get(...)` method, so this fake doesn't need one either."""

    def __init__(self, existing_scene_data: dict | None):
        self._existing_scene_data = existing_scene_data
        self.set_calls: list[tuple[_FakeRef, dict]] = []
        self.update_calls: list[tuple[_FakeRef, dict]] = []

    def set(self, ref, data, merge=False):
        self.set_calls.append((ref, data))

    def update(self, ref, data):
        self.update_calls.append((ref, data))


def _make_scene_ref(path: str, existing_data: dict | None):
    """Builds a fake scene DocumentReference whose `.get(transaction=...)`
    returns a snapshot of `existing_data`, matching the real
    `scene_ref.get(transaction=transaction)` call in write_video_result."""
    ref = _FakeRef(path)
    ref.get = lambda transaction=None: _FakeSnapshot(existing_data)
    return ref


def test_first_completion_increments_completed_scene_count():
    """gcs_video_path was previously unset -> this is a first completion."""
    transaction = _FakeTransaction(existing_scene_data={})
    scene_ref = _make_scene_ref("scenes/1", existing_data={})
    project_ref = _FakeRef("projects/p1")

    write_video_result.to_wrap(transaction, scene_ref, project_ref, "u/p1/scenes/1/video.mp4")

    assert len(transaction.set_calls) == 1
    set_ref, set_data = transaction.set_calls[0]
    assert set_ref is scene_ref
    assert set_data["gcs_video_path"] == "u/p1/scenes/1/video.mp4"

    assert len(transaction.update_calls) == 1
    update_ref, update_data = transaction.update_calls[0]
    assert update_ref is project_ref
    # Increment is a sentinel object, not a plain int — just check the key exists.
    assert "completed_scene_count" in update_data


def test_regeneration_does_not_double_increment():
    """gcs_video_path was already set -> this is a regeneration, not a new
    completion; completed_scene_count must NOT be touched again."""
    transaction = _FakeTransaction(existing_scene_data={"gcs_video_path": "old/path.mp4"})
    scene_ref = _make_scene_ref("scenes/1", existing_data={"gcs_video_path": "old/path.mp4"})
    project_ref = _FakeRef("projects/p1")

    write_video_result.to_wrap(transaction, scene_ref, project_ref, "u/p1/scenes/1/video.mp4")

    assert len(transaction.set_calls) == 1
    _, set_data = transaction.set_calls[0]
    assert set_data["gcs_video_path"] == "u/p1/scenes/1/video.mp4"

    # No project update at all on regeneration.
    assert transaction.update_calls == []


def test_missing_scene_doc_treated_as_first_completion():
    """A brand new scene doc (doesn't exist yet, to_dict() returns None)
    must still be treated as a first completion, not crash."""
    transaction = _FakeTransaction(existing_scene_data=None)
    scene_ref = _make_scene_ref("scenes/1", existing_data=None)
    project_ref = _FakeRef("projects/p1")

    write_video_result.to_wrap(transaction, scene_ref, project_ref, "u/p1/scenes/1/video.mp4")

    assert len(transaction.update_calls) == 1
