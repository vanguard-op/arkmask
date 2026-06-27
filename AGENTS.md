# AGENTS.md — ArkMask

## Source of Truth

`docs/ArkMask/` is the **primary source of truth** for all product requirements, feature definitions,
design decisions, and business logic. This file is a complementary quick-reference for agents working
on the codebase — it does not replace the docs.

---

## Tech Stack

| Layer | Technology | Pinned Version |
|---|---|---|
| Flutter version manager | FVM (Flutter Version Manager) | `3.x` — use `fvm flutter` for all Flutter commands |
| Mobile client | Flutter (iOS + Android) | `3.44.0` (stable) / Dart `3.10` — pinned via FVM |
| State management | Bloc / Cubit (`flutter_bloc`) | `flutter_bloc 9.1.1` / `bloc 9.2.1` |
| Navigation | GoRouter | `14.x` |
| Backend API | FastAPI | `0.115.x` |
| Backend runtime | Python | `3.12` |
| Database | PostgreSQL | `15` (Cloud SQL prod; Docker local) |
| Auth | Firebase Auth (email/password) | `firebase_auth` Flutter `5.x`; Firebase Admin SDK `6.x` (backend) |
| Push notifications | Firebase Cloud Messaging | `firebase_messaging` Flutter `15.x` |
| Object storage | GCS (prod) / MinIO (local dev) | GCS client lib `2.x` |
| Billing | Stripe | `stripe_flutter 10.x` (Android); Stripe-hosted web page (iOS — reader app exception) |
| Async video jobs | Google Cloud Tasks | `google-cloud-tasks 2.x` |
| On-device video editing | `ffmpeg_kit_flutter` | `6.0.3` — **pin; do not upgrade without full trim + export test** |
| Video playback | `video_player` | `2.9.x` |
| Secure storage | `flutter_secure_storage` | `9.x` |
| HTTP client (Flutter) | `dio` | `5.x` |
| HTTP client (FastAPI) | `httpx` | `0.27.x` |
| Icons | `lucide_flutter` | `0.3.x` |
| Fonts | `google_fonts` or bundled assets | — |
| Local dev | Docker Compose | — |

**Fonts:** `DM Sans` and `JetBrains Mono` are loaded via the `google_fonts` package — no font files in `assets/`. Do not declare them under `flutter.fonts` in `pubspec.yaml`.
**Icons:** All standard icons come from the `lucide_flutter` package — no SVG files needed in `assets/`. Custom icons (ArkMask mask symbol for splash/app icon) live in `assets/images/`.

---

## Project Structure

