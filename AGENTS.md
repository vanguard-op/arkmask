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
| Content store (client) | Cloud Firestore (`cloud_firestore`) | `5.x` — offline persistence enabled; all MDX content lives here |
| Firebase core | `firebase_core` | `3.x` |
| Auth (client) | Firebase Auth (`firebase_auth`) | `5.x` |
| Push notifications | Firebase Cloud Messaging (`firebase_messaging`) | `15.x` |
| On-device job registry | Hive CE (`hive_ce`) | `2.x` — `job_registry` box; key=`job_id` |
| Secure storage | `flutter_secure_storage` | `9.x` — platform key, provider type, provider API key |
| HTTP client (Flutter) | `dio` | `5.x` |
| Video playback | `video_player` | `2.9.x` — for in-app GCS presigned URL streaming |
| Icons | `lucide_flutter` | `0.3.x` |
| Fonts | `google_fonts` | — |
| Backend API | FastAPI | `0.115.x` |
| Backend runtime | Python | `3.12` |
| Database | PostgreSQL | `15` (Cloud SQL prod; Docker local) |
| Auth (backend) | Firebase Admin SDK | `6.x` — token verify + Firestore writes (Admin bypasses rules) |
| Content store (backend) | Cloud Firestore (Admin SDK) | — — writes `prompt_body`, `storyboard_body`, `gcs_*_path` fields |
| Object storage | GCS (permanent, per-user) | GCS client lib `2.x` — no TTL/lifecycle delete; MinIO for local dev |
| Billing | Stripe | Stripe-hosted web page (iOS — reader app exception); Stripe native sheet (Android) |
| Async generation workers | Cloud Tasks + Cloud Run (separate service) | `google-cloud-tasks 2.x` — image, video, and merge jobs |
| HTTP client (FastAPI) | `httpx` | `0.27.x` |
| Local dev | Docker Compose | FastAPI + Workers + PostgreSQL + MinIO |

**No `ffmpeg_kit_flutter`.** FFmpeg runs in the cloud-side merge worker container. There is no on-device FFmpeg dependency.

**No local project filesystem.** All project text content lives in Firestore. All generated media lives in GCS. The device holds only credentials (Flutter Secure Storage), the Hive CE job registry, and Firestore's automatic offline cache.

**Fonts:** `DM Sans` and `JetBrains Mono` via `google_fonts` — do not declare them under `flutter.fonts` in `pubspec.yaml`.
**Icons:** All standard icons from `lucide_flutter`. Custom icons (ArkMask symbol) live in `assets/images/`.

---

## Project Structure

