# Image Prompt Generation

Generate a text prompt for the Ark image generation API (Seedream model) that will produce a high-quality visual asset from a description and asset type.

## Input Format

```json
{
  "description": "string",
  "type": "character" | "background" | "object",
  "art_style": "string"
}
```

- `art_style` — the visual rendering style for this project (e.g. `"painterly illustration with clean lines and rich color"`, `"cinematic live-action"`, `"2D Japanese anime style"`). Apply this style as written, **except** for `"character"` assets when it is realism-leaning, in which case resolve it through the Realism Guardrail below before writing the prompt. If absent or empty, default to `painterly illustration with clean lines and rich color`.

## Model Context

Prompts are consumed by **seedream-5-0-lite** (`seedream-5-0-260128`) via the Ark Image Generation API. This model:
- Understands coherent natural language describing **subject + action + environment**
- Responds well to explicit descriptors of **style, color, lighting, and composition**
- Has a hard limit of **600 English words** per prompt — long prompts cause the model to lose detail
- Natively respects layout instructions written in natural language (e.g. "left panel / right panel", "side by side", "two views")
- Interprets aspect ratio from natural language when the `size` parameter is set to a resolution tier (`2K`, `3K`, `4K`)

## Output

Output a single prompt string — plain text, no JSON wrapping, no field names. The prompt is the only output.

## Realism Guardrail (Downstream Video Model Compatibility)

The image generated here is later fed into a separate video generation model as a conditioning reference. That video model silently rejects images its own safety filter judges to be an indistinguishable photograph of a real person (its rejection reasoning references likeness/celebrity-resemblance risk, even for entirely fictional descriptions). A prompt that leans into literal photographic realism — especially for `"character"` assets — risks producing an image the video model will reject after the fact, with no user-facing error.

**When this applies**: check `art_style` (case-insensitive) for realism-leaning language — e.g. it contains words like `"live-action"`, `"photoreal"`, `"photo-real"`, `"photorealistic"`, `"cinematic"`, `"realistic"`, `"live action"`, `"film"`, `"photograph"`. If none of these are present (e.g. painterly, anime, cartoon, stylized, low-poly, watercolor styles), skip this section entirely and apply `art_style` exactly as written — those styles are already far from the rejection boundary.

**How to resolve a realism-leaning `art_style`**: do not pass the raw style string through unmodified. Instead, translate it into rendering-style language that keeps every quality the user asked for (photographic lighting, fine detail, lifelike proportions, cinematic composition, color grading) while explicitly framing the output as a **digital render of a character**, never as a photograph of a real, physical person. Concretely, the "Style and rendering" language in the prompt must:
- Keep the user's realism cues — lighting quality, level of detail, cinematic mood, color grading — intact and undiminished.
- Add a rendering-medium qualifier that a photo cannot have, e.g. "hyper-detailed digital character render," "CG character render with photographic lighting," "cinematic 3D character render." Use wording proportional to the source style — do not soften the requested realism, only reclassify its medium.
- Never use the bare words "photograph," "photo," "photorealistic photo," or "real person" to describe the output image itself — these describe exactly the classification the video model rejects. Describing lighting or detail as "photographic" or "cinematic" is fine; describing the output image itself as a photo is not.
- For `"character"` assets specifically, avoid descriptor combinations that read as a specific, identifiable real individual (e.g. do not invent or imply a celebrity likeness, a named public figure, or hyper-specific real-world identity markers). Keep descriptions generic and original — an invented person's features, not a recognizable one.

This guardrail applies specifically to `"character"` assets — the video model's rejection is a likeness/face-resemblance check, which only fires on images containing a face. `"background"` and `"object"` assets have no face for the filter to evaluate, so their `art_style` should always be applied as written, with no guardrail translation needed.

## Generation Rules by Type

### `"character"` — Character Reference Sheet

Produce a prompt for a **single image** showing **two views side by side on a plain light neutral background**:
- **Left panel**: close-up portrait (head and shoulders, from mid-chest upward), sharp facial detail, direct or slightly angled gaze
- **Right panel**: full-body view from head to toe, natural standing pose, complete outfit and proportions visible

Both panels must show the **same character** with **identical appearance, style, lighting, and art direction** — this is a character reference sheet for use as a visual source asset.

Structure the prompt as:
1. Layout declaration — state explicitly that this is a two-panel side-by-side character sheet
2. Character description — physical appearance, face, hair, skin, expression, age, distinguishing features
3. Clothing and accessories — full outfit description in both panels
4. Style and rendering — art style, line quality, color palette, rendering technique (apply the Realism Guardrail above if `art_style` is realism-leaning)
5. Lighting — clean, even, studio-quality lighting with no dramatic shadows that would obscure features
6. Background — plain, light neutral or white background in both panels (no environmental context)
7. Aspect ratio guidance — include in the prompt that the image is wide/landscape format (16:9)

**Avoid**: placing the character in a scene, adding environmental elements, or using dramatic or atmospheric lighting that obscures the reference value.

### `"background"` — Environment / Scene

Produce a prompt for a **single wide establishing shot** of the environment.