```
ark-mask/
├── mobile/                          # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart                 # MaterialApp, GoRouter, ThemeData wiring
│   │   ├── core/
│   │   │   ├── theme/               # AppTheme: color tokens, text styles, spacing constants
│   │   │   ├── router/              # GoRouter definitions, route guards (auth + provider)
│   │   │   ├── auth/                # AuthService: Firebase Auth + secure storage session
│   │   │   ├── api/                 # ArkMaskApiClient (Dio), Dio interceptor (headers), error models
│   │   │   ├── storage/             # SecureStorageService: platform key, provider type + key
│   │   │   ├── filesystem/          # ProjectFileService: on-device directory + MDX operations
│   │   │   ├── jobs/                # GenerationJobManager: polling loop, FCM bridge, job state
│   │   │   └── utils/               # Extensions, date formatters, validators, size formatter
│   │   ├── features/
│   │   │   ├── auth/                # FEAT-001, FEAT-002, FEAT-031
│   │   │   ├── provider_setup/      # FEAT-003, FEAT-022
│   │   │   ├── projects/            # FEAT-004, FEAT-005, FEAT-006, FEAT-007, FEAT-027, FEAT-028
│   │   │   ├── story_editor/        # FEAT-008, FEAT-009
│   │   │   ├── asset_editor/        # FEAT-010, FEAT-011, FEAT-012, FEAT-013
│   │   │   ├── scene_detail/        # FEAT-014, FEAT-015, FEAT-016, FEAT-017
│   │   │   ├── video_editor/        # FEAT-018, FEAT-019, FEAT-020, FEAT-021
│   │   │   ├── settings/            # FEAT-022, FEAT-023, FEAT-025
│   │   │   ├── usage/               # FEAT-024
│   │   │   ├── upgrade/             # Flow 6 — Upgrade / Paywall
│   │   │   └── video_player/        # FEAT-026 — In-app video player (Phase 5)
│   │   └── shared/
│   │       ├── widgets/             # GenerationStepDots, FileBrowserRow, CreditPill, etc.
│   │       └── models/              # AssetFrontmatter, SceneFrontmatter, shared DTOs
│   ├── assets/
│   │   └── images/                  # ArkMask SVG symbol mark (splash, app icon) + any raster assets
│   ├── test/
│   │   ├── unit/
│   │   └── widget/
│   └── pubspec.yaml
│
├── backend/                         # FastAPI — stateless AI proxy on GCP Cloud Run
│   ├── app/
│   │   ├── main.py                  # FastAPI app entrypoint + middleware
│   │   ├── routers/
│   │   │   ├── auth.py              # POST /register, POST /login, GET /me, GET /me/credits
│   │   │   ├── generation.py        # POST /assets, /image-prompt, /image, /video-prompt, /video
│   │   │   ├── jobs.py              # GET /video/{job_id}/status
│   │   │   ├── usage.py             # GET /usage
│   │   │   └── billing.py           # POST /webhook/stripe, POST /keys/regenerate
│   │   ├── providers/
│   │   │   ├── base.py              # AIProvider abstract base class
│   │   │   ├── gemini.py            # Google Gemini adapter (flash, image, Veo 2.0)
│   │   │   └── byteplus.py          # BytePlus Ark adapter (Doubao, Seedream, Seedance 2.0)
│   │   ├── services/
│   │   │   ├── auth_service.py      # Firebase Admin token verification, platform key issuance
│   │   │   ├── billing_service.py   # Atomic credit check + deduction; Stripe webhook handler
│   │   │   ├── gcs_service.py       # GCS / MinIO upload + presigned URL (2-hour TTL)
│   │   │   ├── fcm_service.py       # FCM push on video job completion
│   │   │   └── tasks_service.py     # Google Cloud Tasks enqueue for async /video jobs
│   │   ├── models/
│   │   │   ├── db.py                # SQLAlchemy ORM: users, usage_events, stripe_subscriptions
│   │   │   └── schemas.py           # Pydantic v2 request + response models
│   │   ├── db.py                    # SQLAlchemy async engine + session factory
│   │   └── config.py                # Pydantic Settings from environment variables
│   ├── migrations/                  # Alembic migrations
│   ├── tests/
│   ├── Dockerfile
│   ├── docker-compose.yml           # FastAPI + PostgreSQL 15 + MinIO
│   ├── pyproject.toml
│   └── .env.example
│
└── docs/
    └── ArkMask/                     # Source of truth — see Document Map
```

Each `features/<name>/` directory follows this internal layout:
```
features/<name>/
├── screens/              # Screen widgets (one file per screen)
├── widgets/              # Feature-local reusable widgets
├── cubit/                # Cubit + state classes for simple state
│   ├── <name>_cubit.dart
│   └── <name>_state.dart
├── bloc/                 # Bloc + event + state classes for event-driven state
│   ├── <name>_bloc.dart
│   ├── <name>_event.dart
│   └── <name>_state.dart
└── models.dart           # Feature-local data models (if not in shared/models)
```

**Cubit vs Bloc guidance:**
- Use **Cubit** for straightforward UI state with simple method calls (e.g., form inputs, toggle visibility, settings changes, project list loading).
- Use **Bloc** when state changes are driven by discrete, named events that need to be logged, replayed, or tested individually (e.g., generation job lifecycle: `GenerationStarted`, `GenerationPolling`, `GenerationSucceeded`, `GenerationFailed`).
- Generation pipeline features (`asset_editor`, `scene_detail`, `video_editor`) use **Bloc** — their job state transitions are event-driven and complex.
- Auth, settings, and project management features use **Cubit** — simpler, fewer state transitions.

