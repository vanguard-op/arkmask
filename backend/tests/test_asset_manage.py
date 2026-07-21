"""Unit tests for app.services.asset_manage — manual asset deletion helpers
(FEAT-037) and the `ref`-field-based transitive dependents scan (FEAT-013).
Uses lightweight fakes for the Firestore client rather than a live Firestore
instance, matching the pattern in test_scene_assets.py.
"""

import pytest

from app.services.asset_manage import (
    Dependent,
    build_asset_path,
    delete_asset,
    find_dependent_assets,
    parse_asset_path,
)


# ── parse_asset_path / build_asset_path ─────────────────────────────────────

def test_parse_asset_path_global():
    assert parse_asset_path("assets/palace") == (0, "palace")


def test_parse_asset_path_scene_local():
    assert parse_asset_path("scenes/2/assets/shade") == (2, "shade")


def test_parse_asset_path_invalid_raises():
    with pytest.raises(ValueError):
        parse_asset_path("not/a/valid/path/shape")


def test_build_asset_path_global():
    assert build_asset_path(0, "palace") == "assets/palace"


def test_build_asset_path_scene_local():
    assert build_asset_path(3, "shade") == "scenes/3/assets/shade"


def test_build_asset_path_is_inverse_of_parse():
    for path in ("assets/palace", "scenes/3/assets/shade"):
        assert build_asset_path(*parse_asset_path(path)) == path


# ── find_dependent_assets ────────────────────────────────────────────────────

class _FakeDoc:
    def __init__(self, doc_id: str, data: dict):
        self.id = doc_id
        self._data = data
        self.exists = True

    def to_dict(self) -> dict:
        return self._data


class _MissingDoc:
    exists = False


class _FakeCollection:
    def __init__(self, docs: list[_FakeDoc]):
        self._docs = docs

    def stream(self):
        return iter(self._docs)


class _FakeDocRef:
    def __init__(self, doc):
        self._doc = doc

    def get(self):
        return self._doc


class _FakeDb:
    """Maps a collection path string to a canned list of _FakeDoc, and a
    document path string to a canned _FakeDoc/_MissingDoc (for `ref` chain
    walks via app.services.asset_ref.ref_chain_paths)."""

    def __init__(
        self,
        collections: dict[str, list[_FakeDoc]],
        documents: dict[str, _FakeDoc] | None = None,
    ):
        self._collections = collections
        self._documents = documents or {}

    def collection(self, path: str) -> _FakeCollection:
        return _FakeCollection(self._collections.get(path, []))

    def document(self, path: str) -> _FakeDocRef:
        return _FakeDocRef(self._documents.get(path, _MissingDoc()))


def test_find_dependent_assets_finds_direct_global_and_scene_local_references():
    project_path = "users/uid1/projects/proj1"
    palace_variant = _FakeDoc(
        "palace-variant",
        {"name": "Palace (gold)", "type": "background", "description": "gold", "ref": "assets/palace"},
    )
    palace_ref = _FakeDoc(
        "palace-ref",
        {"name": "Palace", "type": "background", "description": "", "ref": "assets/palace"},
    )
    db = _FakeDb(
        collections={
            f"{project_path}/assets": [
                _FakeDoc("palace", {"name": "palace", "type": "background", "ref": None}),
                palace_variant,
            ],
            f"{project_path}/scenes": [_FakeDoc("2", {"scene_number": 2})],
            f"{project_path}/scenes/2/assets": [
                palace_ref,
                _FakeDoc("unrelated", {"name": "hero", "type": "character", "ref": None}),
            ],
        },
        documents={
            f"{project_path}/assets/palace": _FakeDoc(
                "palace", {"name": "palace", "type": "background", "ref": None}
            ),
        },
    )

    dependents = find_dependent_assets(db, "uid1", "proj1", "assets/palace")

    assert Dependent(asset_path="assets/palace-variant", name="Palace (gold)", ref="assets/palace") in dependents
    assert Dependent(asset_path="scenes/2/assets/palace-ref", name="Palace", ref="assets/palace") in dependents
    assert len(dependents) == 2


def test_find_dependent_assets_finds_transitive_chain():
    # scenes/3/assets/shade-v2 --ref--> scenes/2/assets/shade-v1 --ref--> assets/shade
    # Deleting assets/shade must find BOTH as dependents (FEAT-013/R-029).
    project_path = "users/uid1/projects/proj1"
    shade_v1 = _FakeDoc(
        "shade-v1", {"name": "Shade v1", "type": "character", "ref": "assets/shade"}
    )
    shade_v2 = _FakeDoc(
        "shade-v2", {"name": "Shade v2", "type": "character", "ref": "scenes/2/assets/shade-v1"}
    )
    db = _FakeDb(
        collections={
            f"{project_path}/assets": [
                _FakeDoc("shade", {"name": "shade", "type": "character", "ref": None}),
            ],
            f"{project_path}/scenes": [
                _FakeDoc("2", {"scene_number": 2}),
                _FakeDoc("3", {"scene_number": 3}),
            ],
            f"{project_path}/scenes/2/assets": [shade_v1],
            f"{project_path}/scenes/3/assets": [shade_v2],
        },
        documents={
            f"{project_path}/assets/shade": _FakeDoc(
                "shade", {"name": "shade", "type": "character", "ref": None}
            ),
            f"{project_path}/scenes/2/assets/shade-v1": shade_v1,
        },
    )

    dependents = find_dependent_assets(db, "uid1", "proj1", "assets/shade")

    paths = {d.asset_path for d in dependents}
    assert paths == {"scenes/2/assets/shade-v1", "scenes/3/assets/shade-v2"}


def test_find_dependent_assets_no_dependents_returns_empty():
    project_path = "users/uid1/projects/proj1"
    db = _FakeDb({
        f"{project_path}/assets": [_FakeDoc("palace", {"name": "palace", "type": "background", "ref": None})],
        f"{project_path}/scenes": [],
    })

    assert find_dependent_assets(db, "uid1", "proj1", "assets/palace") == []


def test_find_dependent_assets_stops_at_cycle_without_raising():
    # A malformed chain that cycles back on itself must not crash the scan —
    # it just never reaches the deletion target through that path.
    project_path = "users/uid1/projects/proj1"
    a = _FakeDoc("a", {"name": "A", "type": "character", "ref": "scenes/1/assets/b"})
    b = _FakeDoc("b", {"name": "B", "type": "character", "ref": "scenes/1/assets/a"})
    db = _FakeDb(
        collections={
            f"{project_path}/assets": [
                _FakeDoc("unrelated", {"name": "unrelated", "type": "object", "ref": None}),
            ],
            f"{project_path}/scenes": [_FakeDoc("1", {"scene_number": 1})],
            f"{project_path}/scenes/1/assets": [a, b],
        },
        documents={
            f"{project_path}/scenes/1/assets/a": a,
            f"{project_path}/scenes/1/assets/b": b,
        },
    )

    # "unrelated" is never in the cycle, so deleting it finds no dependents.
    assert find_dependent_assets(db, "uid1", "proj1", "assets/unrelated") == []


# ── delete_asset ─────────────────────────────────────────────────────────────

class _FakeDeleteDocRef:
    def __init__(self, deleted_paths: list[str], path: str):
        self._deleted_paths = deleted_paths
        self._path = path

    def delete(self):
        self._deleted_paths.append(self._path)


class _FakeDeleteDb:
    def __init__(self):
        self.deleted_paths: list[str] = []

    def document(self, path: str) -> _FakeDeleteDocRef:
        return _FakeDeleteDocRef(self.deleted_paths, path)


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
