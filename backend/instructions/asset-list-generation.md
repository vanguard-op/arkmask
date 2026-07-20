# Asset List Generation

Analyze a story and produce a flat JSON array of all visual assets needed to realize it — characters, backgrounds, and objects — organized by scene.

## Input Format

`story` is either the full story text or a contiguous chunk of it (a fixed-size run of consecutive `# N` scenes, split by the caller so a single call never has to enumerate more than a handful of scenes at once — this keeps per-scene coverage reliable on long stories). Never assume `story` starts at scene 1 or ends at the story's last scene — walk exactly the scene(s) present in `story`, using each one's own `# N` heading number, and do not skip any of them. If this is a **re-extraction** on a project that already has assets — or a later chunk of the same story within one extraction run — you will also receive an `existing_assets` JSON block listing every asset already defined so far:

```json
{
  "story": "string — full story text, all scene blocks",
  "existing_assets": [
    {
      "name": "string",
      "type": "character" | "background" | "object",
      "description": "string",
      "scene_number": 0
    }
  ]
}
```

- `existing_assets` is omitted or empty on a first-time extraction (no assets exist yet for this project). Treat that case exactly as documented below with no special handling.
- When `existing_assets` is present and non-empty, every listed asset **already exists as a real, saved document** in the project — it is not a candidate entry in your output, it is ground truth you are extracting *against*. Read `## Existing-Assets Rules` below before producing output.

## Output Format

Produce a single JSON array:

```json
[
  {
    "name": "string",
    "description": "string",
    "type": "character" | "background" | "object",
    "scene_number": 0
  }
]
```

### Field Rules

**`name`**
- Use the asset's proper name as it appears or can be inferred from the story (e.g. `"elias"`, `"clockwork_emporium"`, `"chronosphere"`).
- Use snake_case, lowercase.
- If the asset is reused from a previous scene without modification, use a reference path: `"@/scenes/{scene_number}/{asset_name}"`. Example: `"@/scenes/0/elias"` means the character `elias` defined in scene 0 is reused here as-is.

**Derived reference (background/object extensions, subsections, or derivations)**
- Sometimes a `background` or `object` is not a full reuse and not a brand-new asset either — it is a **part, subsection, close-up, or extension of another existing background or object** (e.g. a specific corner of a shop that was already defined as a background, a drawer that is part of an already-defined workbench, a close-up of one engraved panel on the chronosphere).
- In this case, still set `name` to a reference path pointing at the **source asset it derives from**: `"@/scenes/{scene_number}/{source_asset_name}"`.
- Unlike an unchanged reuse, this entry **always gets a full, non-empty `description`** — write it as a complete, self-contained description of this specific derived asset (the corner, the drawer, the close-up), following the same rules as any other `description` (describe only the asset itself, no relational context).
- This tells downstream image-prompt generation two things at once: (1) generate a new image for this specific derived asset using its own description, and (2) attach/ground it visually to the referenced source asset so the derived asset's materials, style, and identity stay consistent with its parent.
- Use this pattern only when the derived asset is genuinely part of or extended from a specific, already-defined asset — not for a new background/object that merely resembles or sits near another one. If it's an unrelated new asset, give it its own plain `name` instead.

**`description`**
- Provide a rich visual description of the asset sufficient to generate an image standalone, without needing to look up the referenced asset.
- Describe **only the asset itself** — its appearance, materials, colors, shape, texture, expression, and state. Do not mention other assets, locations, or relationships (e.g. do not write "visible through the shop window" or "sitting on the workbench" or "holding the chronosphere").
- If the `name` is a reference (`@/scenes/...`) AND the asset appears unchanged, set `description` to `""`.
- If the `name` is a reference BUT the asset has been visually modified in this scene (different clothing, expression, lighting, state, etc.), write a **complete** description of the asset as it appears in this scene — take the base appearance from the referenced asset and bake the modifications into it. Do not describe only the delta. The description must be self-contained and paint the full picture of the asset as it looks right now.
- If the `name` is a reference used as a **derived reference** (see "Derived reference" rule above — a part/subsection/close-up/extension of a `background` or `object`), always write a full, non-empty description of that specific derived asset, even though it is a `background`/`object` type reference. This is the one case where a reference name still requires a complete description alongside it.
- For scene 0 (root) assets, always write a full description.

