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
    def generate_image_prompt(self, name: str, type_: str, description: str) -> str:
        """Return a generated image prompt string."""

    @abstractmethod
    def generate_video_prompt(
        self,
        scene_text: str,
        assets: list[dict],   # [{"name": str, "type": str, "image": RefImage}]
    ) -> str:
        """Return a storyboard prompt string (written to ark.mdx body)."""

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