```
ark-mask/
├── mobile/                          # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart                 # MaterialApp, GoRouter, ThemeData, Firebase init
│   │   ├── core/
│   │   │   ├── theme/               # AppTheme: color tokens, text styles, spacing constants
│   │   │   ├── router/              # GoRouter definitions, route guards (auth + vault)
│   │   │   ├── auth/                # AuthService: Firebase Auth sign-in/out, session
│   │   │   ├── api/                 # ArkMaskApiClient (Dio), Dio interceptor (X-Platform-Key header)
│   │   │   ├── storage/             # SecureStorageService: platform key, provider type + key
│   │   │   ├── vault/               # VaultService: credential read/write; maps to secure storage keys
│   │   │   ├── jobs/                # JobRegistryService: Hive CE box wrapper, FCM routing, recovery polling
│   │   │   ├── http/                # Dio interceptors, error models, base URLs
│   │   │   ├── models/              # Shared DTOs (JobRegistryEntry HiveType, etc.)
│   │   │   └── utils/               # Extensions, date formatters, validators, size formatter
│   │   ├── features/
│   │   │   ├── auth/                # FEAT-001, FEAT-002, FEAT-031
│   │   │   ├── vault_setup/         # FEAT-003 — AI provider onboarding (vault = secure credential store)
│   │   │   ├── projects/            # FEAT-004, FEAT-005, FEAT-006, FEAT-007, FEAT-027, FEAT-028
│   │   │   ├── story/               # FEAT-008, FEAT-009 — story editor + asset extraction
│   │   │   ├── assets/              # FEAT-010, FEAT-011, FEAT-012, FEAT-013 — asset editor + image pipeline
│   │   │   ├── scene/               # FEAT-014, FEAT-015, FEAT-016 — storyboard editor + video generation
│   │   │   ├── scenes/              # FEAT-017 — job status tracking across scenes (scene list view)
│   │   │   ├── editor/              # FEAT-018, FEAT-019, FEAT-020, FEAT-021 — video timeline editor
│   │   │   ├── settings/            # FEAT-022, FEAT-023, FEAT-025 — provider settings, sign out, key mgmt
│   │   │   ├── usage/               # FEAT-024 — usage dashboard
│   │   │   ├── billing/             # Upgrade/paywall flow (credit exhaustion 402 → tier upgrade)
│   │   │   └── player/              # FEAT-026 — in-app video player (GCS presigned URL streaming)
│   │   └── shared/
│   │       ├── widgets/             # GenerationStepDots, FileBrowserRow, CreditPill, etc.
│   │       └── models/              # Shared Firestore document models, API response DTOs
│   ├── assets/
│   │   └── images/                  # ArkMask SVG symbol mark (splash, app icon)
│   ├── test/
│   │   ├── unit/
│   │   └── widget/
│   └── pubspec.yaml
│
├── backend/                         # FastAPI — AI proxy + job orchestration on GCP Cloud Run
│   ├── app/
│   │   ├── main.py                  # FastAPI app entrypoint + middleware
│   │   ├── routers/
│   │   │   ├── auth.py              # POST /register, POST /login, GET /me, GET /me/credits
│   │   │   ├── account.py           # GET /me, key regeneration
│   │   │   ├── generation.py        # POST /assets, /image-prompt, /image, /video-prompt, /video
│   │   │   ├── merge.py             # POST /merge
│   │   │   ├── jobs.py              # GET /job/{id}/status, GET /job/{id}/presigned-url
│   │   │   ├── media.py             # POST /media/presigned-url
│   │   │   ├── projects.py          # POST /projects, DELETE /projects/{slug}
│   │   │   ├── usage.py             # GET /usage
│   │   │   └── billing.py           # POST /webhook/stripe, POST /keys/regenerate
│   │   ├── providers/
│   │   │   ├── base.py              # AIProvider abstract base class
│   │   │   ├── gemini.py            # Google Gemini adapter (gemini-3.5-flash, gemini-3.1-flash-image, veo-3.1-generate-preview)
│   │   │   └── byteplus.py          # BytePlus Ark adapter (seed-2-0-lite-260228, seedream-5-0-lite, Seedance 2.0)
│   │   ├── services/
│   │   │   ├── auth_service.py      # Firebase Admin token verification, platform key issuance
│   │   │   ├── billing_service.py   # Atomic credit check + deduction; Stripe webhook handler
│   │   │   ├── gcs_service.py       # GCS / MinIO upload + presigned URL (1-hour TTL)
│   │   │   ├── fcm_service.py       # FCM push on all job completions (image, video, merge)
│   │   │   ├── firebase.py          # Firebase Admin SDK init; Firestore writes after sync generation
│   │   │   ├── media_store.py       # GCS / MinIO object store abstraction
│   │   │   └── tasks_service.py     # Cloud Tasks enqueue for /image, /video, /merge async jobs
│   │   ├── workers/                 # Cloud Tasks worker handlers (separate Cloud Run service)
│   │   │   ├── image_worker.py      # Image gen → GCS save → Firestore gcs_image_path → FCM
│   │   │   ├── video_worker.py      # Video gen (reads ref images from GCS) → GCS → Firestore → FCM
│   │   │   └── merge_worker.py      # FFmpeg merge → final.mp4 → GCS → Firestore gcs_final_path → FCM
│   │   ├── models/
│   │   │   ├── db.py                # SQLAlchemy ORM: users, projects, generation_jobs, usage_events, stripe_subscriptions
│   │   │   └── schemas.py           # Pydantic v2 request + response models
│   │   ├── database.py              # SQLAlchemy async engine + session factory
│   │   ├── dependencies.py          # FastAPI dependency injection (auth, db session)
│   │   └── config.py                # Pydantic Settings from environment variables
│   ├── migrations/                  # Alembic migrations
│   ├── tests/
│   ├── instructions/                # LLM system prompts (asset-list, image-prompt, video-prompt)
│   ├── Dockerfile
│   ├── docker-compose.yml           # FastAPI + Workers + PostgreSQL 15 + MinIO
│   ├── pyproject.toml
│   └── .env.example
│
├── solid-work/                      # Working prototype — read-only reference; do not develop here
│
└── docs/
    └── ArkMask/                     # Source of truth — see Document Map
```

