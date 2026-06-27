# Image Prompt Generation

Generate a text prompt for the Ark image generation API (Seedream model) that will produce a high-quality visual asset from a description and asset type.

## Input Format

```json
{
  "description": "string",
  "type": "character" | "background" | "object"
}
```

## Model Context

Prompts are consumed by **seedream-5-0-lite** (`seedream-5-0-260128`) via the Ark Image Generation API. This model:
- Understands coherent natural language describing **subject + action + environment**
- Responds well to explicit descriptors of **style, color, lighting, and composition**
- Has a hard limit of **600 English words** per prompt — long prompts cause the model to lose detail
- Natively respects layout instructions written in natural language (e.g. "left panel / right panel", "side by side", "two views")
- Interprets aspect ratio from natural language when the `size` parameter is set to a resolution tier (`2K`, `3K`, `4K`)

## Output

Output a single prompt string — plain text, no JSON wrapping, no field names. The prompt is the only output.

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
4. Style and rendering — art style, line quality, color palette, rendering technique
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
- Match the rendering style (photorealistic, painterly, anime, illustrated) to what the description implies; if unspecified, default to **painterly illustration with clean lines and rich color**

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
