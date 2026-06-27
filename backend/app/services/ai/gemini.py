"""Google Gemini AI provider adapter.

Models used (per architecture.md provider model mapping):
  - Text:  gemini-2.5-flash
  - Image: gemini-3.1-flash-image  (Nano Banana — Interactions API)
  - Video: veo-2.0-generate-001 (Veo 2.0)

The user's Gemini API key is passed in at construction time via `X-Provider-Key`.
It is used in-flight only — never logged, never stored.
"""

import base64
import json
import re
import time

from google import genai

from app.services.ai.base import AIProvider, RefImage


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON."""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    return match.group(1).strip() if match else text.strip()


class GeminiProvider(AIProvider):
    TEXT_MODEL = "gemini-2.5-flash"
    # Nano Banana — uses the Interactions API (client.interactions.create),
    # not generate_content or generate_images.
    IMAGE_MODEL = "gemini-3.1-flash-image"
    VIDEO_MODEL = "veo-2.0-generate-001"
    VIDEO_POLL_INTERVAL = 10  # seconds between status checks

    def __init__(self, api_key: str):
        super().__init__(api_key)
        # Client is scoped to a single request — API key lives only here.
        self._client = genai.Client(api_key=api_key)

    def _text_config(self, system_instruction: str) -> genai.types.GenerateContentConfig:
        return genai.types.GenerateContentConfig(
            system_instruction=system_instruction,
            temperature=1,
            max_output_tokens=65536,
            top_p=0.95,
            thinking_config=genai.types.ThinkingConfig(thinking_budget=8192),
        )


    def generate_asset_list(self, story: str) -> list[dict]:
        response = self._client.models.generate_content(
            model=self.TEXT_MODEL,
            contents=story,
            config=self._text_config(self.ASSET_LIST_PROMPT),
        )
        return json.loads(_extract_json(response.text))

    def generate_image_prompt(self, name: str, type_: str, description: str) -> str:
        payload = json.dumps({"name": name, "type": type_, "description": description})
        response = self._client.models.generate_content(
            model=self.TEXT_MODEL,
            contents=payload,
            config=self._text_config(self.IMAGE_PROMPT),
        )
        return response.text.strip()

    def generate_video_prompt(self, scene_text: str, assets: list[dict]) -> str:
        # Assets list: [{"name": str, "type": str}] — images not passed to text model.
        payload = json.dumps({"scene": scene_text, "assets": assets})
        response = self._client.models.generate_content(
            model=self.TEXT_MODEL,
            contents=payload,
            config=self._text_config(self.VIDEO_PROMPT),
        )
        return response.text.strip()

    def generate_image(self, prompt: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate an image via the Interactions API (Nano Banana / gemini-3.1-flash-image).

        Supports up to 14 reference images passed as base64-encoded blocks.
        The response carries the final image in `interaction.output_image.data`
        as a base64 string.
        """
        # Build the input list: text prompt first, then optional reference images.
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

        image_bytes = base64.b64decode(out.data)
        mime = out.mime_type or "image/png"
        return image_bytes, mime

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        if not ref_images:
            raise ValueError("At least one reference image is required for video generation")
        ref = ref_images[0]
        ref_image = genai.types.Image(image_bytes=ref.data, mime_type=ref.mime_type)

        operation = self._client.models.generate_videos(
            model=self.VIDEO_MODEL,
            prompt=storyboard,
            image=ref_image,
            config=genai.types.GenerateVideosConfig(number_of_videos=1),
        )
        # Poll until the operation completes (typically 2–5 minutes).
        while not operation.done:
            time.sleep(self.VIDEO_POLL_INTERVAL)
            operation = self._client.operations.get(operation)

        video = operation.response.generated_videos[0].video
        return video.video_bytes, "video/mp4"
