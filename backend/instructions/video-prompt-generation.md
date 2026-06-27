# Video Prompt Generation

Generate a text prompt for the Ark video generation API (Seedance 2.0 model) that will produce a high-quality video clip from a scene description and a set of named reference assets.

## Input Format

```json
{
  "scene": "string",
  "assets": [
    {
      "name": "string",
      "prompt": "string"
    }
  ]
}
```

- `scene` — a description of what happens in the video: what characters do, the setting, mood, and any dialogue or sound
- `assets` — an ordered list of reference images that will be provided to the model alongside the prompt
  - `name` — the asset's identifier (e.g. `"elias"`, `"clockwork_emporium"`, `"chronosphere"`)
  - `prompt` — the image generation prompt used to create this reference image; read it to understand the asset's visual appearance and type

The reference images are provided to the Seedance model in the **same order** as the `assets` list. The asset at index 0 becomes **Image 1**, index 1 becomes **Image 2**, and so on. Always use these `Image N` identifiers in the prompt — never reference an asset by its `name` alone without binding it to its image number.

## Model Context

Prompts are consumed by **Seedance 2.0** (`dreamina-seedance-2-0-260128`) via the Ark Video Generation API. Understand how this model works before constructing a prompt:

- It internally decouples the **spatial layer** (what is in the frame) and the **temporal layer** (how things change over time). A good prompt addresses both: who/what/where feeds the spatial layer; actions, camera moves, and shot order feed the temporal layer.
- It is an "engineering-style instruction", not copywriting. The advanced prompt formula is: **precise subject → action details → scene/environment → lighting & color tone → camera movement → visual style → image quality → constraints**
- It understands standard film camera terminology directly — use it without explanation
- It supports dialogue with `{}`, sound effects with `<>`, music with `（）`, subtitles with `【】`
- It does **not** support negative prompts — use explicit positive constraint phrases instead
- Precise timing (e.g. "at 3 seconds") is unstable — do not specify durations; let the model pace shots naturally
- Language of dialogue must be consistent; do not mix Chinese and English (except proper nouns)

## Output

Output a single prompt string — plain text only, no JSON wrapping, no field labels. The prompt is the only output.

---

## Construction Process

### Step 1 — Read and Classify the Assets

Read every asset's `prompt` field to determine its type:

- **Character** — describes a person, creature, or animate subject (mentions face, body, clothing, skin, hair, expression, age, "character reference sheet", "portrait", etc.)
- **Background** — describes an environment or setting (mentions interior, exterior, architecture, landscape, sky, floor, atmosphere, etc.)
- **Object** — describes a prop or item (mentions materials, shape, texture, surface, product-style lighting, dimensions, etc.)

Assign each asset its **Image N** number by its position in the list (0-indexed → Image 1, Image 2, ...).

> **Asset count warning**: The model degrades when given too many reference images. Do not reference more than ~5 total assets in the prompt. If the list contains more, prioritize character face images, then the primary background, then the most narratively important objects.

> **Character limit**: If there are more than 4 character assets, the model becomes unstable and may produce incorrect or duplicate characters. Flag this as a known limitation in the generated prompt via a comment, but still write the best possible prompt.

---

### Step 2 — Order Assets in the Prompt

Assets must appear in the prompt in this priority order, from most important to least:

1. **Character face/body references first** — the more a character needs precise appearance locking, the earlier it must appear
2. **Background scene reference** — after all characters
3. **Object references** — last, inline where they appear in the action

This ordering matters: the model assigns higher feature weight to assets mentioned earlier.

---

### Step 3 — Define Subjects (Characters)

For every character asset, write a subject definition that binds the character to their image number. Use 2–3 concrete, stable, static visual features extracted from the asset's `prompt` (clothing, hair, skin, distinctive accessories — not abstract traits like "kind" or "mysterious").

**Pattern — single character:**
> Define the [2–3 core visual features] in **Image N** as **[name]**

**Pattern — multiple characters (bind separately, one per line):**
> Define the [features of character 1] in **Image N** as **[name1]**, and define the [features of character 2] in **Image N** as **[name2]**

**Pattern — same character across multiple images (e.g. separate headshot and full-body):**
> Define [name]: facial features reference **Image N** (headshot), full-body styling reference **Image M**

