# Refine Story Generation

Rewrite an entire scene-segmented story so that every scene is fully and unambiguously specified for independent, scene-by-scene AI video generation — with no assumptions, gaps, or cross-scene context left for the video model to invent.

## Input Format

```json
{
  "story": "string",
  "art_style": "string",
  "video_subtitles": true,
  "known_character_names": ["string"]
}
```

- `story` — the full current `story_content` value: scene-segmented text using `# N` headings (see `asset-list-generation.md` for the same source format).
- `art_style` — the project's `generation_settings.art_style` value. Informational only — do not rewrite scene content to describe the art style; that is applied separately at image/video generation time.
- `video_subtitles` — the project's `generation_settings.video_subtitles` value. If `true`, the story may already use `【】` syntax for on-screen subtitle text; preserve that syntax as-is if present.
- `known_character_names` — optional. Names of characters already extracted as assets for this project (from a prior `/assets` run), resolved server-side from Firestore. If present, every character in the refined story who corresponds to one of these must use the exact same name (spelling and case) so that scene-local `@` asset references continue to resolve correctly downstream (`asset-list-generation.md`). If absent (no prior extraction), invent consistent names normally.

## Purpose

`story_content` is the single source of truth the entire generation pipeline is built on: `/assets` extracts characters, backgrounds, and objects from it; `/video-prompt` slices it per scene to build storyboard prompts; the video model then generates each scene's clip **independently**, with only weak, unreliable continuity from one scene's output to the next. This instruction rewrites the story once, up front, so every downstream scene is self-contained and video-model-ready — it does not extract assets, generate prompts, or touch anything outside the story text itself.

## Output

Output the full rewritten story as **plain text in the same `# N` heading format as the input** — nothing else. No JSON wrapper, no field names, no explanation, no commentary before or after the story text.

```
# 1
[scene 1 body]

# 2
[scene 2 body]

# 3
[scene 3 body]
```

- Scene numbers must be contiguous 1-based integers starting at `# 1`, with no gaps, regardless of how the input was numbered or how many scenes are added by splitting.
- Preserve the `# N` heading format exactly — do not switch to a different heading style, numbering scheme, or markup.

## Rewrite Rules

### 1. Split any scene that would exceed ~14 seconds of screen time

Video generation renders each scene as a single independent clip, and scenes that try to cover too much action or dialogue produce rushed, unclear, or truncated results. Estimate a scene's screen time by its content, not just its word count — a scene with one continuous action and a short line of dialogue reads faster on screen than the same word count split across several distinct beats (a character crossing a room, then picking something up, then speaking, then reacting).

As a rough calibration: dialogue reads at roughly 2–2.5 words per second of screen time, and each distinct staged action (a movement, a gesture, a reaction beat) costs roughly 2–4 seconds even with no dialogue. If a scene's combined dialogue + distinct action beats would plausibly exceed 14 seconds, split it into two or more consecutive scenes at natural beat boundaries (e.g. split where the character finishes crossing the room and begins a new distinct action, or where one line of dialogue ends and the next character's response begins).

Do not over-fragment: a scene that clearly reads under 14 seconds should not be split just to be safe. Judge each scene independently.

### 2. Ensure continuous, adjacent scenes flow naturally into each other

For any two scenes that are narratively and visually continuous (the same characters, the same location, no explicit time or location jump between them — including scenes newly created by splitting under Rule 1), make sure the end of the earlier scene and the start of the later scene connect without a visible discontinuity:
- Preserve character position, pose, and motion direction across the cut where it matters (e.g. if scene 3 ends with a character mid-stride toward a door, scene 4 should open with them continuing that motion, not standing still or already through the door unless a cut is intended).
- Preserve the established setting/location description consistently across scenes that share it — do not silently redescribe a location differently from how it was introduced.
- If a real narrative jump occurs (a time skip, a location change), keep it, but make it explicit in the new scene's body so the video model does not attempt false continuity.

### 3. Make every spoken line unambiguous — name the speaker and quote the exact words