---

## Coding Style & Conventions

### Flutter / Dart

- **State management:** Bloc / Cubit (`flutter_bloc 9.1.1`). No Riverpod, no Provider, no `setState` except for purely local widget animation state (e.g., `AnimationController`).
  - Cubits and Blocs are provided at the appropriate subtree level via `BlocProvider` or `MultiBlocProvider`.
  - Screens read state with `BlocBuilder`, react to one-off events with `BlocListener`, and do both with `BlocConsumer`.
  - State classes use `sealed` + subclasses pattern (e.g., `sealed class ProjectState {}`, `final class ProjectLoaded extends ProjectState {}`). This enables exhaustive pattern matching in `BlocBuilder`.
  - Every state class is immutable (`@immutable`). Use `copyWith` for partial state updates.
  - All async logic (API calls, file I/O) runs inside the Cubit/Bloc method — never in a widget.
- **Navigation:** GoRouter only. Route name constants live in `core/router/routes.dart`. Route guards (auth, provider credentials) are implemented as `redirect` callbacks on the router, not in widget `initState` or Bloc methods.
- **No business logic in widgets.** Widgets call Cubit methods or dispatch Bloc events. All file I/O, API calls, and state transitions happen inside Cubits/Blocs or injected service classes.
- **FVM:** Always use `fvm flutter` and `fvm dart` — never bare `flutter` or `dart` commands. The pinned version is `3.44.0` (Dart `3.10`), declared in `mobile/.fvm/fvm_config.json`.
- **Naming:** `snake_case` for files; `PascalCase` for classes and enums; `camelCase` for variables and methods; `_prefixed` for private members.
- **Theme tokens — mandatory:**
  - Colors: `context.theme.colors.<tokenName>` — **never** use raw hex strings in widget code.
  - Text styles: `context.theme.textStyles.<tokenName>` — **never** hardcode `fontSize` or `fontWeight`.
  - Spacing: `AppTheme.spacing.<tokenName>` constants — **never** hardcode pixel padding values.
- **API calls:** Always go through `ArkMaskApiClient`. Never instantiate `Dio` directly in a feature file.
- **Generation request headers:** Injected by the Dio interceptor in `core/api/`. Never add `X-Platform-Key`, `X-Provider-Type`, or `X-Provider-Key` manually in feature code.
- **All screen states are mandatory.** Every screen defined in `docs/ArkMask/screens.md` must implement every listed state (loading, empty, error, offline, submitting, edge cases). A screen stub that shows only the loaded state is incomplete.
- **Docstrings:** `///` dartdoc on all public classes, public methods, and non-obvious private helpers. Describe what it does, not just what it is called.
- **Accessibility:** Every icon button must have a `Tooltip` or `semanticLabel`. All asset images set `semanticsLabel` from the asset's `description` field.

### FastAPI / Python

- **Type hints everywhere:** all function parameters and return types, including `-> None`.
- **`async def`** for all route handlers and any I/O-bound service method.
- **Pydantic v2** for all request bodies, response models, and settings.
- **Separation:** route handlers call service methods; service methods contain business logic; database operations stay in the service layer via SQLAlchemy.
- **Credit deduction atomicity:** `INSERT INTO usage_events` and `UPDATE users SET credit_balance` always execute in a single `async with session.begin()` transaction. A deduction committed without a corresponding usage event (or vice versa) is a data integrity bug.
- **Provider key security:** `X-Provider-Key` header value must never appear in any log statement, exception message, Sentry capture, or database field. Log the provider *type*, not the key.
- **Platform key storage:** stored as a bcrypt hash in `users.platform_api_key`. The raw key is returned once in the registration response and is not recoverable from the backend.
- **Linting:** `ruff` for lint and format. `mypy` for type checking. Both must pass clean before a PR is merged.

---

## Behavior Rules

