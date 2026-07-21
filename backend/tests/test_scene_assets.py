"""Unit tests for app.services.scene_assets — the server-side port of
SceneCubit's scene-text parsing and asset-resolution logic (see the module
docstring for why this exists).

Uses lightweight fakes for the Firestore client (document/collection
`.get()`/`.stream()` surface only) rather than a live Firestore instance —
these functions are pure data transforms once given Firestore-shaped input.
"""

from app.services.scene_assets import (
    ResolvedAsset,
    assets_ready_for_storyboard,
    get_generation_settings,
    get_scene_text,
    ordered_gcs_image_paths,
    parse_scene_text,
    resolve_scene_assets,
    to_asset_prompt_inputs,
)


# ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeDoc:
    def __init__(self, doc_id: str, data: dict | None):
        self.id = doc_id
        self._data = data

    @property
    def exists(self) -> bool:
        return self._data is not None

    def get(self, field: str = None):
        # Mirrors firebase_admin's DocumentSnapshot.get(field) subset access
        # used by generation.py (e.g. `doc.get("storyboard_body")`).
        if self._data is None:
            return None
        return self._data.get(field) if field else self._data

    def to_dict(self) -> dict | None:
        return self._data


class _FakeDocRef:
    def __init__(self, data: dict | None, doc_id: str = "doc"):
        self._data = data
        self._doc_id = doc_id

    def get(self):
        return _FakeDoc(self._doc_id, self._data)


class _FakeCollection:
    def __init__(self, docs: list[_FakeDoc]):
        self._docs = docs

    def stream(self):
        return iter(self._docs)


class _FakeFirestore:
    """Routes `.document(path)` / `.collection(path)` to canned fixtures by path."""

    def __init__(self, documents: dict[str, dict | None], collections: dict[str, list[_FakeDoc]]):
        self._documents = documents
        self._collections = collections

    def document(self, path: str) -> _FakeDocRef:
        return _FakeDocRef(self._documents.get(path), doc_id=path.rsplit("/", 1)[-1])

    def collection(self, path: str) -> _FakeCollection:
        return _FakeCollection(self._collections.get(path, []))


# ── parse_scene_text ─────────────────────────────────────────────────────────

def test_parse_scene_text_extracts_matching_heading():
    content = "# 1\nFirst scene body.\n\n# 2\nSecond scene body.\n"
    assert parse_scene_text(content, 1) == "First scene body."
    assert parse_scene_text(content, 2) == "Second scene body."


def test_parse_scene_text_no_headings_treated_as_scene_one():
    assert parse_scene_text("Just prose, no headings.", 1) == "Just prose, no headings."
    assert parse_scene_text("Just prose, no headings.", 2) == ""


def test_parse_scene_text_missing_scene_number_returns_empty():
    content = "# 1\nOnly scene one.\n"
    assert parse_scene_text(content, 3) == ""


def test_parse_scene_text_handles_none_and_empty():
    assert parse_scene_text(None, 1) == ""
    assert parse_scene_text("   ", 1) == ""


# ── resolve_scene_assets ─────────────────────────────────────────────────────

def _fs_with_scene_and_globals(scene_docs: list[_FakeDoc], global_docs: list[_FakeDoc]) -> _FakeFirestore:
    # Also register each doc under its individual document path — needed by
    # resolve_asset_ref_chain (app.services.asset_ref), which reads a `ref`
    # target via `db.document(path).get()`, not `db.collection(...).stream()`.
    documents = {
        f"users/u1/projects/p1/assets/{d.id}": d._data for d in global_docs
    }
    documents.update({
        f"users/u1/projects/p1/scenes/2/assets/{d.id}": d._data for d in scene_docs
    })
    return _FakeFirestore(
        documents=documents,
        collections={
            "users/u1/projects/p1/assets": global_docs,
            "users/u1/projects/p1/scenes/2/assets": scene_docs,
        },
    )


def test_resolve_scene_assets_orders_background_before_character_before_object():
    scene_docs = [
        _FakeDoc("a1", {"name": "sword", "description": "a blade", "type": "object", "prompt_body": "sword prompt", "gcs_image_path": "u1/p1/o.png"}),
        _FakeDoc("a2", {"name": "hero", "description": "a hero", "type": "character", "prompt_body": "hero prompt", "gcs_image_path": "u1/p1/c.png"}),
        _FakeDoc("a3", {"name": "castle", "description": "a castle", "type": "background", "prompt_body": "castle prompt", "gcs_image_path": "u1/p1/b.png"}),
    ]
    db = _fs_with_scene_and_globals(scene_docs, [])
    resolved = resolve_scene_assets(db, "u1", "p1", 2)
    assert [a.name for a in resolved] == ["castle", "hero", "sword"]