Each `features/<name>/` directory follows this internal layout:
```
features/<name>/
├── screens/              # Screen widgets (one file per screen)
├── widgets/              # Feature-local reusable widgets
├── cubit/                # Cubit + state classes
│   ├── <name>_cubit.dart
│   └── <name>_state.dart
├── bloc/                 # Bloc + event + state (event-driven features only)
│   ├── <name>_bloc.dart
│   ├── <name>_event.dart
│   └── <name>_state.dart
└── models.dart           # Feature-local data models (if not in shared/models)
```

**Cubit vs Bloc guidance:**
- Use **Cubit** for straightforward UI state: form inputs, settings changes, project list loading, Firestore document read/display.
- Use **Bloc** when state changes are driven by discrete, named events needing logging, replay, or individual test cases — e.g., generation job lifecycle: `GenerationStarted`, `FirestoreListenerFired`, `FCMReceived`, `GenerationSucceeded`, `GenerationFailed`.
- Generation pipeline features (`assets/`, `scene/`, `editor/`) use **Bloc** — async worker jobs, FCM arrivals, and Firestore listener callbacks are discrete events.
- Auth, settings, project management, and vault_setup use **Cubit** — simpler state, fewer transitions.

---

## Data Architecture (Critical — Read Before Writing Any Feature Code)

ArkMask has three distinct persistence layers. Confusing them causes bugs.

| Layer | What It Holds | Who Writes | Who Reads |
|---|---|---|---|
| **Cloud Firestore** | All project text content: `story_content`, `prompt_body`, `storyboard_body`; GCS media path references: `gcs_image_path`, `gcs_video_path`, `gcs_final_path` | Flutter app (direct, via Firebase SDK); backend API (writes `prompt_body`/`storyboard_body` after sync generation); workers (write `gcs_*_path` after async generation) | Flutter app (real-time listeners); backend/workers (Admin SDK) |
| **Google Cloud Storage** | All generated media: `image.png`, `video.mp4`, `final.mp4` — permanent, per user, per project | Workers only (image worker, video worker, merge worker) | Flutter app via presigned URLs (1-hour TTL); workers (read ref images for video gen) |
| **Flutter Secure Storage** | Platform API key, AI provider type, AI provider API key | `VaultService` at onboarding and settings change | Every generation request (Dio interceptor) |
| **Hive CE `job_registry`** | In-flight job metadata: `job_id`, `project_id`, `type`, `scene_index`, `asset_name`, `status` | `JobRegistryService` on enqueue; updated on FCM arrival or status poll | FCM handler routes to correct UI; app launch recovery polling |
| **Cloud SQL (PostgreSQL)** | User accounts, project slugs, job state, credit balances, usage events, Stripe records | Backend API (job enqueue, credit deduction) and workers (job completion, credit deduction) | Backend on every request (key lookup, credit check) |
| **Firestore Offline Cache** | Cached copies of all Firestore documents the app has read | Managed automatically by Firestore SDK | Transparent to app — reads hit cache first; writes queued offline |