- **Never commit secrets.** `.env`, Firebase service account JSON, GCS keys are gitignored. Production secrets live in GCP Secret Manager.
- **Run tests before pushing.** `flutter test` (zero failures) and `pytest` (zero failures) are blocking gates.
- **Feature branches only.** Naming convention: `feat/<FEAT-ID>-short-description` (e.g., `feat/feat-016-generate-video`).
- **Credits deduct only on terminal success.** If a generation request results in a provider error (5xx), a network timeout, or a Cloud Tasks worker failure — zero credits are deducted. A refund event is written to `usage_events` if a deduction row was already committed. See `docs/ArkMask/monetization.md`.
- **`video.mp4` source files are immutable.** Trim in/out points are stored in app state and applied at FFmpeg export time. No feature code may write to or rename an existing `video.mp4`. Only the export step writes `final.mp4`.
- **Character reference images capped at 4 per scene.** Any code path calling `/video-prompt` or `/video` must count character-type assets with `image.png` and show a warning dialog before sending if the count exceeds 4. See `docs/ArkMask/features.md` FEAT-014 and FEAT-016.
- **Subtitle suppression is mandatory in every storyboard.** The `/video-prompt` prompt template must always include the subtitle suppression instruction text. This is not optional or user-configurable.
- **GCS presigned URLs are ephemeral (2-hour TTL).** Download and save to device immediately. If a URL expires before download completes, request a fresh URL from the backend via job ID. Never treat GCS as durable storage.
- **iOS billing — no native payment UI.** On iOS, tapping any upgrade or "Manage Subscription" action opens a Stripe-hosted web page in Safari (`launchUrl` with `LaunchMode.externalApplication`). The `stripe_flutter` payment sheet is rendered only on Android. See `docs/ArkMask/architecture.md`.
- **Project count gate is account-scoped.** When enforcing the Free tier 1-project limit, count only directories associated with the current authenticated account — not all directories in the app's Documents folder. See `docs/ArkMask/monetization.md` gate logic.
- **Offline writing always works.** The story editor, asset description editor, and storyboard editor must remain fully editable with auto-save to local filesystem when the device is offline. Only generation API calls require connectivity.
- **No background batch generation.** Every generation step is user-triggered. No code may fire a generation request without an explicit user action. See `docs/ArkMask/README.md` core workflow.
- **Generation job state survives navigation.** If a user navigates away during a generation job, the job continues and the result is applied on return. `GenerationJobManager` holds in-progress job tokens in memory and persists them to local JSON for crash recovery.

---

## Document Map

| Document | Use When |
|---|---|
| `docs/ArkMask/README.md` | Understanding the product concept, on-device file structure, AI provider table, backend endpoint list, SWOT |
| `docs/ArkMask/user_personas.md` | Writing UI copy, calibrating onboarding depth, making UX trade-off decisions — Kofi (speed/volume), Amara (quality/narrative), Dev (agency/repeatability) |
| `docs/ArkMask/branding.md` | Implementing `AppTheme` — every color token, text style token, spacing value, shadow, radius, component variant, and accessibility target |
| `docs/ArkMask/features.md` | Implementing or modifying any feature (use Feature ID as the stable reference), writing acceptance criteria tests, resolving feature dependencies |
| `docs/ArkMask/roadmap.md` | Determining which features ship in which phase (Phase 1–5), understanding launch scope vs. post-launch |
| `docs/ArkMask/monetization.md` | Implementing credit deduction logic, tier feature gates, Free project limit, paywall checks, Stripe billing events, iOS reader app exception billing |
| `docs/ArkMask/risk_log.md` | Adding resilience: video job timeout handling (R-006), GCS URL expiry retry (R-008), FFmpeg version pinning (R-009), BYOK key security (R-004), character consistency warnings (R-005) |
| `docs/ArkMask/user_flows.md` | Implementing navigation flows, form validation, alternate/error paths, offline handling, credit exhaustion flow (Flow 6) |
| `docs/ArkMask/screens.md` | Building any screen — component tree, data requirements on mount, all UI states (loading, empty, error, offline, edge cases) |
| `docs/ArkMask/architecture.md` | Scaffolding backend components, understanding data flow patterns (sync text / async image / long-poll video), auth model, error handling table, deployment topology |
| `docs/ArkMask/schema.md` | Defining Pydantic models, SQLAlchemy columns, MDX frontmatter structures, API request/response contracts |

