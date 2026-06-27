"""Google Gemini AI provider adapter.

Models used:
  - Text:  gemini-3.5-flash  (Interactions API — client.interactions.create)
  - Image: gemini-3.1-flash-image  (Nano Banana — Interactions API)
  - Video: veo-3.1-generate-preview  (client.models.generate_videos + GenerateVideosSource)

The user's Gemini API key is passed in at construction time via `X-Provider-Key`.
It is used in-flight only — never logged, never stored.
"""

import base64
import json
import re
import time

from google import genai
from google.genai import types

from app.services.ai.base import AIProvider, RefImage


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON."""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    return match.group(1).strip() if match else text.strip()


class GeminiProvider(AIProvider):
    # Text: Interactions API — system_instruction + input → interaction.output_text
    TEXT_MODEL = "gemini-3.5-flash"
    # Image: Nano Banana — Interactions API → interaction.output_image.data (base64)
    IMAGE_MODEL = "gemini-3.1-flash-image"
    # Video: Veo 3.1 — generate_videos + GenerateVideosSource → video.video_bytes
    VIDEO_MODEL = "veo-3.1-generate-preview"
    VIDEO_POLL_INTERVAL = 10  # seconds between status checks

    def __init__(self, api_key: str):
        super().__init__(api_key)
        # Client is scoped to a single request — API key lives only here.
        self._client = genai.Client(api_key=api_key)

    # ── Text helpers ──────────────────────────────────────────────────────────

    def _text_interact(self, system_instruction: str, payload: str) -> str:
        """Run a text generation call via the Interactions API.

        Returns the model's text output as a plain string.
        system_instruction is passed as a top-level parameter (not inside the
        input) so the Interactions API wires it correctly as a system turn.
        """
        interaction = self._client.interactions.create(
            model=self.TEXT_MODEL,
            system_instruction=system_instruction,
            input=payload,
            generation_config={"thinking_level": "low"},
        )
        return (interaction.output_text or "").strip()

    # ── AI pipeline methods ───────────────────────────────────────────────────

    def generate_asset_list(self, story: str) -> list[dict]:
        text = self._text_interact(self.ASSET_LIST_PROMPT, story)
        return json.loads(_extract_json(text))

    def generate_image_prompt(self, name: str, type_: str, description: str) -> str:
        payload = json.dumps({"name": name, "type": type_, "description": description})
        return self._text_interact(self.IMAGE_PROMPT, payload)

    def generate_video_prompt(self, scene_text: str, assets: list[dict]) -> str:
        payload = json.dumps({"scene": scene_text, "assets": assets})
        return self._text_interact(self.VIDEO_PROMPT, payload)

    def generate_image(self, prompt: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate an image via the Interactions API (Nano Banana).

        Accepts up to 14 reference images as base64-encoded input blocks.
        Response carries the final image in interaction.output_image.data (base64).
        """
        input_blocks: list = [{"type": "text", "text": prompt}]
        for img in ref_images[:14]:
            input_blocks.append({
                "type": "image",
                "data": base64.b64encode(img.data).decode("utf-8"),
                "mime_type": img.mime_type,
            })

        interaction = self._client.interactions.create(
            model=self.IMAGE_MODEL,
            input=input_blocks if len(input_blocks) > 1 else prompt,
            response_format={"type": "image", "image_size": "1K"},
        )

        out = interaction.output_image
        if out is None or out.data is None:
            raise ValueError("gemini-3.1-flash-image returned no image in response")

        return base64.b64decode(out.data), out.mime_type or "image/png"

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate a video via Veo 3.1 (veo-3.1-generate-preview).

        Uses client.models.generate_videos() with GenerateVideosSource.
        Polls the returned operation every VIDEO_POLL_INTERVAL seconds until done.
        Returns raw video bytes and mime type.
        """
        # Build source — prompt is required; first ref image is optional.
        source = types.GenerateVideosSource(prompt=storyboard)
        if ref_images:
            source = types.GenerateVideosSource(
                prompt=storyboard,
                image=types.Image(
                    image_bytes=ref_images[0].data,
                    mime_type=ref_images[0].mime_type,
                ),
            )

        operation = self._client.models.generate_videos(
            model=self.VIDEO_MODEL,
            source=source,
            config=types.GenerateVideosConfig(
                number_of_videos=1,
                duration_seconds=8,
                enhance_prompt=True,
                generate_audio=False,
            ),
        )

        # Poll until the operation completes (typically 2–5 minutes for Veo 3.1).
        while not operation.done:
            time.sleep(self.VIDEO_POLL_INTERVAL)
            operation = self._client.operations.get(operation)

        video = operation.response.generated_videos[0].video
        if video.video_bytes is None:
            raise ValueError("Veo 3.1 returned no video bytes in response")
        return video.video_bytes, video.mime_type or "video/mp4"