**Firestore document tree:**
```
users/{uid}/projects/{project_slug}
  display_name: string
  story_content: string
  gcs_final_path: string | null
  created_at, updated_at

users/{uid}/projects/{project_slug}/assets/{asset_slug}
  name: string          ← @ prefix = reference asset
  type: character | background | object
  description: string
  prompt_body: string | null    ← set by backend after /image-prompt
  gcs_image_path: string | null ← set by image worker
  updated_at

users/{uid}/projects/{project_slug}/scenes/{n}
  scene_number: integer
  storyboard_body: string | null  ← set by backend after /video-prompt
  gcs_video_path: string | null   ← set by video worker
  updated_at

users/{uid}/projects/{project_slug}/scenes/{n}/assets/{asset_slug}
  (same schema as global asset; gcs_image_path null for pass-through references)
```

**GCS folder structure:**
```
arkmask-media/
  {firebase-uid}/
    {project-slug}/
      assets/{asset-slug}/image.png          ← image worker
      scenes/{n}/assets/{asset-slug}/image.png
      scenes/{n}/video.mp4                   ← video worker
      final.mp4                              ← merge worker
```

---

## AI Provider Model Mapping

| Task | Endpoint | Gemini Model | BytePlus Ark Model | Credits |
|---|---|---|---|---|
| Asset extraction | `POST /assets` | `gemini-3.5-flash` | `seed-2-0-lite-260228` | 1 |
| Image prompt | `POST /image-prompt` | `gemini-3.5-flash` | `seed-2-0-lite-260228` | 1 |
| Storyboard | `POST /video-prompt` | `gemini-3.5-flash` (multimodal) | `seed-2-0-lite-260228` | 3 |
| Image generation | `POST /image` (async worker) | `gemini-3.1-flash-image` | `seedream-5-0-lite` | 5 |
| Video generation | `POST /video` (async worker) | `veo-3.1-generate-preview` | `Seedance 2.0` | 20 |

**Veo 3.1 constraints (R-018):** `generate_audio` and `enhance_prompt` params are NOT supported — omit them. Only one conditioning image accepted (first `ref_images` entry; extras silently ignored). Only PNG and JPEG conditioning images (sniff magic bytes; fall back to prompt-only for unsupported formats). API returns a GCS URI — download via `client.files.download(file=uri)`. Polling interval: 10 s.

---

## Coding Style & Conventions

### Flutter / Dart

- **State management:** Bloc / Cubit (`flutter_bloc 9.1.1`). No Riverpod, no Provider, no `setState` except for purely local widget animation state (`AnimationController`).
  - Cubits and Blocs are provided at the appropriate subtree level via `BlocProvider` or `MultiBlocProvider`.
  - Screens read state with `BlocBuilder`, react to one-off events with `BlocListener`, and do both with `BlocConsumer`.
  - State classes use `sealed` + subclasses pattern (`sealed class ProjectState {}`, `final class ProjectLoaded extends ProjectState {}`). Enables exhaustive pattern matching.
  - Every state class is immutable (`@immutable`). Use `copyWith` for partial state updates.
  - All async logic (API calls, Firestore reads/writes, Hive CE operations) runs inside the Cubit/Bloc — never in a widget.
- **Firestore access:** All Firestore reads and writes go through the `cloud_firestore` SDK. Never access Firestore directly in a widget or screen. Wrap Firestore calls in repository/service classes injected into Cubits/Blocs.
- **Real-time listeners:** Firestore `snapshots()` streams are subscribed to in the Bloc/Cubit. On each emission, emit a new state. Cancel stream subscriptions in `close()`.
- **Job registry:** All Hive CE `job_registry` reads and writes go through `JobRegistryService` in `core/jobs/`. Never open or access the Hive box directly in a feature file.
- **Navigation:** GoRouter only. Route name constants live in `core/router/routes.dart`. Route guards (auth check, vault/credentials check) are implemented as `redirect` callbacks on the router.
- **No business logic in widgets.** Widgets call Cubit methods or dispatch Bloc events. All Firestore I/O, API calls, and state transitions happen inside Cubits/Blocs or injected service classes.
- **FVM:** Always use `fvm flutter` and `fvm dart` — never bare `flutter` or `dart` commands. Pinned version: `3.44.0` (Dart `3.10`), declared in `mobile/.fvm/fvm_config.json`.
- **Naming:** `snake_case` for files; `PascalCase` for classes and enums; `camelCase` for variables and methods; `_prefixed` for private members.
- **Theme tokens — mandatory:**
  - Colors: `context.theme.colors.<tokenName>` — **never** raw hex strings in widget code.
  - Text styles: `context.theme.textStyles.<tokenName>` — **never** hardcode `fontSize` or `fontWeight`.
  - Spacing: `AppTheme.spacing.<tokenName>` constants — **never** hardcode pixel padding values.