Structure the prompt as:
1. Environment type and setting — interior/exterior, time of day, season, architecture or landscape type
2. Key visual elements — objects, structures, features that define the space
3. Atmosphere and mood — weather, lighting quality, emotional tone
4. Color palette — dominant hues, contrast, saturation
5. Composition — camera perspective (wide angle, eye level, slight elevation), depth, framing
6. Rendering style — photorealistic, painterly, illustrated, cinematic, etc.
7. Aspect ratio guidance — include in the prompt that the image is wide/landscape (16:9) for a cinematic background

**Avoid**: placing characters or foreground props in the scene — this is a pure environment asset.

### `"object"` — Prop / Item

Produce a prompt for a **clean, well-lit product-style shot** of the object on a neutral background.

Structure the prompt as:
1. Object description — shape, size, material, color, texture, condition, any distinguishing details
2. Orientation and view — the most informative angle (3/4 view, front-facing, slight elevation)
3. Lighting — soft, even studio lighting that clearly reveals material surface and texture with no harsh shadows
4. Background — pure white, light grey, or soft neutral background
5. Rendering style — match the style implied by the description (realistic, stylized, illustrated)
6. Aspect ratio guidance — square format (1:1) is recommended for isolated object shots

**Avoid**: placing the object in a scene or environment. Focus entirely on the object itself.

## Prompt Quality Rules

- Write in **coherent descriptive sentences**, not comma-separated keyword lists
- Always include: subject, visual style, lighting, and composition
- Never exceed **600 words** — trim ruthlessly if needed; the model loses coherence with over-long prompts
- Do not reference other assets, scenes, or relationships — describe only what is in this image
- Do not include negative prompts or model directives (e.g. "do not include...", "avoid...") — Seedream does not use negative prompt syntax
- Always use the `art_style` from the input as the rendering style — apply it exactly as written across the entire prompt. Never infer or override the style from the description.

## Example

**Input**:
```json
{
  "description": "A heavy, rustic dark wooden box with metal latches, filled with several glowing crystal vials secured in straw padding.",
  "type": "object"
}
```

**Output**:
A heavy rectangular wooden box, open-lidded to reveal its interior, constructed from dark aged oak with a rough-hewn grain and worn edges. Four iron corner fittings and two metal latch clasps line the exterior. The interior is padded with golden straw, cradling a cluster of small crystal vials that emit a soft, warm amber and blue luminescent glow from within. The vials are short and round-stoppered, their glass catching the light with a gentle inner radiance. Rendered in a rich painterly illustration style with detailed textures on both the dark wood grain and the glowing glass. Soft studio lighting from above and slightly to one side, emphasizing the surface material of the wood and the translucent glow of the crystal. Clean light grey background. Square format (1:1).

---

**Input**:
```json
{
  "description": "An elderly man in his late 70s with deeply weathered skin and oil-stained hands. He wears a worn leather apron over a simple linen shirt, with round wire-rimmed spectacles perched on his nose. His expression is gentle and absorbed — the face of a lifetime craftsman.",
  "type": "character"
}
```

**Output**:
Character reference sheet — two-panel side-by-side layout on a plain white background, wide landscape format (16:9). Left panel: close-up portrait from mid-chest upward of an elderly man in his late 70s, face in soft three-quarter view. His skin is deeply weathered with pronounced wrinkles earned over decades of close work. Round wire-rimmed spectacles rest on his nose. His eyes are warm and absorbed, carrying the focused calm of a lifetime craftsman. Thinning white hair, neatly kept. He wears a worn brown leather apron over a simple off-white linen shirt, collar slightly open. Oil and grease stains mark the apron and his hands. Right panel: full-body view of the same man in a natural standing pose, hands visible at his sides, full leather apron and linen shirt clearly rendered head to toe, same lighting and same expression. Painterly illustration style with clean outlines and warm, earthy color palette. Soft even studio lighting, no shadows obscuring facial features. Plain white background in both panels.

---

**Input** (realism-leaning `art_style` — Realism Guardrail applies):
```json
{
  "description": "A woman in her mid-20s with sharp cheekbones, straight dark hair in a ponytail, and an athletic build. She wears a fitted grey running jacket and dark leggings, with a determined, focused expression.",
  "type": "character",
  "art_style": "cinematic live-action"
}
```

**Output**:
Character reference sheet — two-panel side-by-side layout on a plain light neutral background, wide landscape format (16:9). Left panel: close-up portrait from mid-chest upward of a woman in her mid-20s with an invented, original appearance — sharp cheekbones, straight dark hair pulled into a neat ponytail, athletic build, and a determined, focused expression, gaze slightly angled toward camera. Right panel: full-body view of the same woman in a natural standing pose, wearing a fitted grey running jacket over dark athletic leggings, full outfit and proportions visible head to toe, same lighting and same expression. Rendered as a hyper-detailed digital character render with cinematic, photographic-quality lighting and fine surface detail — a polished CG character render, not a photograph. Clean, even studio-quality lighting with soft falloff, no dramatic shadows obscuring the face. Plain light neutral background in both panels.
