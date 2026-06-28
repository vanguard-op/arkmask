"""BytePlus Ark AI provider adapter.

Models used (per architecture.md provider model mapping):
  - Text:  seed-2-0-lite-260228 (via Doubao chat completions)
  - Image: seedream-5-0-260128
  - Video: dreamina-seedance-2-0-260128

SDK: byteplus-python-sdk-v2 (byteplussdkarkruntime)

  Text  → client.chat.completions.create()
  Image → client.images.generate()
  Video → client.content_generation.tasks.create()  [async task + poll]
           client.content_generation.tasks.get(task_id)

The user's BytePlus API key is passed in at construction time via `X-Provider-Key`.
It is used in-flight only — never logged, never stored.
"""

import base64
import json
import logging
import re
import time

import httpx

# Install with: pip install byteplus-python-sdk-v2
from byteplussdkarkruntime import Ark as _Ark

from app.services.ai.base import AIProvider, RefImage

logger = logging.getLogger(__name__)


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON."""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    return match.group(1).strip() if match else text.strip()


def _to_data_uri(data: bytes, mime_type: str) -> str:
    """Encode raw bytes as a base64 data URI.

    BytePlus image APIs accept data URIs in the ``image`` / ``image_url.url``
    fields when a publicly reachable URL is not available.
    """
    return f"data:{mime_type};base64,{base64.b64encode(data).decode()}"


def _download(url: str) -> bytes:
    """Download raw bytes from a URL (BytePlus returns temporary CDN URLs)."""
    with httpx.Client(timeout=120) as client:
        response = client.get(url)
        response.raise_for_status()
        return response.content


def _extract_video_url(task_result) -> str | None:
    """Extract the video URL from a completed content-generation task result.

    The REST response nests the URL at ``content.video_url``.  The Python SDK
    may expose ``content`` as either a single object or a list of objects, so
    both shapes are handled.

    Returns the URL string, or ``None`` if it cannot be found.
    """
    content = getattr(task_result, "content", None)
    if content is None:
        return None

    # List shape: content = [{"type": "video", "video_url": "..."}]
    if isinstance(content, list):
        for item in content:
            url = getattr(item, "video_url", None)
            if url:
                return url
        return None

    # Object shape: content.video_url
    return getattr(content, "video_url", None)


class BytePlusProvider(AIProvider):
    TEXT_MODEL = "seed-2-0-lite-260228"
    IMAGE_MODEL = "seedream-5-0-260128"
    VIDEO_MODEL = "dreamina-seedance-2-0-260128"
    BASE_URL = "https://ark.ap-southeast.bytepluses.com/api/v3"

    # Seedance 2.0 supports up to 9 reference images per generation task.
    _SEEDANCE_MAX_REF_IMAGES = 9

    # Polling cadence and ceiling for video generation tasks.
    # Seedance typically completes in 2–5 minutes; 20 minutes is a conservative
    # ceiling to avoid hanging indefinitely on queued/slow tasks.
    VIDEO_POLL_INTERVAL = 15   # seconds between status checks
    VIDEO_POLL_TIMEOUT = 1200  # maximum total wait (seconds)

    def __init__(self, api_key: str):
        super().__init__(api_key)
        # Client is scoped to a single request — API key lives only here.
        self._client = _Ark(base_url=self.BASE_URL, api_key=api_key)

    # ── Text helpers ──────────────────────────────────────────────────────────

    def _chat(self, system_prompt: str, content: str) -> str:
        """Single-turn chat completion via Doubao/Seed text model."""
        response = self._client.chat.completions.create(
            model=self.TEXT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
        )
        return response.choices[0].message.content

    # ── AI pipeline methods ───────────────────────────────────────────────────

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
        """Generate an image via Seedream 5.0.

        Uses ``client.images.generate()``.  Reference images (up to 10) are
        forwarded as base64 data URIs via the ``image`` parameter — Seedream
        accepts URL strings or data URIs for character/style references.

        The response contains a temporary CDN URL; the image bytes are fetched
        from that URL and returned inline.

        Returns:
            Tuple of (raw PNG bytes, ``"image/png"``).
        """
        kwargs: dict = dict(
            model=self.IMAGE_MODEL,
            prompt=prompt,
            size="2K",
            response_format="url",
            watermark=False,
        )

        if ref_images:
            # Seedream supports up to 10 reference images via the `image` param.
            uris = [_to_data_uri(img.data, img.mime_type) for img in ref_images[:10]]
            # Single image → scalar string; multiple → list of strings.
            kwargs["image"] = uris[0] if len(uris) == 1 else uris

        logger.debug(
            "generate_image: model=%s ref_images=%d",
            self.IMAGE_MODEL, len(ref_images),
        )

        response = self._client.images.generate(**kwargs)
        data = _download(response.data[0].url)
        return data, "image/png"

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate a video via Seedance 2.0 using the async content-generation task API.

        Workflow:
          1. Submit a task via ``client.content_generation.tasks.create()``.
             The ``content`` array carries the storyboard prompt as a ``text``
             item followed by up to ``_SEEDANCE_MAX_REF_IMAGES`` (9) reference
             images as ``image_url`` items.
          2. Poll ``client.content_generation.tasks.get(task_id)`` every
             ``VIDEO_POLL_INTERVAL`` seconds until the task reaches a terminal
             state (``succeeded``, ``failed``, or ``cancelled``).
          3. On success, extract the temporary MP4 URL from the task result via
             ``_extract_video_url()`` and download the bytes via HTTPX.

        Reference images are encoded as base64 data URIs so that raw bytes
        received from the mobile client can be forwarded without a separate
        file-upload step.

        Returns:
            Tuple of (raw MP4 bytes, ``"video/mp4"``).

        Raises:
            ValueError: No reference images supplied, task failed/cancelled, or
                        the succeeded task returned no video URL.
            TimeoutError: Polling exceeded ``VIDEO_POLL_TIMEOUT`` seconds.
        """
        if not ref_images:
            raise ValueError("At least one reference image is required for video generation")

        # Build the content array: text prompt + reference images (up to 9).
        capped = ref_images[:self._SEEDANCE_MAX_REF_IMAGES]
        content: list[dict] = [{"type": "text", "text": storyboard}]
        for img in capped:
            content.append({
                "type": "image_url",
                "image_url": {"url": _to_data_uri(img.data, img.mime_type)},
            })

        logger.info(
            "generate_video: submitting Seedance task — ref_images=%d/%d",
            len(capped), len(ref_images),
        )

        task = self._client.content_generation.tasks.create(
            model=self.VIDEO_MODEL,
            content=content,
        )
        task_id: str = task.id
        logger.info("generate_video: task submitted — task_id=%s", task_id)

        # Poll until terminal state or timeout.
        deadline = time.monotonic() + self.VIDEO_POLL_TIMEOUT
        result = None
        while True:
            time.sleep(self.VIDEO_POLL_INTERVAL)

            result = self._client.content_generation.tasks.get(task_id=task_id)
            status: str = getattr(result, "status", "unknown")
            logger.debug("generate_video: poll task_id=%s status=%s", task_id, status)

            if status == "succeeded":
                break
            if status in ("failed", "cancelled"):
                raise ValueError(
                    f"Seedance video generation task {task_id} ended with status '{status}'"
                )
            if time.monotonic() > deadline:
                raise TimeoutError(
                    f"Seedance task {task_id} did not complete within "
                    f"{self.VIDEO_POLL_TIMEOUT}s (last status: {status})"
                )
            # queued / running — continue polling.

        video_url = _extract_video_url(result)
        if not video_url:
            raise ValueError(
                f"Seedance task {task_id} succeeded but returned no video_url. "
                f"Full result: {result!r}"
            )

        logger.info("generate_video: downloading MP4 from %s", video_url)
        data = _download(video_url)
        return data, "video/mp4"
