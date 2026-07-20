"""BytePlus Ark AI provider adapter.

Models in use (see BytePlusProvider class attributes for the current values —
kept there as the single source of truth since these get updated from time
to time; this docstring is illustrative, not authoritative):
  - Text:  chat completions model (Doubao/Seed/DeepSeek family)
  - Image: Seedream image generation model
  - Video: Seedance/Dreamina video generation model

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
from byteplussdkarkruntime._exceptions import ArkAPIError

from app.services.ai.base import AIProvider, AIProviderError, AssetPromptInput, RefImage

logger = logging.getLogger(__name__)


def _call_ark(fn, *args, **kwargs):
    """
    Call an Ark SDK method, translating ``ArkAPIError`` into the shared
    ``AIProviderError`` so callers get a clean, structured message instead of
    the SDK's raw exception (previously surfaced to users/logs as either a
    generic "AI provider error during X." or FastAPI's bare "An internal
    server error occurred.").

    ``ArkAPIStatusError`` subclasses (4xx/5xx responses) already parse
    ``.code``/``.type``/``.message`` from the response body — this just
    forwards them into ``AIProviderError``. Non-HTTP SDK errors (e.g.
    connection failures) have no status code but still get a clean message.
    """
    try:
        return fn(*args, **kwargs)
    except ArkAPIError as e:
        status_code = getattr(e, "status_code", None)
        # Prefer `.code` (the specific error, e.g. "AccountOverdueError") over
        # `.type` (just the generic HTTP class, e.g. "Forbidden") — `.code` is
        # the actually useful, actionable identifier when both are present.
        provider_error_code = getattr(e, "code", None) or getattr(e, "type", None)
        raise AIProviderError(
            provider="BytePlus",
            status_code=status_code,
            provider_error_code=provider_error_code,
            message=e.message,
        ) from e


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON.

    Handles four response shapes:
    1. JSON wrapped in ```json ... ``` fences (preferred, instructed by prompt)
    2. Raw JSON starting with [ or { (model ignored the fence instruction)
    3. A bare "json" language tag with no surrounding ``` fence markers at all
       (observed with seed-2-0-lite-260428: the model emits the tag from what
       would have been a ```json fence, but the backticks themselves are
       missing — e.g. "json\n[\n  {...}\n]" with no ``` anywhere in the text).
       Strip a leading "json" tag line before checking for the array/object
       start.
    4. Empty/whitespace — returns "" to let the caller raise a clear error
    """
    if not text:
        return ""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if match:
        return match.group(1).strip()

    stripped = text.strip()

    # Case 3: leading bare "json" tag with no fence markers.
    tag_match = re.match(r"^json\s*\n", stripped, re.IGNORECASE)
    if tag_match:
        stripped = stripped[tag_match.end():].strip()

    # No code fence — accept if the text looks like raw JSON.
    if stripped and stripped[0] in ("[", "{"):
        return stripped
    return ""


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
    TEXT_MODEL = "seed-2-0-mini-260428"
    IMAGE_MODEL = "seedream-5-0-260128"
    VIDEO_MODEL = "dreamina-seedance-2-0-mini-260615"
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

    # No max_tokens was previously set, so responses were capped by whatever
    # default the API applies. For asset extraction on stories with several
    # detailed characters, the model's JSON array (each entry ~150-300 chars
    # of prose) can run past that default before finishing — the response
    # gets cut off mid-generation with no closing ``` fence, which
    # _extract_json can't recover (there's genuinely no valid JSON to find,
    # since the array itself is incomplete). 8192 was enough headroom for
    # small/medium stories, but a ~50-scene story with a large asset list
    # (characters + props + locations, each with a prose description) can
    # produce a JSON array well past that ceiling and gets truncated the
    # same way. 32768 gives a large enough ceiling for that scale while
    # staying at/under typical Doubao/Seed text model context ceilings.
    _CHAT_MAX_TOKENS = 32768

    def _chat(self, system_prompt: str, content: str) -> str:
        """Single-turn chat completion via Doubao/Seed text model.

        Some Seed model variants (e.g. those with extended thinking enabled)
        return the answer in ``reasoning_content`` while leaving ``content``
        as ``None`` or empty. We fall back to ``reasoning_content`` so callers
        always get a non-None string to parse.
        """
        response = _call_ark(
            self._client.chat.completions.create,
            model=self.TEXT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
            max_tokens=self._CHAT_MAX_TOKENS,
        )
        msg = response.choices[0].message
        text = msg.content or ""
        if not text:
            # Thinking-mode fallback: some BytePlus models put the answer in
            # reasoning_content and leave content empty.
            text = getattr(msg, "reasoning_content", None) or ""

        finish_reason = response.choices[0].finish_reason
        if finish_reason == "length":
            # The response was cut off by the token limit before the model
            # finished — e.g. an unclosed JSON array/fence. Surfacing this
            # clearly here (rather than only downstream as a generic
            # "unparseable" error) makes the actual cause obvious in logs.
            logger.warning(
                "_chat response truncated by max_tokens=%d: model=%s output_length=%d",
                self._CHAT_MAX_TOKENS, self.TEXT_MODEL, len(text),
            )
        if not text:
            logger.warning(
                "_chat returned empty content: model=%s finish_reason=%s",
                self.TEXT_MODEL,
                finish_reason,
            )
        return text

    # ── AI pipeline methods ───────────────────────────────────────────────────

    def _generate_asset_list_batch(
        self, story: str, existing_assets: list[dict] | None = None
    ) -> list[dict]:
        # JSON-wrap the payload per asset-list-generation.md "Input Format"
        # — existing_assets is omitted (left as an empty list) on a
        # first-time extraction, matching the "omitted or empty" language in
        # the instruction file.
        payload = json.dumps({
            "story": story,
            "existing_assets": existing_assets or [],
        })
        text = self._chat(self.ASSET_LIST_PROMPT, payload)
        extracted = _extract_json(text)
        if not extracted:
            # An opening fence with no closing one is the signature of a
            # response truncated by max_tokens before the model finished —
            # call this out explicitly rather than making the caller guess.
            looks_truncated = "```" in text and text.count("```") < 2
            hint = (
                " Response appears truncated (opening code fence with no "
                "closing fence) — the story likely produced more assets than "
                "fit within max_tokens; consider a shorter story or splitting "
                "extraction into smaller batches."
                if looks_truncated
                else ""
            )
            raise ValueError(
                f"Model returned an empty or unparseable asset list.{hint} "
                f"Raw response length: {len(text)} chars. "
                f"Preview: {text[:300]!r}"
            )
        return json.loads(extracted)

    def generate_image_prompt(
        self,
        name: str,
        type_: str,
        description: str,
        art_style: str = "painterly illustration with clean lines and rich color",
    ) -> str:
        # Include art_style in the payload so the static system prompt can apply it.
        payload = json.dumps({
            "name": name,
            "type": type_,
            "description": description,
            "art_style": art_style,
        })
        return self._chat(self.IMAGE_PROMPT, payload).strip()

    def generate_refine_story(
        self,
        story: str,
        art_style: str = "painterly illustration with clean lines and rich color",
        video_subtitles: bool = False,
        known_character_names: list[str] | None = None,
    ) -> str:
        # Plain-text output (the story rewrite itself) — unlike
        # generate_asset_list, no JSON extraction is applied to the response;
        # see refine-story-generation.md "Output".
        payload = json.dumps({
            "story": story,
            "art_style": art_style,
            "video_subtitles": video_subtitles,
            "known_character_names": known_character_names or [],
        })
        return self._chat(self.REFINE_STORY_PROMPT, payload).strip()

    def generate_video_prompt(
        self,
        scene_text: str,
        assets: list[AssetPromptInput],
        art_style: str = "painterly illustration with clean lines and rich color",
        subtitles: bool = False,
        previous_scene_prompt: str = "",
    ) -> str:
        # Serialise the input as JSON matching the instruction's Input Format
        # exactly — scene, assets (name + prompt text, no images), art_style,
        # subtitles, and previous_scene_prompt all sit at the root. This is
        # now a plain text-only call: no image parts are attached, since the
        # model infers each asset's appearance/type purely from its `prompt`
        # text (see video-prompt-generation.md). Real reference images are
        # only needed later, in generate_video. previous_scene_prompt is ""
        # for the first scene / when the prior scene has none yet.
        payload = json.dumps({
            "scene": scene_text,
            "assets": [{"name": a.name, "prompt": a.prompt} for a in assets],
            "art_style": art_style,
            "subtitles": "enabled" if subtitles else "disabled",
            "previous_scene_prompt": previous_scene_prompt,
        })
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
        # Seedream has no separate system-instruction field.  When reference
        # images are attached, prepend the variant instruction to the prompt so
        # the model knows to anchor its output to the provided visuals.
        effective_prompt = (
            f"{self.IMAGE_VARIANT_INSTRUCTION}\n\n---\n\n{prompt}"
            if ref_images
            else prompt
        )

        kwargs: dict = dict(
            model=self.IMAGE_MODEL,
            prompt=effective_prompt,
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

        response = _call_ark(self._client.images.generate, **kwargs)
        data = _download(response.data[0].url)
        return data, "image/png"

    def generate_image_description(self, image: RefImage, type_: str) -> str:
        """Vision call: describe an uploaded image (FEAT-034).

        Sends the image as a base64 data URI multimodal chat message (same
        encoding used for reference images in generate_image) alongside the
        image-description-generation.md system instruction. Text-only output.
        """
        response = _call_ark(
            self._client.chat.completions.create,
            model=self.TEXT_MODEL,
            messages=[
                {"role": "system", "content": self.IMAGE_DESCRIPTION_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": json.dumps({"type": type_})},
                        {
                            "type": "image_url",
                            "image_url": {"url": _to_data_uri(image.data, image.mime_type)},
                        },
                    ],
                },
            ],
            max_tokens=self._CHAT_MAX_TOKENS,
        )
        msg = response.choices[0].message
        text = msg.content or getattr(msg, "reasoning_content", None) or ""
        return text.strip()

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
        # Per BytePlus Seedance API: text items have no role; image_url items require
        # role="reference_image" (other valid roles: "first_frame", "last_frame").
        capped = ref_images[:self._SEEDANCE_MAX_REF_IMAGES]
        content: list[dict] = [{"type": "text", "text": storyboard}]
        for img in capped:
            content.append({
                "role": "reference_image",
                "type": "image_url",
                "image_url": {"url": _to_data_uri(img.data, img.mime_type)},
            })

        logger.info(
            "generate_video: submitting Seedance task — ref_images=%d/%d",
            len(capped), len(ref_images),
        )

        task = _call_ark(
            self._client.content_generation.tasks.create,
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

            result = _call_ark(self._client.content_generation.tasks.get, task_id=task_id)
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
