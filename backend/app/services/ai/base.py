"""Abstract AI provider interface.

Both `GeminiProvider` and `BytePlusProvider` implement this contract so the
generation router can call them interchangeably based on `X-Provider-Type`.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path

from app.config import INSTRUCTIONS_DIR


@dataclass
class RefImage:
    """In-memory image bytes + MIME type forwarded to the AI provider."""
    data: bytes
    mime_type: str


class AIProvider(ABC):
    """
    Abstract base for AI provider adapters.

    Each method maps to one generation endpoint.  All adapters receive the
    user's provider API key at construction time (BYOK — never stored).
    """

    # System prompts loaded once at import time from the instructions/ directory.
    ASSET_LIST_PROMPT: str = (INSTRUCTIONS_DIR / "asset-list-generation.md").read_text(encoding="utf-8")
    IMAGE_PROMPT: str = (INSTRUCTIONS_DIR / "image-prompt-generation.md").read_text(encoding="utf-8")
    VIDEO_PROMPT: str = (INSTRUCTIONS_DIR / "video-prompt-generation.md").read_text(encoding="utf-8")
    # Applied only for variant generation (when reference images are attached).
    IMAGE_VARIANT_INSTRUCTION: str = (INSTRUCTIONS_DIR / "image-variant-generation.md").read_text(encoding="utf-8")

    def __init__(self, api_key: str):
        """
        Args:
            api_key: The user's own provider API key from `X-Provider-Key`.
                     Used in-flight only — never logged or persisted.
        """
        self._api_key = api_key

    @abstractmethod
    def generate_asset_list(self, story: str) -> list[dict]:
        """Return a list of asset dicts matching the AssetsResponse schema."""

    @abstractmethod
    def generate_image_prompt(
        self,
        name: str,
        type_: str,
        description: str,
        art_style: str = "painterly illustration with clean lines and rich color",
    ) -> str:
        """Return a generated image prompt string.

        Args:
            name: Asset name.
            type_: Asset type — ``"character"``, ``"background"``, or ``"object"``.
            description: Human-written asset description.
            art_style: Project-level visual style injected into the AI payload so
                the system prompt can apply it. Defaults to painterly illustration.
        """

    @abstractmethod
    def generate_video_prompt(
        self,
        scene_text: str,
        ref_images: list[RefImage],  # fetched from GCS by the router
        art_style: str = "painterly illustration with clean lines and rich color",
        subtitles: bool = False,
    ) -> str:
        """Return a storyboard prompt string (written to Firestore storyboard_body).

        Args:
            scene_text: The scene body from story_content.
            ref_images: Reference images fetched from GCS by the router.
            art_style: Project-level visual style appended to the scene input so the
                system prompt applies it in the closing block.
            subtitles: When ``True``, the subtitle-free constraint is omitted from
                the closing block so ``【】`` subtitle syntax is respected.
        """

    @abstractmethod
    def generate_image(self, prompt: str, ref_images: list[RefImage]) -> tuple[bytes, str]:
        """Return (raw_bytes, mime_type) for the generated image."""

    @abstractmethod
    def generate_video(
        self,
        storyboard: str,
        ref_images: list[RefImage],
    ) -> tuple[bytes, str]:
        """Return (raw_bytes, mime_type) for the generated video."""