- **API calls:** Always go through `ArkMaskApiClient`. Never instantiate `Dio` directly in a feature file.
- **Generation request headers:** Injected by the Dio interceptor in `core/api/`. Never add `X-Platform-Key`, `X-Provider-Type`, or `X-Provider-Key` manually in feature code.
- **All screen states are mandatory.** Every screen defined in `docs/ArkMask/screens.md` must implement every listed state (loading, empty, error, offline, submitting, edge cases). A screen stub showing only the loaded state is incomplete.
- **Docstrings:** `///` dartdoc on all public classes, public methods, and non-obvious private helpers. Describe what it does, not just what it is called.
- **Accessibility:** Every icon button must have a `Tooltip` or `semanticLabel`. All asset images set `semanticsLabel` from the asset's `description` Firestore field.

### FastAPI / Python

- **Type hints everywhere:** all function parameters and return types, including `-> None`.
- **`async def`** for all route handlers and any I/O-bound service method.
- **Pydantic v2** for all request bodies, response models, and settings.
- **Separation:** route handlers call service methods; service methods contain business logic; database operations stay in the service layer via SQLAlchemy async sessions.
- **Credit deduction atomicity:** `INSERT INTO usage_events` and `UPDATE users SET credit_balance` always execute in a single `async with session.begin()` transaction. A deduction committed without a corresponding usage event (or vice versa) is a data integrity bug.
- **Firestore writes from API (sync generation):** After `/image-prompt` returns a prompt, write `prompt_body` to the Firestore asset document using Firebase Admin SDK. After `/video-prompt` returns a storyboard, write `storyboard_body` to the scene document. These writes happen inline before the API response is returned.
- **Firestore writes from workers (async generation):** After an image worker saves `image.png` to GCS, write `gcs_image_path` to the Firestore asset document. After a video worker saves `video.mp4`, write `gcs_video_path` to the scene document. After merge worker saves `final.mp4`, write `gcs_final_path` to the project document. Workers use Firebase Admin SDK (bypasses security rules).
- **Provider key security:** `X-Provider-Key` header value must never appear in any log statement, exception message, Sentry capture, or database field. Log the provider *type*, not the key.
- **Platform key storage:** stored as a bcrypt hash in `users.platform_api_key`. The raw key is returned once in the registration response and is not recoverable from the backend.
- **GCS path authorization (R-022):** Validate `project_slug` against `projects` table (checking `user_id` matches authenticated key holder) before enqueueing any job. Workers derive GCS paths only from the validated job record in Cloud SQL — never from user-supplied paths directly.
- **Linting:** `ruff` for lint and format. `mypy` for type checking. Both must pass clean before a PR is merged.

---

## Behavior Rules

