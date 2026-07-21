"""Unit tests for app.services.asset_ref — the shared recursive `ref`-chain
resolver used by both app.services.scene_assets and app.services.asset_manage.
"""

import pytest

from app.services.asset_ref import (
    CycleDetectedError,
    MaxDepthExceededError,
    ref_chain_paths,
    resolve_asset_ref_chain,
)


class _FakeDoc:
    def __init__(self, data: dict | None):
        self._data = data

    @property
    def exists(self) -> bool:
        return self._data is not None

    def to_dict(self):
        return self._data


class _FakeDocRef:
    def __init__(self, data: dict | None):
        self._data = data

    def get(self):
        return _FakeDoc(self._data)


class _FakeDb:
    def __init__(self, documents: dict[str, dict]):
        self._documents = documents

    def document(self, path: str) -> _FakeDocRef:
        # path is "{project_path}/{asset_path}" — strip the project_path
        # prefix the same way the real Firestore client would resolve it,
        # by looking up the raw suffix in our canned map.
        for key, data in self._documents.items():
            if path.endswith(key):
                return _FakeDocRef(data)
        return _FakeDocRef(None)


PROJECT_PATH = "users/u1/projects/p1"


def test_resolve_terminal_asset_with_no_ref():
    db = _FakeDb({"assets/hero": {"name": "hero", "ref": None, "prompt_body": "hero prompt"}})
    resolved = resolve_asset_ref_chain(db, PROJECT_PATH, "assets/hero")
    assert resolved.exists is True
    assert resolved.asset_path == "assets/hero"
    assert resolved.data["prompt_body"] == "hero prompt"
    assert resolved.hops == 0


def test_resolve_follows_multi_hop_chain_to_terminal():
    db = _FakeDb({
        "scenes/3/assets/variant": {"name": "variant", "ref": "scenes/2/assets/mid"},
        "scenes/2/assets/mid": {"name": "mid", "ref": "assets/root"},
        "assets/root": {"name": "root", "ref": None, "prompt_body": "root prompt"},
    })
    resolved = resolve_asset_ref_chain(db, PROJECT_PATH, "scenes/3/assets/variant")
    assert resolved.exists is True
    assert resolved.asset_path == "assets/root"
    assert resolved.data["prompt_body"] == "root prompt"
    assert resolved.hops == 2


def test_resolve_missing_target_returns_not_exists():
    db = _FakeDb({})
    resolved = resolve_asset_ref_chain(db, PROJECT_PATH, "assets/ghost")
    assert resolved.exists is False


def test_resolve_dangling_ref_mid_chain_returns_not_exists():
    db = _FakeDb({
        "assets/a": {"name": "a", "ref": "assets/deleted"},
    })
    resolved = resolve_asset_ref_chain(db, PROJECT_PATH, "assets/a")
    assert resolved.exists is False


def test_resolve_raises_cycle_detected_error():
    db = _FakeDb({
        "assets/a": {"name": "a", "ref": "assets/b"},
        "assets/b": {"name": "b", "ref": "assets/a"},
    })
    with pytest.raises(CycleDetectedError):
        resolve_asset_ref_chain(db, PROJECT_PATH, "assets/a")


def test_resolve_raises_max_depth_exceeded_for_long_non_cyclic_chain():
    # 15 distinct hops, never repeating a path — cycle detection alone
    # wouldn't catch this, so the explicit depth cap must.
    documents = {}
    for i in range(15):
        documents[f"assets/a{i}"] = {"name": f"a{i}", "ref": f"assets/a{i + 1}"}
    documents["assets/a15"] = {"name": "a15", "ref": None}
    db = _FakeDb(documents)
    with pytest.raises(MaxDepthExceededError):
        resolve_asset_ref_chain(db, PROJECT_PATH, "assets/a0")


def test_ref_chain_paths_stops_at_cycle_without_raising():
    db = _FakeDb({
        "assets/a": {"name": "a", "ref": "assets/b"},
        "assets/b": {"name": "b", "ref": "assets/a"},
    })
    paths = ref_chain_paths(db, PROJECT_PATH, "assets/a")
    assert paths == ["assets/a", "assets/b"]


def test_ref_chain_paths_includes_every_hop_to_terminal():
    db = _FakeDb({
        "scenes/2/assets/mid": {"name": "mid", "ref": "assets/root"},
        "assets/root": {"name": "root", "ref": None},
    })
    paths = ref_chain_paths(db, PROJECT_PATH, "scenes/2/assets/mid")
    assert paths == ["scenes/2/assets/mid", "assets/root"]