---

## Key Commands

### Flutter (`mobile/`)

> All Flutter commands go through FVM. Never call `flutter` or `dart` directly.
> The pinned version (`3.44.0`) is declared in `mobile/.fvm/fvm_config.json`.

```bash
# Pin Flutter version for this project (run once after cloning)
cd mobile && fvm use 3.44.0

# Install dependencies
fvm flutter pub get

# Generate JSON serialization code (json_serializable)
fvm dart run build_runner build --delete-conflicting-outputs

# Watch mode for code generation during development
fvm dart run build_runner watch --delete-conflicting-outputs

# Run on connected device or emulator
fvm flutter run

# Run all tests
fvm flutter test

# Run tests with coverage
fvm flutter test --coverage

# Static analysis
fvm flutter analyze

# Format code
fvm dart format lib/ test/

# Build Android release APK
fvm flutter build apk --release

# Build iOS release archive
fvm flutter build ipa --release
```

### FastAPI (`backend/`)

```bash
# Install dependencies (editable + dev extras)
pip install -e ".[dev]"

# Start full local dev stack (FastAPI + PostgreSQL + MinIO)
docker compose up

# Run FastAPI in watch mode (requires running postgres + minio)
uvicorn app.main:app --reload --port 8000

# Run tests
pytest

# Run tests with coverage
pytest --cov=app --cov-report=term-missing

# Lint
ruff check app/

# Format
ruff format app/

# Type check
mypy app/

# Create a new database migration
alembic revision --autogenerate -m "short description"

# Apply all pending migrations
alembic upgrade head

# Roll back one migration
alembic downgrade -1
```

### Docker (local dev)

```bash
# Start all services in background
docker compose up -d

# View FastAPI logs
docker compose logs -f fastapi

# Reset the database and MinIO volumes
docker compose down -v && docker compose up -d

# MinIO web console (bucket browser)
# URL: http://localhost:9001   user: minioadmin   pass: minioadmin
```

---

## Existing Backend Prototype (`solid-work/`)

`solid-work/` is a working prototype of the AI service layer. **Do not develop in it.** The production target is `backend/`. When building `backend/`, copy from `solid-work/` and adapt — do not rewrite from scratch.

### What to copy verbatim (then adapt)

| `solid-work/` path | Copy to `backend/` path | Notes |
|---|---|---|
| `apps/src/models/ai.py` | `app/models/schemas.py` (AI section) | All Pydantic models are production-ready: `Asset`, `AssetInput`, `AssetPrompt`, `SceneInput`, `Image`, `ImagePrompt`, `VideoPrompt`. Copy exactly. |
| `apps/src/models/media.py` | `app/models/schemas.py` (media section) | `Media` model — copy as-is. |
| `apps/src/services/ai.py` | `app/providers/gemini.py` + `app/providers/byteplus.py` | Split `AIServiceGoogle` into `app/providers/gemini.py`; split `AIServiceSeedream` into `app/providers/byteplus.py`. Refactor both to implement the `AIProvider` ABC in `app/providers/base.py`. |
| `apps/src/services/media_store.py` | `app/services/gcs_service.py` | Keep the `MediaStore` ABC and `MediaStoreNoSave` for tests. Rename `MediaStoreS3Temporary` → `GCSMediaStore`. **Fix TTL: update `EXPIRY_SECONDS` from `3600` to `7200`** (per architecture spec). |
| `apps/src/main.py` (endpoint logic only) | `app/routers/generation.py` | The 5 generation endpoints (`/assets`, `/image-prompt`, `/image`, `/video-prompt`, `/video`) already work. Lift the route handlers into `generation.py`; wire in auth middleware, credit checks, and async job dispatch (see "What still needs to be built" below). |
| `instructions/asset-list-generation.md` | `backend/instructions/asset-list-generation.md` | **Copy verbatim.** This is the system prompt loaded at runtime. Do not paraphrase or shorten it. |
| `instructions/image-prompt-generation.md` | `backend/instructions/image-prompt-generation.md` | **Copy verbatim.** Seedream-specific, 600-word limit, type-based layout rules must be preserved exactly. |
| `instructions/video-prompt-generation.md` | `backend/instructions/video-prompt-generation.md` | **Copy verbatim.** Subtitle suppression constraint lives here. Must not be removed or made optional. |
| `apps/tests/unit/test_ai_service.py` | `backend/tests/unit/test_ai_service.py` | Comprehensive unit tests with mocks. Update import paths and class names after the provider refactor above. |
| `apps/tests/integration/test_ai_service_integration.py` | `backend/tests/integration/test_ai_service_integration.py` | Auto-skipped when `GEMINI_API_KEY` not set. `@pytest.mark.slow` on video tests. Update imports. |