- **Never commit secrets.** `.env`, Firebase service account JSON (`backend/arkmask-firebase.json`), GCS keys are gitignored. Production secrets live in GCP Secret Manager.
- **Run tests before pushing.** `flutter test` (zero failures) and `pytest` (zero failures) are blocking gates.
- **Feature branches only.** Naming convention: `feat/<FEAT-ID>-short-description` (e.g., `feat/feat-016-generate-video`).
- **Credits deduct only on terminal success.** If a generation request results in a provider error (5xx), a network timeout, or a Cloud Tasks worker failure — zero credits are deducted. A refund event is written to `usage_events` if a deduction row was already committed. See `docs/ArkMask/monetization.md`.
- **Cloud-side FFmpeg only.** All video merging is done by the merge worker in the Cloud Run worker container. There is no on-device FFmpeg. Do not add `ffmpeg_kit_flutter` or any on-device media processing dependency.
- **No media stored on device.** Generated images, scene videos, and `final.mp4` are never saved to the device's local storage as part of the generation pipeline. The only exception is the explicit "Save to Camera Roll" action (FEAT-021), which downloads `final.mp4` to the device media library on user request.
- **GCS objects are permanent.** There is no lifecycle delete policy on the GCS bucket. Objects are deleted only when the user explicitly deletes a project — the backend then deletes all GCS objects under `{uid}/{project_slug}/`. Never add TTL or lifecycle rules to generated media.
- **GCS presigned URLs are ephemeral (1-hour TTL).** Request a fresh URL from `GET /job/{id}/presigned-url` or `POST /media/presigned-url` if a URL expires before the user opens the preview. Never treat GCS as durable storage accessible without a fresh URL.
- **Character reference images capped at 4 per scene.** Any code path calling `/video-prompt` or `/video` must count character-type assets with `gcs_image_path` set and show a warning dialog before sending if the count exceeds 4. See `docs/ArkMask/features.md` FEAT-014 and FEAT-016.
- **Subtitle suppression is mandatory in every storyboard.** The `/video-prompt` prompt template must always include the subtitle suppression instruction text. This is not optional or user-configurable.
- **Offline editing always works.** The story editor, asset description editor, and storyboard editor must remain fully editable when the device is offline. Firestore SDK queues writes locally and syncs on reconnect — no custom offline logic is required. Generation API calls require connectivity; surface a toast ("No internet connection") and block the request without clearing the editor.
- **No background batch generation.** Every generation step is user-triggered. No code may fire a generation request without an explicit user action.
- **Generation job state survives navigation and restarts.** When a job is enqueued, a `JobRegistryEntry` is written to the Hive CE `job_registry` box. When the app returns to the foreground, poll `GET /job/{id}/status` for every registry entry with status `pending` or `running`. FCM push is the primary completion signal; polling is the fallback. Clear the registry box on sign-out.
- **Firestore listeners are the primary UI update mechanism.** When a worker completes and writes `gcs_image_path` / `gcs_video_path` / `gcs_final_path` / `prompt_body` / `storyboard_body` to Firestore, the Flutter Firestore listener fires and updates the UI — no explicit polling or presigned URL fetch is needed for content refresh.
- **iOS billing — no native payment UI.** On iOS, tapping any upgrade or "Manage Subscription" action opens a Stripe-hosted web page in Safari (`launchUrl` with `LaunchMode.externalApplication`). The Stripe native payment sheet is rendered only on Android. See `docs/ArkMask/architecture.md`.
- **Project count gate is account-scoped.** When enforcing the Free tier 1-project limit, count only Firestore documents in `users/{uid}/projects/` for the current authenticated `uid`. See `docs/ArkMask/monetization.md` gate logic.
- **Firebase credentials file must be mounted (R-019).** `backend/arkmask-firebase.json` must exist and be mounted into every container that uses the Firebase Admin SDK. Without it, all `/login` and `/register` requests return 401 and all Firestore writes from the backend fail silently. Provision via GCP Secret Manager in production; bind-mount in local Docker Compose.
- **Immutable project slug.** The `slug` field (GCS folder name and Firestore document ID) is generated once at project creation and never changes, even if the user renames the project. Only `display_name` in the Firestore root document is mutable.

---

## Document Map