> **Variant discipline — avoid over-generating asset variants.**
> Only create a new variant (i.e. a reference entry with a non-empty description) when the visual change is **obvious and meaningful to a viewer** — something a person watching the story would immediately notice and that matters to the scene. Qualifying changes include: a completely different outfit, a major injury or physical transformation, a drastically different emotional state (e.g. sobbing vs. neutral), or a key prop visibly attached to or altering the character. Do **not** create variants for subtle shifts that a viewer would not consciously register: a slightly different posture, a minor facial expression change, ambient lighting tinting, or incidental repositioning. When in doubt, reuse the reference with `description: ""` rather than generating a variant.

**`type`**
- `"character"` — any person, creature, or animate entity with agency.
- `"background"` — the setting or environment of a scene (there is typically one per scene).
- `"object"` — any inanimate prop, device, or item that plays a role in the scene.

**`scene_number`**
- Integer starting at `0`.
- `0` is the **root scene** — use it for assets that appear across multiple scenes and need a canonical definition. Define them once here; reference them in later scenes.
- `1`, `2`, `3`, … correspond to numbered scenes in the story.
- Assign each asset to the scene where it is *first introduced* if it's a root asset, or to the scene where it appears if it is scene-specific.

## Existing-Assets Rules

Apply these rules only when `existing_assets` is present and non-empty (a re-extraction):

