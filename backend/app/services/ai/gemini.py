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
from google.genai import errors as genai_errors
from google.genai import types

from app.services.ai.base import AIProvider, AIProviderError, RefImage

logger = logging.getLogger(__name__)


def _call_genai(fn, *args, **kwargs):
    """
    Call a Gemini SDK method, translating ``google.genai.errors.APIError``
    into the shared ``AIProviderError`` — same rationale as
    ``byteplus._call_ark``: give callers a clean, structured message instead
    of the SDK's raw exception or a generic fallback string.
    """
    try:
        return fn(*args, **kwargs)
    except genai_errors.APIError as e:
        raise AIProviderError(
            provider="Gemini",
            status_code=getattr(e, "code", None),
            provider_error_code=getattr(e, "status", None),
            message=e.message or str(e),
        ) from e


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
            interaction = _call_genai(
                self._client.interactions.create,
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
        return self._text_interact(self.IMAGE_PROMPT, payload)

    def generate_video_prompt(
        self,
        scene_text: str,
        ref_images: list[RefImage],
        art_style: str = "painterly illustration with clean lines and rich color",
        subtitles: bool = False,
    ) -> str:
        # Serialise the input as JSON matching the instruction's Input Format.
        # art_style and subtitles sit at the root alongside scene and assets.
        # (assets[] prompts are not available at this layer — ref images are passed
        # as inline image parts below; the model uses Image N ordering to map them.)
        payload = json.dumps({
            "scene": scene_text,
            "art_style": art_style,
            "subtitles": "enabled" if subtitles else "disabled",
        })
        # Build a multimodal content list: system text + image parts for each ref_image.
        # Uses generate_content (not Interactions API) because the Interactions API
        # does not accept image parts.
        contents: list = [
            types.Part.from_text(
                text=f"{self.VIDEO_PROMPT}\n\n---\n\n{payload}"
            )
        ]
        for img in ref_images[:8]:  # cap at 8 ref images for video prompt
            contents.append(types.Part.from_bytes(data=img.data, mime_type=img.mime_type))

        config = types.GenerateContentConfig(
            safety_settings=self._SAFETY_SETTINGS,
        )
        response = _call_genai(
            self._client.models.generate_content,
            model=self.TEXT_MODEL,
            contents=contents,
            config=config,
        )
        return (response.text or "").strip()

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
        print("No of ref images:", len(ref_images))
        for img in ref_images[:14]:
            contents.append(types.Part.from_bytes(data=img.data, mime_type=img.mime_type))

        logger.debug(
            "generate_image: model=%s ref_images=%d",
            self.IMAGE_MODEL, len(ref_images),
        )

        # Include a system instruction when reference images are attached so the
        # model knows to treat them as authoritative visual references rather
        # than ignoring or de-prioritising them.
        config = types.GenerateContentConfig(
            response_modalities=["IMAGE"],
            safety_settings=self._SAFETY_SETTINGS,
            system_instruction=self.IMAGE_VARIANT_INSTRUCTION if ref_images else None,
        )

        try:
            response = _call_genai(
                self._client.models.generate_content,
                model=self.IMAGE_MODEL,
                contents=contents,
                config=config,
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

    # Veo 3.1 accepts up to 3 reference images per request (asset type only).
    # PNG and JPEG are the only accepted formats; WebP and others are rejected.
    _VEO_MAX_REF_IMAGES = 3
    _VEO_ACCEPTED_FORMATS = frozenset({"image/png", "image/jpeg"})

    def generate_video(self, storyboard: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Generate a video via Veo 3.1 (veo-3.1-generate-preview).

        Uses client.models.generate_videos() with up to 3 reference images passed
        as VideoGenerationReferenceImage entries in GenerateVideosConfig.reference_images.
        Reference images use reference_type="asset" — the only type supported by the
        Developer API as of June 2026.

        Image format handling:
        - Actual MIME type is sniffed from magic bytes (the declared type from the
          client may not match what the image model returned).
        - Only PNG and JPEG are forwarded. WebP/GIF/unknown are skipped with a warning.
        - Images are capped at _VEO_MAX_REF_IMAGES (3). Excess images are dropped.

        Polls the returned operation every VIDEO_POLL_INTERVAL seconds until done.
        Returns raw video bytes and MIME type.
        """
        # Filter to accepted formats only, cap at the Veo limit.
        veo_ref_images: list[types.VideoGenerationReferenceImage] = []
        for img in ref_images:
            if len(veo_ref_images) >= self._VEO_MAX_REF_IMAGES:
                logger.info(
                    "generate_video: dropping ref image — Veo limit of %d reached",
                    self._VEO_MAX_REF_IMAGES,
                )
                break
            actual_mime = self._sniff_mime(img.data)
            logger.info(
                "generate_video: ref image size=%d bytes declared_mime=%s actual_mime=%s",
                len(img.data), img.mime_type, actual_mime,
            )
            if actual_mime not in self._VEO_ACCEPTED_FORMATS:
                logger.warning(
                    "generate_video: skipping ref image with unsupported format %s",
                    actual_mime,
                )
                continue
            veo_ref_images.append(
                types.VideoGenerationReferenceImage(
                    image=types.Image(image_bytes=img.data, mime_type=actual_mime),
                    reference_type="asset",
                )
            )

        logger.info(
            "generate_video: sending %d/%d ref images to Veo 3.1",
            len(veo_ref_images), len(ref_images),
        )

        operation = _call_genai(
            self._client.models.generate_videos,
            model=self.VIDEO_MODEL,
            prompt=storyboard,
            config=types.GenerateVideosConfig(
                number_of_videos=1,
                duration_seconds=8,
                # Reference images are passed here — not in the source/prompt field.
                # enhance_prompt and generate_audio are not supported by
                # veo-3.1-generate-preview via the standard Developer API.
                reference_images=veo_ref_images or None,
            ),
        )

        # Poll until the operation completes (typically 2–5 minutes for Veo 3.1).
        while not operation.done:
            time.sleep(self.VIDEO_POLL_INTERVAL)
            operation = _call_genai(self._client.operations.get, operation)

        # Surface operation-level errors before inspecting the response body.
        op_error = getattr(operation, "error", None)
        if op_error:
            logger.error("generate_video: operation finished with error: %s", repr(op_error))
            raise ValueError(f"Veo 3.1 operation failed: {op_error}")

        # Log the full operation response so we can diagnose failures where
        # generated_videos is empty (content block, quota error, etc.).
        response = operation.response
        logger.info(
            "generate_video: operation done — response type=%s repr=%s",
            type(response).__name__,
            repr(response)[:1000],
        )

        generated = getattr(response, "generated_videos", None) or []
        if not generated:
            # Try to surface a reason from the operation metadata if available.
            error = getattr(operation, "error", None)
            reason = repr(error) if error else "no generated_videos in response and no error detail"
            raise ValueError(f"Veo 3.1 returned no video. Reason: {reason}")

        video = generated[0].video
        logger.info(
            "generate_video: response video_bytes=%s uri=%s mime_type=%s",
            "present" if getattr(video, "video_bytes", None) else "absent",
            getattr(video, "uri", None),
            getattr(video, "mime_type", None),
        )

        # The Developer API returns a GCS URI rather than inline bytes.
        # Fetch the bytes from the URI using the SDK's file download helper.
        if getattr(video, "video_bytes", None) is not None:
            return video.video_bytes, video.mime_type or "video/mp4"

        uri = getattr(video, "uri", None)
        if uri:
            logger.info("generate_video: fetching video bytes from URI %s", uri)
            video_bytes = _call_genai(self._client.files.download, file=uri)
            return bytes(video_bytes), video.mime_type or "video/mp4"

        raise ValueError(
            f"Veo 3.1 returned no video bytes and no URI. "
            f"Full video object: {video!r}"
        )
