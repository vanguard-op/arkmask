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


@dataclass
class AssetPromptInput:
    """
    A single scene asset's name and its already-generated image prompt text,
    as consumed by `generate_video_prompt` (see
    backend/instructions/video-prompt-generation.md "Input Format").

    Deliberately does NOT carry image bytes — the storyboard-prompt model
    only reads the asset's `prompt` text to understand its visual appearance
    and type; the actual reference images are only needed later, by
    `generate_video`, once the storyboard prompt exists.
    """
    name: str
    prompt: str


class AIProviderError(Exception):
    """
    A clean, structured error raised when an AI provider (Gemini or BytePlus)
    returns a 4xx/5xx response.

    Both provider SDKs already parse structured error info (status code,
    provider-specific error type, human message) — this wraps that into one
    consistent shape so callers (generation.py, workers/app/tasks/*.py) get a
    useful message instead of either the raw SDK exception's repr or a
    hard-coded generic string that discards what the provider actually said.

    Example: a BytePlus account with an unpaid balance returns HTTP 403 with
    body `{"type": "Forbidden", "message": "...overdue balance...", "code":
    "AccountOverdueError"}` — previously this surfaced to the user/logs as a
    bare "AI provider error during X." or FastAPI's generic "An internal
    server error occurred." Now it surfaces as e.g.:
        "BytePlus API error 403 (AccountOverdueError): The request failed
        because your account has an overdue balance."
    """

    def __init__(
        self,
        provider: str,
        status_code: int | None,
        provider_error_code: str | None,
        message: str,
    ):
        self.provider = provider
        self.status_code = status_code
        self.provider_error_code = provider_error_code
        self.message = message
        super().__init__(str(self))

    def __str__(self) -> str:
        code_part = f" {self.status_code}" if self.status_code else ""
        type_part = f" ({self.provider_error_code})" if self.provider_error_code else ""
        return f"{self.provider} API error{code_part}{type_part}: {self.message}"


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
    # FEAT-034 — vision-model call that turns an uploaded image into a text
    # description usable as a normal asset `description` field.
    IMAGE_DESCRIPTION_PROMPT: str = (INSTRUCTIONS_DIR / "image-description-generation.md").read_text(encoding="utf-8")
    # FEAT-038 — full-story rewrite for video-generation clarity (scene
    # splitting, continuity, explicit dialogue attribution, fully-specified
    # action/staging). Plain-text in, plain-text out — see
    # backend/instructions/refine-story-generation.md.
    REFINE_STORY_PROMPT: str = (INSTRUCTIONS_DIR / "refine-story-generation.md").read_text(encoding="utf-8")

    def __init__(self, api_key: str):
        """
        Args:
            api_key: The user's own provider API key from `X-Provider-Key`.
                     Used in-flight only — never logged or persisted.
        """
        self._api_key = api_key

    @abstractmethod
    def generate_asset_list(self, story: str, existing_assets: list[dict] | None = None) -> list[dict]:
        """Return a list of asset dicts matching the AssetsResponse schema.

        Args:
            story: The full current `story_content` value.
            existing_assets: Assets already saved for this project (resolved
                server-side from Firestore by the caller — see
                workers/app/tasks/assets.py::run), each shaped as
                ``{name, type, description, scene_number}``. ``None`` or an
                empty list on a first-time extraction. When present, per
                backend/instructions/asset-list-generation.md "Input Format"
                / "Existing-Assets Rules", the model must never re-emit an
                asset already covered here — only genuinely missing assets
                are returned.
        """

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
        assets: list[AssetPromptInput],
        art_style: str = "painterly illustration with clean lines and rich color",
        subtitles: bool = False,
        previous_scene_prompt: str = "",
    ) -> str:
        """Return a storyboard prompt string (written to Firestore storyboard_body).

        No images are sent for this call — see
        backend/instructions/video-prompt-generation.md "Input Format". The
        model reads each asset's `name` and previously-generated `prompt`
        text only; the real reference images are attached later, in
        `generate_video`.

        Args:
            scene_text: The scene body from story_content, resolved server-side
                by `app.services.scene_assets.parse_scene_text`.
            assets: This scene's resolved reference assets (name + prompt text),
                in priority order — see `app.services.scene_assets.resolve_scene_assets`.
            art_style: Project-level visual style appended to the scene input so the
                system prompt applies it in the closing block.
            subtitles: When ``True``, the subtitle-free constraint is omitted from
                the closing block so ``【】`` subtitle syntax is respected.
            previous_scene_prompt: The previous scene's own generated video prompt
                (its `storyboard_body`), or ``""`` when there is no previous scene
                (first scene) or it has none yet. Used by the model for continuity
                inference only — see backend/instructions/video-prompt-generation.md
                "Continuity Inference": whether the new scene picks up directly from
                the last shot or is a hard cut is decided from THIS scene's own
                `scene_text`/`assets`, not defaulted from the presence of this field.
        """

    @abstractmethod
    def generate_refine_story(
        self,
        story: str,
        art_style: str = "painterly illustration with clean lines and rich color",
        video_subtitles: bool = False,
        known_character_names: list[str] | None = None,
    ) -> str:
        """Return the full rewritten story text (FEAT-038, `POST /refine-story`).

        Plain text in, plain text out — no JSON wrapper on either side. See
        backend/instructions/refine-story-generation.md "Input Format" /
        "Output". The caller writes the result to the project document's
        `refined_story_preview` field; `story_content` is never touched here.

        Args:
            story: The full current `story_content` value (scene-segmented,
                `# N` headings).
            art_style: The project's `generation_settings.art_style` —
                informational only, not applied to scene content by this call.
            video_subtitles: The project's `generation_settings.video_subtitles`
                — controls whether existing `【】` subtitle syntax is preserved.
            known_character_names: Names of already-extracted character assets
                for this project (resolved server-side from Firestore), so the
                rewrite keeps `@` asset references resolvable downstream. Empty
                or ``None`` when no prior extraction has run.
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

    @abstractmethod
    def generate_image_description(self, image: RefImage, type_: str) -> str:
        """Return a generated text description of an uploaded image (FEAT-034).

        Uses ``backend/instructions/image-description-generation.md``. The
        returned description is presented to the user for review/edit before
        being saved as the asset's `description` field — it is not written to
        Firestore automatically.

        Args:
            image: The uploaded reference image bytes fetched from GCS.
            type_: Asset type — ``"character"``, ``"background"``, or ``"object"``
                — tailors the focus of the generated description.
        """