def test_resolve_scene_assets_pass_through_resolves_to_global_asset():
    # Global (scope 0) assets live in the project-level `assets` collection —
    # a `ref: "assets/hero"` resolves there.
    global_docs = [
        _FakeDoc("hero", {"name": "hero", "type": "character", "ref": None, "prompt_body": "the real hero prompt", "gcs_image_path": "u1/p1/hero.png"}),
    ]
    scene_docs = [
        # Pass-through: empty description, `ref` pointing at the global asset.
        _FakeDoc("ref1", {"name": "Hero", "ref": "assets/hero", "description": "", "type": None, "prompt_body": None, "gcs_image_path": None}),
    ]
    db = _fs_with_scene_and_globals(scene_docs, global_docs)
    resolved = resolve_scene_assets(db, "u1", "p1", 2)

    assert len(resolved) == 1
    asset = resolved[0]
    # Name stays the referencing document's own display name, but
    # prompt/image/type come from the referenced (terminal) asset — never
    # the (empty) scene-local fields.
    assert asset.name == "Hero"
    assert asset.prompt == "the real hero prompt"
    assert asset.gcs_image_path == "u1/p1/hero.png"
    assert asset.type == "character"


def test_resolve_scene_assets_pass_through_missing_ref_target_resolves_empty():
    scene_docs = [
        _FakeDoc("ref1", {"name": "Hero", "ref": "assets/hero", "description": ""}),
    ]
    global_docs = [
        _FakeDoc("hero", {"name": "hero", "type": "character", "ref": None, "prompt_body": "hero prompt", "gcs_image_path": "u1/p1/hero.png"}),
    ]
    db = _fs_with_scene_and_globals(scene_docs, global_docs)
    resolved = resolve_scene_assets(db, "u1", "p1", 2)
    assert resolved[0].prompt == "hero prompt"

    # No matching global asset at all -> resolves to empty/None, not a crash.
    db_missing = _fs_with_scene_and_globals(scene_docs, [])
    resolved_missing = resolve_scene_assets(db_missing, "u1", "p1", 2)
    assert resolved_missing[0].prompt == ""
    assert resolved_missing[0].gcs_image_path is None


def test_resolve_scene_assets_pass_through_resolves_to_non_root_source_scene():
    # Regression test: a character first introduced in a *non-root* scene
    # (e.g. scene 5) is never copied into the project-level `assets`
    # collection — only scene_number == 0 assets are (see
    # app.services.asset_writer.write_extracted_assets). A later scene's
    # pass-through `ref` into that scene must resolve against scene 5's own
    # `assets` subcollection, not the project-level one.
    db = _FakeFirestore(
        documents={
            "users/u1/projects/p1/scenes/5/assets/hero": {
                "name": "hero",
                "type": "character",
                "ref": None,
                "prompt_body": "scene 5 hero prompt",
                "gcs_image_path": "u1/p1/scene5-hero.png",
            },
        },
        collections={
            "users/u1/projects/p1/assets": [],  # no root assets at all
            "users/u1/projects/p1/scenes/6/assets": [
                _FakeDoc("ref1", {"name": "Hero", "ref": "scenes/5/assets/hero", "description": ""}),
            ],
        },
    )
    resolved = resolve_scene_assets(db, "u1", "p1", 6)

    assert len(resolved) == 1
    asset = resolved[0]
    assert asset.name == "Hero"
    assert asset.prompt == "scene 5 hero prompt"
    assert asset.gcs_image_path == "u1/p1/scene5-hero.png"
    assert asset.type == "character"


