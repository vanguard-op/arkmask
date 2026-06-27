# Asset List Generation

Analyze a story and produce a flat JSON array of all visual assets needed to realize it — characters, backgrounds, and objects — organized by scene.

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

**`description`**
- Provide a rich visual description of the asset sufficient to generate an image standalone, without needing to look up the referenced asset.
- Describe **only the asset itself** — its appearance, materials, colors, shape, texture, expression, and state. Do not mention other assets, locations, or relationships (e.g. do not write "visible through the shop window" or "sitting on the workbench" or "holding the chronosphere").
- If the `name` is a reference (`@/scenes/...`) AND the asset appears unchanged, set `description` to `""`.
- If the `name` is a reference BUT the asset has been visually modified in this scene (different clothing, expression, lighting, state, etc.), write a **complete** description of the asset as it appears in this scene — take the base appearance from the referenced asset and bake the modifications into it. Do not describe only the delta. The description must be self-contained and paint the full picture of the asset as it looks right now.
- For scene 0 (root) assets, always write a full description.

**`type`**
- `"character"` — any person, creature, or animate entity with agency.
- `"background"` — the setting or environment of a scene (there is typically one per scene).
- `"object"` — any inanimate prop, device, or item that plays a role in the scene.

**`scene_number`**
- Integer starting at `0`.
- `0` is the **root scene** — use it for assets that appear across multiple scenes and need a canonical definition. Define them once here; reference them in later scenes.
- `1`, `2`, `3`, … correspond to numbered scenes in the story.
- Assign each asset to the scene where it is *first introduced* if it's a root asset, or to the scene where it appears if it is scene-specific.

## Extraction Process

1. **Read the full story** before writing any output.
2. **Identify root assets**: characters and recurring objects/settings that appear in more than one scene. Define them in `scene_number: 0` with a complete description.
3. **Walk each scene** in order. For each scene:
   - Identify the background (setting/environment).
   - Identify all characters present.
   - Identify all significant objects (props that affect the narrative or are visually prominent).
4. **Apply reference logic**:
   - If a root asset appears in a scene unchanged → use `@/scenes/0/{name}` with `description: ""`.
   - If a root asset appears with a visual change → use `@/scenes/0/{name}` with a new description.
   - If a non-root asset from a prior scene reappears unchanged → reference it with `@/scenes/{prior_scene}/{name}` and `description: ""`.
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
- [ ] Every scene in the story has at least one background asset.
- [ ] Every named or clearly described character has an entry.
- [ ] Every narratively significant object has an entry.
- [ ] Root assets (scene 0) have full descriptions.
- [ ] References have `description: ""` unless a modification is described in the story.
- [ ] No description mentions another asset, location, or relational context — each describes only the asset itself.
- [ ] `type` values are exactly `"character"`, `"background"`, or `"object"`.
- [ ] `scene_number` values are non-negative integers.
- [ ] Output is valid JSON wrapped in a ```json code block.