| Document | Use When |
|---|---|
| `docs/ArkMask/README.md` | Understanding the product concept, Firestore + GCS project model, AI provider table, backend endpoint list, SWOT |
| `docs/ArkMask/user_personas.md` | Writing UI copy, calibrating onboarding depth, making UX trade-off decisions — Kofi (speed/volume), Amara (quality/narrative), Dev (agency/repeatability) |
| `docs/ArkMask/branding.md` | Implementing `AppTheme` — every color token, text style token, spacing value, shadow, radius, component variant, and accessibility target |
| `docs/ArkMask/features.md` | Implementing or modifying any feature (use Feature ID as the stable reference), writing acceptance criteria tests, resolving feature dependencies |
| `docs/ArkMask/roadmap.md` | Determining which features ship in which phase (Phase 1–5), understanding launch scope vs. post-launch |
| `docs/ArkMask/monetization.md` | Implementing credit deduction logic, tier feature gates, Free 1-project limit, paywall checks, 402 handling, Stripe billing events, iOS reader app exception billing |
| `docs/ArkMask/risk_log.md` | Adding resilience: Veo 3.1 constraints (R-018), Firebase credentials mount (R-019), GCS path authorization (R-022), GCS storage cost (R-020), Firestore dependency (R-021), character consistency warning (R-005), GCS URL expiry retry (R-008) |
| `docs/ArkMask/user_flows.md` | Implementing navigation flows, form validation, alternate/error paths, offline handling, credit exhaustion flow (Flow 6) |
| `docs/ArkMask/screens.md` | Building any screen — component tree, data requirements on mount, all UI states (loading, empty, error, offline, edge cases) |
| `docs/ArkMask/architecture.md` | Understanding component responsibilities, data flow patterns (sync text / async image / async video / async merge), Firestore security rules, error handling table, deployment topology, local dev setup |
| `docs/ArkMask/schema.md` | Defining Pydantic models, SQLAlchemy columns, Firestore document field contracts, API request/response schemas, FCM payload shape, Hive CE job registry entry schema |

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

# Generate JSON serialization + Hive CE type adapters
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

# Start full local dev stack (FastAPI + Workers + PostgreSQL + MinIO)
docker compose up

# Run FastAPI in watch mode (requires running postgres + minio + firebase credentials)
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

# View worker logs
docker compose logs -f workers

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
| `apps/src/models/ai.py` | `app/models/schemas.py` (AI section) | Pydantic models are production-ready: `Asset`, `AssetInput`, `AssetPrompt`, `SceneInput`, `Image`, `ImagePrompt`, `VideoPrompt`. Copy exactly. |
| `apps/src/models/media.py` | `app/models/schemas.py` (media section) | `Media` model — copy as-is. |
| `apps/src/services/ai.py` | `app/providers/gemini.py` + `app/providers/byteplus.py` | Split `AIServiceGoogle` → `app/providers/gemini.py`; split `AIServiceSeedream` → `app/providers/byteplus.py`. Refactor both to implement the `AIProvider` ABC in `app/providers/base.py`. |
| `apps/src/services/media_store.py` | `app/services/media_store.py` | Keep the `MediaStore` ABC and `MediaStoreNoSave` for tests. Rename `MediaStoreS3Temporary` → `GCSMediaStore`. **GCS objects are now permanent — no TTL**. Presigned URL TTL = `3600` seconds (1 hour). |
| `apps/src/main.py` (endpoint logic) | `app/routers/generation.py` | The 5 generation endpoints (`/assets`, `/image-prompt`, `/image`, `/video-prompt`, `/video`) already work. Lift route handlers into `generation.py`; wire in auth middleware, credit checks, async job dispatch, and Firestore writes (see below). |
| `instructions/asset-list-generation.md` | `backend/instructions/asset-list-generation.md` | **Copy verbatim.** System prompt loaded at runtime. Do not paraphrase or shorten. |
| `instructions/image-prompt-generation.md` | `backend/instructions/image-prompt-generation.md` | **Copy verbatim.** Seedream-specific, 600-word limit, type-based layout rules must be preserved exactly. |
| `instructions/video-prompt-generation.md` | `backend/instructions/video-prompt-generation.md` | **Copy verbatim.** Subtitle suppression constraint lives here. Must not be removed or made optional. |
| `apps/tests/unit/test_ai_service.py` | `backend/tests/unit/test_ai_service.py` | Comprehensive unit tests with mocks. Update import paths and class names after provider refactor. |
| `apps/tests/integration/test_ai_service_integration.py` | `backend/tests/integration/test_ai_service_integration.py` | Auto-skipped when `GEMINI_API_KEY` not set. `@pytest.mark.slow` on video tests. Update imports. |