def test_resolve_scene_assets_variant_uses_own_fields_not_terminal_regardless_of_chain_depth():
    # ref chain: variant --ref--> mid --ref--> root (root has ref=None).
    # description is non-empty on the referencing doc -> variant -> uses its
    # OWN prompt/image/type, never the terminal's, no matter the hop count.
    db = _FakeFirestore(
        documents={
            "users/u1/projects/p1/assets/root": {
                "name": "root", "type": "character", "ref": None,
                "prompt_body": "root prompt", "gcs_image_path": "u1/p1/root.png",
            },
            "users/u1/projects/p1/scenes/2/assets/mid": {
                "name": "mid", "type": "character", "ref": "assets/root",
                "description": "", "prompt_body": None, "gcs_image_path": None,
            },
        },
        collections={
            "users/u1/projects/p1/scenes/3/assets": [
                _FakeDoc("variant1", {
                    "name": "Variant", "ref": "scenes/2/assets/mid",
                    "description": "wearing a different coat",
                    "type": "character",
                    "prompt_body": "variant's own prompt",
                    "gcs_image_path": "u1/p1/variant.png",
                }),
            ],
        },
    )
    resolved = resolve_scene_assets(db, "u1", "p1", 3)

    assert len(resolved) == 1
    asset = resolved[0]
    assert asset.name == "Variant"
    assert asset.prompt == "variant's own prompt"
    assert asset.gcs_image_path == "u1/p1/variant.png"


def test_resolve_scene_assets_broken_ref_chain_resolves_unready_not_raise():
    # A cyclic ref chain must not crash scene resolution — it resolves to an
    # "unready" asset (no prompt/image), which naturally fails
    # assets_ready_for_storyboard's gate.
    a = {"name": "A", "ref": "scenes/1/assets/b", "description": ""}
    b = {"name": "B", "ref": "scenes/1/assets/a", "description": ""}
    db = _FakeFirestore(
        documents={
            "users/u1/projects/p1/scenes/1/assets/a": a,
            "users/u1/projects/p1/scenes/1/assets/b": b,
        },
        collections={
            "users/u1/projects/p1/scenes/1/assets": [
                _FakeDoc("a", a),
            ],
        },
    )
    resolved = resolve_scene_assets(db, "u1", "p1", 1)
    assert len(resolved) == 1
    assert resolved[0].prompt == ""
    assert resolved[0].gcs_image_path is None


# ── assets_ready_for_storyboard ──────────────────────────────────────────────

def test_assets_ready_for_storyboard_requires_all_images():
    ready = [ResolvedAsset(name="a", prompt="p", gcs_image_path="path", type="object")]
    not_ready = [ResolvedAsset(name="a", prompt="p", gcs_image_path=None, type="object")]
    assert assets_ready_for_storyboard(ready) is True
    assert assets_ready_for_storyboard(not_ready) is False
    assert assets_ready_for_storyboard([]) is False  # empty scene is never "ready"


# ── to_asset_prompt_inputs / ordered_gcs_image_paths ─────────────────────────

def test_to_asset_prompt_inputs_carries_only_name_and_prompt():
    assets = [
        ResolvedAsset(name="hero", prompt="hero prompt", gcs_image_path="u1/hero.png", type="character"),
    ]
    inputs = to_asset_prompt_inputs(assets)
    assert len(inputs) == 1
    assert inputs[0].name == "hero"
    assert inputs[0].prompt == "hero prompt"
    assert not hasattr(inputs[0], "gcs_image_path")


def test_ordered_gcs_image_paths_skips_assets_without_images():
    assets = [
        ResolvedAsset(name="a", prompt="", gcs_image_path="u1/a.png", type="object"),
        ResolvedAsset(name="b", prompt="", gcs_image_path=None, type="object"),
        ResolvedAsset(name="c", prompt="", gcs_image_path="u1/c.png", type="object"),
    ]
    assert ordered_gcs_image_paths(assets) == ["u1/a.png", "u1/c.png"]


# ── get_scene_text / get_generation_settings ─────────────────────────────────

def test_get_scene_text_reads_story_content_from_project_doc():
    db = _FakeFirestore(
        documents={"users/u1/projects/p1": {"story_content": "# 1\nScene one.\n\n# 2\nScene two.\n"}},
        collections={},
    )
    assert get_scene_text(db, "u1", "p1", 2) == "Scene two."


def test_get_scene_text_missing_project_doc_returns_empty():
    db = _FakeFirestore(documents={}, collections={})
    assert get_scene_text(db, "u1", "p1", 1) == ""


def test_get_generation_settings_defaults_when_missing():
    db = _FakeFirestore(documents={}, collections={})
    art_style, subtitles = get_generation_settings(db, "u1", "p1")
    assert art_style == "painterly illustration with clean lines and rich color"
    assert subtitles is False


def test_get_generation_settings_reads_project_values():
    db = _FakeFirestore(
        documents={
            "users/u1/projects/p1": {
                "generation_settings": {"art_style": "noir", "video_subtitles": True},
            },
        },
        collections={},
    )
    art_style, subtitles = get_generation_settings(db, "u1", "p1")
    assert art_style == "noir"
    assert subtitles is True