Once defined, always use the same label (the `name`) when referring to this character in shots. Never switch to a generic descriptor like "the man" or "the character."

For simple single-character scenes with no prior definition block, you may reference inline as **name@Image N** each time the character appears.

> **⚠ Two-panel character sheet warning**: The image-prompt-generation instruction produces two-panel side-by-side reference sheets (close-up left + full-body right in one image). Seedance 2.0 may interpret the two panels as two separate subjects, causing ID drift or duplicate characters. To mitigate this, in the subject definition explicitly call out that both panels show the same single character: e.g., `"Define the [features] shown in both panels of **Image N** as **[name]** — treat as a single character reference."` Do not use multi-view or two-panel assets if a standalone headshot is available.

---

### Step 4 — Reference the Background

Bind the background asset to the scene context explicitly:

> The scene is set in the [environment type] shown in **Image N**.

or inline in the first shot:

> ...in the [environment] from **Image N**...

Do not describe the environment in prose if an image reference already captures it — let the image carry the visual information and keep text description to atmosphere and mood.

---

### Step 5 — Write the Shot Sequence

Break the `scene` into numbered shots: **Shot 1 / Shot 2 / Shot 3**... in chronological order (primary action first, secondary details later).

**Each shot must contain, in this order:**

1. **Camera** — one movement or framing type only (see vocabulary below). Never mix push + pull + pan in the same shot; this causes instability.
2. **Subject action** — specific body parts (hands, legs, head, shoulders, back), with range, speed, and force. Never say "he feels sad" — externalize it physically (see emotion table below).
3. **Spatial position** — where the subject is within the scene.
4. **Audio** — dialogue in `{}`, ambient sound effects in `<>`, background music in `（）`.

**Camera vocabulary** (use these terms directly):

| Category | Terms |
|---|---|
| Framing | `wide shot`, `medium shot`, `medium close-up`, `close-up`, `extreme close-up`, `over-the-shoulder shot`, `bird's-eye view`, `low-angle shot`, `long shot` |
| Movement | `slow push in`, `pull back`, `smooth lateral track`, `dolly forward`, `pan left/right`, `tilt up/down`, `crane up`, `handheld with slight shake`, `fixed camera` |
| Transitions | `cut to`, `slowly fades into`, `freezes on` |

**Action guidelines:**
- Prioritize **slow, gentle, continuous subtle movements** — avoid high-burst actions (sprinting, big jumps, violent rolls)
- Specify the **inertia and continuity** between consecutive actions: "using the inertia of turning around, she naturally raises her hand"
- Describe actions down to body parts: "slowly raises her right hand", "fingers tighten around the edge of the table", "head tilts slightly downward"

**Emotion externalization:**

| Abstract emotion | Write instead |
|---|---|
| Sadness | head lowers, shoulders tremble slightly, eyes redden, fingers unconsciously clutch the corner of clothing, tears well but do not fall |
| Joy | corners of the mouth rise uncontrollably, brows relax, steps become light, a soft exhale escapes |
| Nervousness | eyes dart away, fingers tap the surface repeatedly, breath quickens, jaw tightens |
| Anger | fists clench, jawline tenses, chest heaves, words come out pressed through gritted teeth |
| Wonder / Awe | eyes widen, breath catches, body leans slightly forward, mouth parts slightly |
| Relief | a long breath releases, tense shoulders fully relax, a long-lost faint smile returns, gaze lifts upward |
| Concentration | brow furrows, jaw sets, body leans in, hands move with deliberate precision |

---

### Step 6 — Write the Closing Block

Always end the prompt with a closing block in this order:

1. **Visual/art style** — always name it explicitly; do not let the model guess. Style drift (e.g. illustration drifting to live-action) happens when this is omitted. Examples: `painterly illustration with warm tones`, `cinematic live-action`, `2D Japanese anime style`, `3D animation CG style`, `retro film grain`.
2. **Image quality** — `high-definition, rich textural detail, cinematic texture, natural colors`
3. **Lighting** — match the mood of the scene
4. **Character stability** — always include: `The character's face and body proportions remain consistent throughout without deformation. Movements are natural and smooth, with no stutter or flicker.`
5. **Subtitle constraint** — always include: `Keep it subtitle-free. Avoid generating any text or subtitles.` (Landscape orientation also significantly reduces subtitle probability — note this if the scene suits a wide format.)
6. **Watermark/logo constraint** — always include: `Do not generate a watermark. Do not generate a logo.`
7. **Duplicate character constraint** — include when more than one character is present: `Throughout the video, characters with completely identical appearance, clothing, and accessories are prohibited. Do not generate duplicate avatars or a twin effect. Keep only a single corresponding character in the same frame.`

