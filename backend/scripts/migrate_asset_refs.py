"""
One-time data migration for the Asset Reference Model change
(docs/ArkMask/schema.md "Global Asset Document", docs/ArkMask/risk_log.md
R-025/R-029, 2026-07-21 changelog).

Before this change, an asset *document's* `name` field was overloaded: a
plain string meant an independent asset, while `"@/scenes/{N}/{base_name}"`
meant a reference to another asset, resolved by string-parsing `name` itself
(see the now-removed `app.services.scene_assets._parse_reference` and
`app.services.asset_manage.reference_name_for`). This conflated an asset's
*display label* with its *reference target* and made resolution ambiguous
whenever a chain crossed scenes non-monotonically.

After this change, every asset document has two separate fields:
  - `name` (str)       — display label only.
  - `ref` (str | None) — 'assets/<slug>' or 'scenes/<N>/assets/<slug>', or
                          null for an independent asset.

NOTE — this is a *Firestore document* migration, unrelated to the separate
AI extraction *output* contract change in
`backend/instructions/asset-list-generation.md` (model now emits a
structured `ref: {scene_number, name} | null` field instead of encoding a
reference into its own `name` string). `app.services.asset_writer` already
translates whatever the AI returns into the clean `name`/`ref` Firestore
shape before every `batch.set()` — a raw `"@/scenes/N/base"` string is never
itself written to Firestore by that path, regardless of which AI contract
version produced it. The only documents this script needs to touch are ones
persisted *before the Firestore schema split existed at all* (i.e. written
under the original overloaded `name`-only schema, pre-dating both the schema
split and today's AI contract wording change) — a strictly older, disjoint
format from anything the AI has ever emitted post-split.

This script walks every existing asset document project-wide (via a
Firestore collection-group query on `assets`, which matches both the
project-level `assets/` subcollection and every `scenes/{n}/assets/`
subcollection regardless of nesting) and, for any document whose legacy
`name` matches the old `"@/scenes/{N}/{base_name}"` convention, rewrites it:
  - `name`  -> just `{base_name}` (the trailing segment).
  - `ref`   -> the resolved `assets/<slug>` or `scenes/<N>/assets/<slug>`
              asset_path, where `<slug>` is derived by slugifying
              `{base_name}` (mirrors `app.services.asset_writer._slugify`
              exactly, so the resolved `ref` always matches how that source
              asset's own document was actually keyed).

Documents that do not match the legacy convention (already-independent
assets, or documents already migrated — `ref` present) are left untouched.

Usage:

    # Dry run (prints what would change, writes nothing):
    python scripts/migrate_asset_refs.py --dry-run

    # Apply the migration:
    python scripts/migrate_asset_refs.py

Requires Firebase Admin credentials on the environment (same as the rest of
the backend — GOOGLE_APPLICATION_CREDENTIALS or the bundled service account
JSON used by app.dependencies._firestore).
"""

from __future__ import annotations

import argparse
import re
import sys

# Reuse the exact same slugify function the extraction worker uses, so a
# migrated `ref` always matches the slug the source asset was actually
# written under.
from app.services.asset_writer import _slugify

_LEGACY_REF_RE = re.compile(r"^@/scenes/(\d+)/(.+)$")


def _resolve_ref_path(scope: int, base_name: str) -> str:
    slug = _slugify(base_name)
    return f"assets/{slug}" if scope == 0 else f"scenes/{scope}/assets/{slug}"


def migrate(dry_run: bool = False) -> int:
    """Runs the migration. Returns the number of documents migrated
    (or, for a dry run, that *would* be migrated)."""
    # Imported lazily so `--help` works without Firebase credentials configured.
    from google.cloud import firestore

    db = firestore.Client()
    migrated = 0

    # collection_group matches EVERY subcollection literally named "assets"
    # regardless of nesting depth — this is what lets a single query reach
    # both `users/{uid}/projects/{slug}/assets` and every
    # `users/{uid}/projects/{slug}/scenes/{n}/assets` without enumerating
    # users/projects/scenes by hand.
    for doc in db.collection_group("assets").stream():
        data = doc.to_dict() or {}
        name = data.get("name")
        if not isinstance(name, str):
            continue

        match = _LEGACY_REF_RE.match(name)
        if not match:
            continue  # Already independent, or already migrated.

        scope = int(match.group(1))
        base_name = match.group(2)
        ref_path = _resolve_ref_path(scope, base_name)

        migrated += 1
        prefix = "[dry-run] " if dry_run else ""
        print(f"{prefix}{doc.reference.path}: name={name!r} -> name={base_name!r}, ref={ref_path!r}")

        if not dry_run:
            doc.reference.update({"name": base_name, "ref": ref_path})

    return migrated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would change without writing anything.",
    )
    args = parser.parse_args()

    count = migrate(dry_run=args.dry_run)
    verb = "Would migrate" if args.dry_run else "Migrated"
    print(f"{verb} {count} asset document(s).")
    if count == 0:
        sys.exit(0)


if __name__ == "__main__":
    main()
