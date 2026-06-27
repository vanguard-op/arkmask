"""BytePlus Ark AI provider adapter.

Models used (per architecture.md provider model mapping):
  - Text:  seed-2-0-lite-260228 (via Doubao chat completions)
  - Image: seedream-5-0-260128
  - Video: dreamina-seedance-2-0-260128

The user's BytePlus API key is passed in at construction time via `X-Provider-Key`.
It is used in-flight only — never logged, never stored.
"""

import base64
import json
import re

import httpx

# Install with: pip install byteplus-python-sdk-v2
from byteplussdkarkruntime import Ark as _Ark

from app.services.ai.base import AIProvider, RefImage


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON."""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    return match.group(1).strip() if match else text.strip()


def _to_data_uri(data: bytes, mime_type: str) -> str:
    """Encode bytes as a base64 data URI for BytePlus image inputs."""
    return f"data:{mime_type};base64,{base64.b64encode(data).decode()}"


def _download(url: str) -> bytes:
    """Download raw bytes from a URL (BytePlus returns URLs, not inline bytes)."""
    with httpx.Client(timeout=120) as client:
        response = client.get(url)
        response.raise_for_status()
        return response.content


class BytePlusProvider(AIProvider):
    TEXT_MODEL = "seed-2-0-lite-260228"
    IMAGE_MODEL = "seedream-5-0-260128"
    VIDEO_MODEL = "dreamina-seedance-2-0-260128"
    BASE_URL = "https://ark.ap-southeast.bytepluses.com/api/v3"

    def __init__(self, api_key: str):
        super().__init__(api_key)
        # Client is scoped to a single request — API key lives only here.
        self._client = _Ark(base_url=self.BASE_URL, api_key=api_key)

    def _chat(self, system_prompt: str, content: str) -> str:
        """Single-turn chat completion."""
        response = self._client.chat.completions.create(
            model=self.TEXT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
        )
        return response.choices[0].message.content

    def generate_asset_list(self, story: str) -> list[dict]:
        text = self._chat(self.ASSET_LIST_PROMPT, story)
        return json.loads(_extract_json(text))

    def generate_image_prompt(self, name: str, type_: str, description: str) -> str:
        payload = json.dumps({"name": name, "type": type_, "description": description})
        return self._chat(self.IMAGE_PROMPT, payload).strip()

    def generate_video_prompt(self, scene_text: str, assets: list[dict]) -> str:
        payload = json.dumps({"scene": scene_text, "assets": assets})
        return self._chat(self.VIDEO_PROMPT, payload).strip()

    def generate_image(self, prompt: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        kwargs: dict = dict(
            model=self.IMAGE_MODEL,
            prompt=prompt,
            size="2K",
            output_format="png",
            response_format="url",
            watermark=False,
        )
        if ref_images:
            uris = [_to_data_uri(img.data, img.mime_type) for img in ref_images]
            kwargs["image"] = uris[0] if len(uris) == 1 else uris

        response = self._client.images.generate(**kwargs)
        data = _download(response.data[0].url)
        return data, "image/png"

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        if not ref_images:
            raise ValueError("At least one reference image is required for video generation")
        ref_uri = _to_data_uri(ref_images[0].data, ref_images[0].mime_type)
        response = self._client.videos.generate(
            model=self.VIDEO_MODEL,
            prompt=storyboard,
            image=ref_uri,
            response_format="url",
        )
        data = _download(response.data[0].url)
        return data, "video/mp4"