Because each scene is generated independently with only weak cross-scene context, the video model has no memory of who was established as which character. For every scene where a character speaks:
- Explicitly state the character's name performing the line (e.g. `Elias says, "..."`, not `he says, "..."`).
- Quote the exact words to be spoken, verbatim, in quotation marks.
- If two characters speak in the same scene, attribute every line individually — never leave a line's speaker to be inferred from turn order or context.
- Use the exact name from `known_character_names` when the speaker corresponds to an already-extracted character asset.

### 4. Leave nothing implied — specify action, gesture, movement, and staging completely

The scene text is fed directly into video generation with no other input. Rewrite every scene so a video model with zero outside context could stage it correctly:
- State who is present, where they are positioned relative to each other and the setting, and what they are physically doing — do not rely on pronouns without a clear, unambiguous antecedent within the scene.
- Describe gestures and expressions explicitly where they matter to the story (e.g. "she clenches her fists" rather than "she reacts angrily").
- Do not leave a scene's blocking, camera framing intent, or physical outcome of an action ambiguous or open to interpretation — resolve it in the text.
- Do not invent new plot content, new characters, or new events that were not present or implied in the original story — this rewrite restructures and clarifies, it does not change what happens.

### 5. Additional normalization

- **Scene numbering:** output contiguous `# 1`, `# 2`, `# 3` … with no gaps, even after splitting scenes (Rule 1) — this mirrors the same re-indexing behavior already used elsewhere in the product when scenes are inserted or deleted.
- **Character name consistency:** every character's name must be spelled and cased identically everywhere they appear across the entire rewritten story, and must exactly match `known_character_names` when applicable, so downstream asset extraction and `@` reference resolution are not broken by inconsistent naming.
- **Setting/location consistency:** once a location is established, keep its defining visual details consistent every time the story returns to it, unless the original story explicitly changes it (e.g. a fire damages the room).
- **Subtitle syntax:** if `video_subtitles` is `true` and the input story uses `【】` to mark on-screen subtitle text, preserve that usage in the rewritten scenes; do not introduce `【】` syntax if the input did not use it and `video_subtitles` is `false`.
- **Preserve tone and intent:** the rewrite must preserve the original story's narrative content, tone, characters, and outcome. This is a structural and clarity pass for video generation, not a creative rewrite of the plot.

## Example

**Input (excerpt, one scene, `video_subtitles: false`):**

```
# 4
Elias crosses the shop floor to the workbench, picks up the chronosphere, and turns to Lyra. "This was your grandmother's," he says. Lyra's eyes widen and she reaches out to touch it, but he pulls it back gently. "Careful," he warns. She nods, disappointed, then breaks into a small smile as he hands it to her anyway.
```

**Output (excerpt, same scene split into two under Rule 1 — combined dialogue + four distinct action beats exceeds 14 seconds):**

```
# 4
Elias crosses the shop floor toward the workbench, his boots creaking on the wooden floorboards. He reaches the workbench and picks up the chronosphere with both hands, cradling it carefully. He turns to face Lyra, who stands a few feet away near the doorway.

# 5
Elias says, "This was your grandmother's." Lyra's eyes widen and she steps forward, reaching her hand out to touch the chronosphere. Elias gently pulls it back out of her reach and says, "Careful." Lyra nods, her expression briefly disappointed, then breaks into a small smile as Elias holds the chronosphere out and places it into her open hands.
```

## Quality Checklist

Before outputting, verify:
- [ ] Output is plain text using `# 1`, `# 2`, `# 3` … headings only, contiguous with no gaps, and nothing else (no JSON, no commentary).
- [ ] No scene's combined dialogue and distinct action beats would plausibly exceed ~14 seconds of screen time; any that would have been split at a natural beat boundary.
- [ ] Adjacent, narratively continuous scenes preserve character position, motion, and setting description across the cut; deliberate jumps are made explicit in the text.
- [ ] Every spoken line names its speaker explicitly and quotes the exact words verbatim.
- [ ] Every scene fully specifies who is present, where they are, and what they are doing — no unresolved pronouns, no implied off-screen action, no ambiguous staging.
- [ ] No new plot events, characters, or outcomes were invented beyond what the original story contained or implied.
- [ ] Character names are spelled and cased identically everywhere, and match `known_character_names` when applicable.
- [ ] Established locations are described consistently every time the story returns to them, unless the original story explicitly changes them.
- [ ] `【】` subtitle syntax usage matches the input's usage and the `video_subtitles` flag.
