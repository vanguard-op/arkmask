# Image Description Generation

Generate a concise text description of an uploaded image, suitable as the `description` input to `image-prompt-generation.md`.

## Input Format

```json
{
  "image": "<attached image>",
  "type": "character" | "background" | "object"
}
```

- `image` — the uploaded reference image, attached alongside this instruction.
- `type` — the asset type selected by the user. Tailor the focus of the description to this type (see "Generation Rules by Type" below). Do not guess or override the user's selected type.

## Purpose

This description is used for two things downstream, both already covered by existing instructions — this instruction only produces the description text itself:

1. As the asset's `description` field, shown to the user in the Asset Editor exactly like a manually typed or extracted description.
2. As the `description` input to `image-prompt-generation.md`, when the user opts to regenerate the image in the story's established style (see `image-variant-generation.md` for how the resulting prompt and the original upload are then combined).

## Output

Output a single description string — plain text, no JSON wrapping, no field names. 2–4 sentences. The description is the only output.

## Generation Rules by Type

### `"character"`

Describe the person or character's physical appearance, face, hair, approximate age, expression, and full outfit/accessories, in enough detail that the description alone (without the image) could be used to regenerate a consistent character elsewhere. Do not describe the background or setting in the uploaded photo — focus entirely on the subject.

### `"background"`

Describe the environment: setting type (interior/exterior), architecture or landscape features, time of day and lighting, mood, and any defining visual elements. Do not describe people or foreground objects if any appear incidentally in the photo — focus on the space itself.

### `"object"`

Describe the object's shape, material, color, texture, and any distinguishing details or condition. Do not describe the background the object was photographed against.

## Rules

- Describe only what is visibly present in the image — do not invent narrative context, backstory, or details not visible.
- Write in coherent descriptive sentences, not a comma-separated keyword list.
- Do not mention that this is a photo, upload, or reference image — describe the subject directly, as if writing a fresh asset description (this keeps the output consistent with manually typed and extracted descriptions).
- Do not include the art style of the source photo (e.g. "photorealistic") as a directive — `image-prompt-generation.md` applies the project's own `art_style` separately when the description is later used to generate or regenerate an image.

## Example

**Input:** `type: "character"`, an attached photo of a woman in her 30s with curly red hair, wearing a green field jacket.

**Output:**
A woman in her early thirties with shoulder-length curly red hair and freckled fair skin. She has a warm, confident expression and green eyes. She wears an olive-green field jacket with patch pockets over a plain white t-shirt, along with a canvas satchel worn across one shoulder.