### What must be adapted (not blindly copied)

| Area | Change required |
|---|---|
| `config.py` | Add: `database_url`, `firebase_project_id`, `stripe_webhook_secret`, `gcs_bucket`, `gcs_endpoint` (MinIO override), `firebase_credentials_path`. See `docs/ArkMask/architecture.md` Local Development Setup. |
| `pyproject.toml` | Add: `sqlalchemy[asyncio]`, `alembic`, `firebase-admin`, `stripe`, `google-cloud-tasks`, `google-cloud-storage`, `asyncpg`, `bcrypt`. `requires-python = ">=3.12"`. |
| Image generation (was sync) | `solid-work` runs image generation inline and returns bytes. **Production target: image generation is async.** `/image` enqueues a Cloud Tasks job and returns `job_id` immediately. The image worker calls the provider, saves `image.png` to GCS, writes `gcs_image_path` to Firestore, updates job in Cloud SQL, deducts credits, sends FCM. |
| Video generation (was sync loop) | `solid-work` uses a `time.sleep` polling loop — blocks the worker thread. Replace with Cloud Tasks: enqueue a job with the operation name/job ID; the video worker polls the provider's operation endpoint, saves `video.mp4` to GCS, writes `gcs_video_path` to Firestore, deducts credits, sends FCM. |
| Firestore writes (sync generation) | After `/image-prompt` succeeds, write `prompt_body` to `users/{uid}/projects/{slug}/assets/{asset_slug}` via Firebase Admin SDK. After `/video-prompt` succeeds, write `storyboard_body` to the scene document. This is new — `solid-work` does not write to Firestore. |
| Provider routing | Add `X-Provider-Type` header routing: instantiate `GeminiProvider` or `BytePlusProvider` per request. **Updated model IDs:** Gemini TEXT=`gemini-3.5-flash`, IMAGE=`gemini-3.1-flash-image`, VIDEO=`veo-3.1-generate-preview`; BytePlus TEXT=`seed-2-0-lite-260228`, IMAGE=`seedream-5-0-lite`, VIDEO=`Seedance 2.0`. |

### What still needs to be built (no solid-work equivalent)

| Component | Target file | Reference doc |
|---|---|---|
| Auth layer | `app/routers/auth.py`, `app/services/auth_service.py` | `docs/ArkMask/architecture.md`, `docs/ArkMask/schema.md` |
| Platform API key issuance + bcrypt hashing | `app/services/auth_service.py` | `docs/ArkMask/architecture.md` (Auth section) |
| Credit check + atomic deduction | `app/services/billing_service.py` | `docs/ArkMask/monetization.md` |
| Stripe webhook handler | `app/routers/billing.py`, `app/services/billing_service.py` | `docs/ArkMask/monetization.md` |
| SQLAlchemy models + Alembic migrations | `app/models/db.py`, `migrations/` | `docs/ArkMask/schema.md` |
| FCM push on all job completions (image, video, merge) | `app/services/fcm_service.py` | `docs/ArkMask/architecture.md` |
| Cloud Tasks enqueueing for image + video + merge | `app/services/tasks_service.py` | `docs/ArkMask/architecture.md` |
| Cloud merge endpoint + merge worker | `app/routers/merge.py`, `app/workers/merge_worker.py` | `docs/ArkMask/schema.md` (POST /merge), `docs/ArkMask/architecture.md` (Merge Worker) |
| Path-based presigned URL | `app/routers/media.py` | `docs/ArkMask/schema.md` (POST /media/presigned-url) |
| Project create + delete endpoints | `app/routers/projects.py` | `docs/ArkMask/features.md` FEAT-004, FEAT-007 |
| Usage/credit query endpoint | `app/routers/usage.py` | `docs/ArkMask/schema.md`, `docs/ArkMask/monetization.md` |
| GCS path authorization check | `app/services/auth_service.py` or `app/dependencies.py` | `docs/ArkMask/risk_log.md` R-022 |