---

## Complete Prompt Template

```
[Subject definition block — one line per character, ordered most-important first]
[Background scene reference]

Shot 1: [One camera movement/framing]. [Character name] [action — body part, speed, range]. [Spatial position in scene]. [Audio: dialogue in {}, SFX in <>, music in （）]

Shot 2: [One camera movement/framing]. [Character name] [action]. [Position]. [Audio]

Shot 3: [One camera movement/framing]. [Character name] [action]. [Position]. [Audio]

[Visual style], [image quality], [lighting]. The character's face and body proportions remain consistent throughout without deformation. Movements are natural and smooth, with no stutter or flicker. Keep it subtitle-free. Avoid generating any text or subtitles. Do not generate a watermark. Do not generate a logo. [Duplicate constraint if multiple characters.]
```

---

## Example

**Input:**
```json
{
  "scene": "Elias stands at his workbench in the clockwork shop, carefully sets down the glowing chronosphere, then slowly straightens up and turns to look out the dusty shop window with quiet accomplishment. The shop is filled with the soft ticking of many clocks.",
  "assets": [
    {
      "name": "elias",
      "prompt": "Character reference sheet — two-panel side-by-side layout on a plain light neutral grey background, wide landscape format. Left panel: close-up portrait from mid-chest upward of an elderly man in his late 70s. Deeply weathered skin, kind eyes, messy grey hair, round wire-rimmed glasses. Worn brown leather apron over an off-white linen shirt. Right panel: full-body view of the same man, same outfit, oil-stained hands visible at sides. Painterly illustration, warm color palette, soft even studio lighting."
    },
    {
      "name": "clockwork_emporium",
      "prompt": "Interior of a cozy Victorian-era watch and clock shop. Dense dark-wood shelves packed with grandfather clocks, glass-domed pocket watches, cuckoo clocks. Warm amber oil lamp light. Worn hardwood floor. Large dusty shop window facing a grey overcast street. Painterly illustration with rich warm tones."
    },
    {
      "name": "chronosphere",
      "prompt": "A spherical brass device the size of a large grapefruit. Outer shell engraved with interlocking gear-tooth patterns and fine filigree. Glass core glows with a faint swirling amber light. Single large brass button on top. Clean light grey background, soft studio lighting. Painterly illustration style."
    }
  ]
}
```

**Output:**

Define the elderly grey-haired man wearing a worn leather apron and round wire-rimmed glasses shown in both panels of **Image 1** as **Elias** — treat as a single character reference. The scene is set in the clockwork shop interior from **Image 2**.

Shot 1: Fixed medium shot at workbench level. **Elias** lowers the **chronosphere from Image 3** onto the workbench surface with both hands, movements slow and deliberate, fingers releasing it gently, shoulders slightly hunched forward over the bench. <the soft rhythmic ticking of many clocks fills the room>

Shot 2: Slow pull back to a medium shot. **Elias** gradually straightens upright from his hunched posture, both hands pressing lightly on the bench surface as he rises. His shoulders settle and release their tension. A long, quiet breath escapes. <continuous soft clock ticking>

Shot 3: Fixed close-up on **Elias**'s face. He slowly turns his head toward the large dusty window, eyes softening as they settle on the grey light beyond the glass. The corners of his mouth form a faint, trembling smile. One tear wells at the corner of his eye but does not fall.

Painterly illustration style with warm amber and dark wood tones, rich textural detail. High-definition, cinematic texture, natural colors. Soft warm lamp-light with gentle shadows. The character's face and body proportions remain consistent throughout without deformation. Movements are natural and smooth, with no stutter or flicker. Keep it subtitle-free. Avoid generating any text or subtitles. Do not generate a watermark. Do not generate a logo.
