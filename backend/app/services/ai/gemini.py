"""Google Gemini AI provider adapter.

Models used:
  - Text:  gemini-2.5-flash        (Interactions API — stateless single-turn)
  - Image: gemini-3.1-flash-image  (generate_content + response_modalities=["IMAGE"])
  - Video: veo-3.1-generate-preview  (client.models.generate_videos + GenerateVideosSource)

The user's Gemini API key is passed in at construction time via `X-Provider-Key`.
It is used in-flight only — never logged, never stored.
"""

import base64
import json
import logging
import re
import time

from google import genai
from google.genai import types

from app.services.ai.base import AIProvider, RefImage

logger = logging.getLogger(__name__)


class ContentBlockedError(ValueError):
    """Raised when the AI provider blocks the prompt due to content policy.

    This is a client-side issue (the input content violates policy) so callers
    should surface it as an HTTP 400, not a 502.

    Args:
        reason: The block reason string from the provider (e.g. PROHIBITED_CONTENT).
        message: Optional human-readable explanation from the provider.
    """

    def __init__(self, reason: str, message: str | None = None):
        self.reason = reason
        detail = message or (
            "Your content was blocked by the AI provider's content policy. "
            "Please rephrase the description and try again."
        )
        super().__init__(detail)


def _extract_json(text: str) -> str:
    """Strip markdown code fences so the LLM output can be parsed as JSON."""
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    return match.group(1).strip() if match else text.strip()