### What must be adapted (not blindly copied)

| Area | Change required |
|---|---|
| `config.py` | Add missing env vars: `database_url`, `firebase_project_id`, `stripe_webhook_secret`, `gcs_bucket`, `gcs_endpoint` (MinIO override for local dev). See `docs/ArkMask/architecture.md` for the full required surface. |
| `pyproject.toml` | Add missing deps: `sqlalchemy[asyncio]`, `alembic`, `firebase-admin`, `stripe`, `boto3`, `google-cloud-tasks`, `google-cloud-storage`, `asyncpg`, `bcrypt`. Update `requires-python` to `>=3.12` (prototype uses 3.14 locally but target is 3.12 on Cloud Run). |
| Video polling loop | `solid-work` uses `time.sleep` loop for Veo 2.0 / Seedance polling — this blocks the worker thread and will hit Cloud Run timeout on long jobs. Replace with Cloud Tasks: enqueue a task with the operation name/job ID; a separate worker route (`POST /internal/video-complete`) polls and sends FCM on completion. See `docs/ArkMask/architecture.md`. |
| Provider routing | `solid-work` only has `AIServiceGoogle` and `AIServiceSeedream`. Add `X-Provider-Type` header routing in `generation.py`: instantiate `GeminiProvider` or `BytePlusProvider` per request — never use the header value directly in a log or DB field. |
| Model identifiers | Prototype has correct model IDs — preserve them: Gemini TEXT=`gemini-2.5-flash`, IMAGE=`models/gemini-3.1-flash-image`, VIDEO=`veo-2.0-generate-001`; BytePlus TEXT=`doubao-1-5-pro-32k-250115`, IMAGE=`seedream-5-0-260128`, VIDEO=`dreamina-seedance-2-0-260128`. |

### What still needs to be built (no solid-work equivalent)

| Component | Target file | Reference doc |
|---|---|---|
| Auth layer | `app/routers/auth.py`, `app/services/auth_service.py` | `docs/ArkMask/architecture.md`, `docs/ArkMask/schema.md` |
| Platform API key issuance + bcrypt hashing | `app/services/auth_service.py` | `docs/ArkMask/architecture.md` (Auth section) |
| Credit check + atomic deduction | `app/services/billing_service.py` | `docs/ArkMask/monetization.md` |
| Stripe webhook handler | `app/routers/billing.py`, `app/services/billing_service.py` | `docs/ArkMask/monetization.md` |
| SQLAlchemy models + Alembic migrations | `app/models/db.py`, `migrations/` | `docs/ArkMask/schema.md` |
| FCM push on video completion | `app/services/fcm_service.py` | `docs/ArkMask/architecture.md` |
| Cloud Tasks enqueueing + worker route | `app/services/tasks_service.py`, `app/routers/jobs.py` | `docs/ArkMask/architecture.md` |
| Usage/credit query endpoint | `app/routers/usage.py` | `docs/ArkMask/schema.md`, `docs/ArkMask/monetization.md` |
