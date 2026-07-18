"""Unit tests for app.services.asset_manage — manual asset deletion helpers
(FEAT-037). Uses lightweight fakes for the Firestore client rather than a
live Firestore instance, matching the pattern in test_scene_assets.py.
"""

import pytest

from app.services.asset_manage import (
    Dependent,
    delete_asset,
    find_dependent_assets,
    parse_asset_path,
    reference_name_for,
)


# ── parse_asset_path / reference_name_for ───────────────────────────────────

def test_parse_asset_path_global():
    assert parse_asset_path("assets/palace") == (0, "palace")


def test_parse_asset_path_scene_local():
    assert parse_asset_path("scenes/2/assets/shade") == (2, "shade")


def test_parse_asset_path_invalid_raises():
    with pytest.raises(ValueError):
        parse_asset_path("not/a/valid/path/shape")


def test_reference_name_for_global():
    assert reference_name_for("assets/palace") == "@/scenes/0/palace"


def test_reference_name_for_scene_local():
    assert reference_name_for("scenes/3/assets/shade") == "@/scenes/3/shade"


# ── find_dependent_assets ────────────────────────────────────────────────────

class _FakeDoc:
    def __init__(self, doc_id: str, data: dict):
        self.id = doc_id
        self._data = data

    def to_dict(self) -> dict:
        return self._data


class _FakeCollection:
    def __init__(self, docs: list[_FakeDoc]):
        self._docs = docs

    def stream(self):
        return iter(self._docs)


class _FakeDb:
    """Maps a collection path string to a canned list of _FakeDoc."""

    def __init__(self, collections: dict[str, list[_FakeDoc]]):
        self._collections = collections

    def collection(self, path: str) -> _FakeCollection:
        return _FakeCollection(self._collections.get(path, []))


def test_find_dependent_assets_finds_global_and_scene_local_references():
    project_path = "users/uid1/projects/proj1"
    db = _FakeDb({
        f"{project_path}/assets": [
            _FakeDoc("palace", {"name": "palace", "type": "background"}),
            _FakeDoc("palace-variant", {"name": "@/scenes/0/palace", "type": "background", "description": "gold"}),
        ],
        f"{project_path}/scenes": [
            _FakeDoc("2", {"scene_number": 2}),
        ],
        f"{project_path}/scenes/2/assets": [
            _FakeDoc("palace-ref", {"name": "@/scenes/0/palace", "type": "background", "description": ""}),
            _FakeDoc("unrelated", {"name": "hero", "type": "character"}),
        ],
    })

    dependents = find_dependent_assets(db, "uid1", "proj1", "assets/palace")

    assert Dependent(asset_path="assets/palace-variant", name="@/scenes/0/palace") in dependents
    assert Dependent(asset_path="scenes/2/assets/palace-ref", name="@/scenes/0/palace") in dependents
    assert len(dependents) == 2


def test_find_dependent_assets_no_dependents_returns_empty():
    project_path = "users/uid1/projects/proj1"
    db = _FakeDb({
        f"{project_path}/assets": [_FakeDoc("palace", {"name": "palace", "type": "background"})],
        f"{project_path}/scenes": [],
    })

    assert find_dependent_assets(db, "uid1", "proj1", "assets/palace") == []


# ── delete_asset ─────────────────────────────────────────────────────────────

class _FakeDocRef:
    def __init__(self, deleted_paths: list[str], path: str):
        self._deleted_paths = deleted_paths
        self._path = path

    def delete(self):
        self._deleted_paths.append(self._path)


class _FakeDeleteDb:
    def __init__(self):
        self.deleted_paths: list[str] = []

    def document(self, path: str) -> _FakeDocRef:
        return _FakeDocRef(self.deleted_paths, path)


class _FakeMediaStore:
    def __init__(self):
        self.deleted_prefixes: list[str] = []

    def delete_prefix(self, prefix: str) -> None:
        self.deleted_prefixes.append(prefix)


def test_delete_asset_removes_firestore_doc_and_gcs_prefix():
    db = _FakeDeleteDb()
    store = _FakeMediaStore()

    delete_asset(db, store, "uid1", "proj1", "assets/palace")

    assert db.deleted_paths == ["users/uid1/projects/proj1/assets/palace"]
    assert store.deleted_prefixes == ["uid1/proj1/assets/palace/"]