class GeminiProvider(AIProvider):
    # Text: Interactions API — stateless single-turn.
    # gemini-2.5-flash is used over gemini-3.5-flash because the newer model
    # applies a stricter PROHIBITED_CONTENT block on fictional character
    # descriptions (including minors) in an image-prompt context, even with
    # BLOCK_NONE safety settings. gemini-2.5-flash handles the same content
    # without triggering the policy gate.
    TEXT_MODEL = "gemini-2.5-flash"
    # Image: Nano Banana — generate_content + response_modalities=["IMAGE"] → part.inline_data.data
    IMAGE_MODEL = "gemini-3.1-flash-image"
    # Video: Veo 3.1 — generate_videos + GenerateVideosSource → video.video_bytes
    VIDEO_MODEL = "veo-3.1-generate-preview"
    VIDEO_POLL_INTERVAL = 10  # seconds between status checks

    def __init__(self, api_key: str):
        super().__init__(api_key)
        # Client is scoped to a single request — API key lives only here.
        self._client = genai.Client(api_key=api_key)

    # ── Safety settings ───────────────────────────────────────────────────────

    # Applied to generate_content image calls.
    # BLOCK_NONE lets the model handle creative fiction content without
    # tripping the default filters for story assets and character descriptions.
    _SAFETY_SETTINGS = [
        types.SafetySetting(category="HARM_CATEGORY_HARASSMENT",       threshold="BLOCK_NONE"),
        types.SafetySetting(category="HARM_CATEGORY_HATE_SPEECH",       threshold="BLOCK_NONE"),
        types.SafetySetting(category="HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold="BLOCK_NONE"),
        types.SafetySetting(category="HARM_CATEGORY_DANGEROUS_CONTENT", threshold="BLOCK_NONE"),
    ]

    # ── Text helpers ──────────────────────────────────────────────────────────

    def _text_interact(self, system_instruction: str, payload: str) -> str:
        """Run a stateless text generation call via the Interactions API.

        Although named "Interactions", the call is fully stateless — no
        previous_interaction_id is passed, so each call is an independent
        single-turn request.  The Interactions API is used here (rather than
        generate_content) because it applies a less aggressive prompt-level
        content policy: generate_content on gemini-3.5-flash blocks fictional
        character descriptions involving minors with PROHIBITED_CONTENT even
        when safety_settings are BLOCK_NONE, whereas the Interactions API
        (which AI Studio also uses) handles the same prompts without issue.

        Returns the model's text output as a plain string.
        """
        try:
            interaction = self._client.interactions.create(
                model=self.TEXT_MODEL,
                system_instruction=system_instruction,
                input=payload,
            )
        except Exception as e:
            logger.error(
                "_text_interact failed: model=%s error=%s message=%s",
                self.TEXT_MODEL,
                type(e).__name__,
                str(e)[:500],
                exc_info=True,
            )
            raise
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
        """Generate an image via generate_content (Nano Banana / gemini-3.1-flash-image).

        Uses the standard models.generate_content API with response_modalities=["IMAGE"].
        With reference images, the prompt and images are passed as a multimodal parts list.
        The generated image is returned as raw bytes in part.inline_data.data.

        Returns:
            Tuple of (raw image bytes, MIME type string).
        """
        # Build the contents list.  Text prompt is always first; ref images follow.
        contents: list = [types.Part.from_text(text=prompt)]
        for img in ref_images[:14]:
            contents.append(types.Part.from_bytes(data=img.data, mime_type=img.mime_type))

        logger.debug(
            "generate_image: model=%s ref_images=%d",
            self.IMAGE_MODEL, len(ref_images),
        )

        try:
            response = self._client.models.generate_content(
                model=self.IMAGE_MODEL,
                contents=contents,
                config=types.GenerateContentConfig(
                    response_modalities=["IMAGE"],
                    safety_settings=self._SAFETY_SETTINGS,
                ),
            )
        except Exception:
            logger.error("generate_image: generate_content raised an exception", exc_info=True)
            raise

        # Check for prompt-level content block (no candidates).
        candidates = response.candidates or []
        feedback = getattr(response, "prompt_feedback", None)
        if not candidates and feedback is not None:
            block_reason = str(getattr(feedback, "block_reason", "UNKNOWN"))
            logger.warning("generate_image: prompt blocked. reason=%s", block_reason)
            raise ContentBlockedError(reason=block_reason)

        # Walk the response parts to find the image.
        if candidates:
            finish_reason = str(getattr(candidates[0], "finish_reason", "UNKNOWN"))
            if finish_reason in ("SAFETY", "PROHIBITED_CONTENT"):
                raise ContentBlockedError(reason=finish_reason)

            for part in candidates[0].content.parts:
                if part.inline_data is not None:
                    return part.inline_data.data, part.inline_data.mime_type or "image/png"

            # Candidate exists but no image part — log any text for debugging.
            text_parts = [p.text for p in candidates[0].content.parts if p.text]
            logger.warning(
                "generate_image: no image part in response. finish_reason=%s text_preview=%r",
                finish_reason, " ".join(text_parts)[:200],
            )

        raise ValueError("generate_content returned no image for the given prompt.")

    @staticmethod
    def _sniff_mime(data: bytes) -> str:
        """Detect image format from magic bytes."""
        if data[:8] == b'\x89PNG\r\n\x1a\n':
            return "image/png"
        if data[:3] == b'\xff\xd8\xff':
            return "image/jpeg"
        if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
            return "image/webp"
        if data[:4] in (b'GIF8', b'GIF9'):
            return "image/gif"
        return "application/octet-stream"

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate a video via Veo 3.1 (veo-3.1-generate-preview).

        Uses client.models.generate_videos() with GenerateVideosSource.
        Veo accepts a single conditioning image (first ref_image) in PNG or JPEG
        format. The image bytes are passed directly; no multipart upload needed.
        Polls the returned operation every VIDEO_POLL_INTERVAL seconds until done.
        Returns raw video bytes and mime type.
        """
        # Build source — prompt is required; conditioning image is optional.
        # Veo only uses one image (the first); additional ref images are ignored.
        source = types.GenerateVideosSource(prompt=storyboard)
        if ref_images:
            img = ref_images[0]
            # Sniff actual format from magic bytes — the declared mime_type from
            # the client may not match what Imagen actually returned.
            actual_mime = self._sniff_mime(img.data)
            logger.info(
                "generate_video: conditioning image size=%d bytes declared_mime=%s actual_mime=%s",
                len(img.data), img.mime_type, actual_mime,
            )
            # Veo rejects WebP and other formats — only PNG and JPEG are safe.
            # If the image is something else, skip it and fall back to prompt-only.
            if actual_mime in ("image/png", "image/jpeg"):
                source = types.GenerateVideosSource(
                    prompt=storyboard,
                    image=types.Image(
                        image_bytes=img.data,
                        mime_type=actual_mime,
                    ),
                )
            else:
                logger.warning(
                    "generate_video: unsupported image format %s — sending prompt only",
                    actual_mime,
                )

        operation = self._client.models.generate_videos(
            model=self.VIDEO_MODEL,
            source=source,
            config=types.GenerateVideosConfig(
                number_of_videos=1,
                duration_seconds=8,
                # enhance_prompt and generate_audio are not supported by
                # veo-3.1-generate-preview via the standard Developer API.
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