- **Never re-emit an existing asset.** Do not output an entry whose `name` matches (case-insensitively, ignoring the `@/scenes/{n}/` reference prefix) the `name` of any asset in `existing_assets`, at the same `scene_number`. This applies even for what would normally be a `description: ""` reference-reuse entry — an unmodified reuse of an asset that is already in `existing_assets` needs no new entry at all, because the real document already exists and nothing new needs to be written.
- **Existing assets are immutable input, not editable output.** You are not being asked to redefine, correct, merge, or improve any asset in `existing_assets` — even if the story text now reads differently than the asset's stored `description`. Leave them alone entirely.
- **Only extract what's missing.** Walk the story exactly as described in `## Extraction Process` below, but before adding an entry, check whether an equivalent asset (same identity, same `scene_number`) is already covered by `existing_assets`. Only output assets that are genuinely new or not yet represented — a character, background, or object the existing set does not already cover.
- **New reference targets still resolve against existing assets.** A brand-new scene-specific entry may still reference an *existing* root or prior-scene asset as its source (e.g. a new derived-reference background that extends an already-existing workbench asset). Use the normal `@/scenes/{scene_number}/{name}` reference syntax pointing at the existing asset's `name` — this is fine and expected; it is not the same as re-emitting that existing asset.
- **New variants of an existing asset are allowed.** If the story introduces a genuinely new, viewer-obvious visual change to an existing asset in a scene not already covered by `existing_assets` (per the "Variant discipline" rule above), output that as a new reference entry with a full description, following the normal variant rules — you are adding a new document, not touching the existing one.
- **When in doubt, omit.** If you are unsure whether an asset is already covered by `existing_assets`, do not emit it. Under-extraction on a re-run is cheap to fix with a follow-up manual asset add (see the product's manual asset management flow); duplicate or near-duplicate documents are more costly to clean up.

## Extraction Process

1. **Read the full story** before writing any output.
2. **Identify root assets**: characters and recurring objects/settings that appear in more than one scene. Define them in `scene_number: 0` with a complete description.
3. **Walk each scene** in order. For each scene:
   - Identify the background (setting/environment).
   - Identify all characters present.
   - Identify all significant objects (props that affect the narrative or are visually prominent).
   - Identify any `background`/`object` that is a part, subsection, close-up, or extension of an already-defined `background`/`object` (e.g. a specific shelf within an already-defined shop, a compartment inside an already-defined machine).
4. **Apply reference logic**:
   - If a root asset appears in a scene unchanged → use `@/scenes/0/{name}` with `description: ""`.
   - If a root asset appears with a visual change → use `@/scenes/0/{name}` with a new description.
   - If a non-root asset from a prior scene reappears unchanged → reference it with `@/scenes/{prior_scene}/{name}` and `description: ""`.
   - If a `background`/`object` is derived from, a subsection of, or an extension of an already-defined `background`/`object` (root or scene-specific) → reference the source asset with `@/scenes/{source_scene}/{source_name}` and always write a full, non-empty `description` of the derived asset itself (see "Derived reference" rule).
5. **Deduplicate**: do not list the same unmodified asset twice in the same scene.
6. **Order**: output root assets first (scene 0), then scene 1 assets, scene 2, and so on.

## Example

Given a story where an old watchmaker named Elias works in his shop across many scenes, and his granddaughter Lyra appears in scene 8:

```json
[
  {
    "name": "elias",
    "description": "An elderly man in his late 70s with deeply weathered skin and oil-stained hands. He wears a worn leather apron over a white linen shirt, round wire-rimmed glasses, and a gentle, contemplative expression.",
    "type": "character",
    "scene_number": 0
  },
  {
    "name": "clockwork_emporium",
    "description": "A narrow Victorian-era shop interior overflowing with clocks of every size — grandfather clocks, pocket watches under glass domes, cuckoo clocks on the walls. Warm amber lamp-light, dark wood shelves, scattered brass gears and tools on every surface.",
    "type": "background",
    "scene_number": 0
  },
  {
    "name": "chronosphere",
    "description": "A spherical brass device the size of a grapefruit. Its outer shell is engraved with gear-tooth patterns; a glass core at the center glows with a faint, swirling amber light. A single large button protrudes from the top.",
    "type": "object",
    "scene_number": 0
  },
  {
    "name": "@/scenes/0/elias",
    "description": "",
    "type": "character",
    "scene_number": 1
  },
  {
    "name": "@/scenes/0/clockwork_emporium",
    "description": "",
    "type": "background",
    "scene_number": 1
  },
  {
    "name": "workbench",
    "description": "A heavy oak workbench covered in watch parts, tiny screwdrivers, magnifying loupes on stands, and a bright focused lamp. The surface is scarred with years of use.",
    "type": "object",
    "scene_number": 1
  },
  {
    "name": "@/scenes/1/workbench",
    "description": "A narrow shallow drawer built into the front of the oak workbench, pulled halfway open. Inside, dozens of tiny brass gears and springs are sorted into small felt-lined compartments, catching the warm lamp-light.",
    "type": "object",
    "scene_number": 5
  },
  {
    "name": "lyra",
    "description": "An eight-year-old girl with rosy cheeks, bright curious eyes, and a wool coat with brass buttons. She wears a knit hat slightly askew and carries the energy of a child bursting with excitement.",
    "type": "character",
    "scene_number": 8
  },
  {
    "name": "@/scenes/0/elias",
    "description": "An elderly man in his late 70s with deeply weathered skin and oil-stained hands, now wearing a heavy wool overcoat and scarf over his usual attire, bundled for a cold winter night. His breath is faintly visible in the cold air. His expression is calm and reflective.",
    "type": "character",
    "scene_number": 17
  }
]
```

## Quality Checklist

Before outputting, verify:
- [ ] Every scene present in `story` (see "Input Format" — this may be the whole story or one chunk of it) has at least one background asset, even if it's only a `description: ""` reuse reference. Re-check this against the actual list of `# N` headings in `story` before finalizing — do not silently drop a scene's boilerplate reuse entry because it feels repetitive.
- [ ] Every named or clearly described character has an entry.
- [ ] Every narratively significant object has an entry.
- [ ] Root assets (scene 0) have full descriptions.
- [ ] References have `description: ""` unless a modification is described in the story, OR the reference is a derived reference (part/subsection/close-up/extension of a background/object), in which case it always has a full, non-empty description.
- [ ] Every variant (reference with a non-empty description) represents a change that a viewer would obviously and immediately notice — minor pose, expression, or lighting shifts are NOT sufficient grounds for a variant.
- [ ] No description mentions another asset, location, or relational context — each describes only the asset itself.
- [ ] `type` values are exactly `"character"`, `"background"`, or `"object"`.
- [ ] `scene_number` values are non-negative integers.
- [ ] Output is valid JSON wrapped in a ```json code block.
- [ ] If `existing_assets` was provided: no output entry duplicates an asset already in `existing_assets` (same `name`/reference target and `scene_number`) — including as a `description: ""` reuse entry — and every entry in the output represents a genuinely new or previously-uncovered asset.
