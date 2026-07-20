import 'package:dio/dio.dart';

import '../models/models.dart';
import '../storage/secure_storage_service.dart';
import 'api_error.dart';
import 'credential_interceptor.dart';

/// HTTP client for the ArkMask Cloud Run API.
///
/// All feature code calls this client — never instantiates [Dio] directly.
/// Generation headers (`X-Platform-Key`, `X-Provider-Type`, `X-Provider-Key`)
/// are injected automatically by [CredentialInterceptor].
///
/// Base URL is configured per environment:
/// - Local dev (Android emulator): `http://10.0.2.2:8000` (host machine loopback)
/// - Local dev (physical device / iOS sim): `http://localhost:8000`
/// - Production: Cloud Run URL (set via env / build config)
/// Base URL injected at build time via --dart-define-from-file=.env.json.
/// Defaults to the Android emulator loopback address for local development.
const _kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

class ArkMaskApiClient {
  ArkMaskApiClient({
    required SecureStorageService storage,
    String baseUrl = _kApiBaseUrl,
  }) : _dio = _buildDio(baseUrl: baseUrl, storage: storage);

  final Dio _dio;

  static Dio _buildDio({
    required String baseUrl,
    required SecureStorageService storage,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 300), // video generation can take minutes
        headers: {'Content-Type': 'application/json'},
      ),
    )
      ..interceptors.add(CredentialInterceptor(storage: storage))
      ..interceptors.add(LogInterceptor(
        request: true,
        requestHeader: false, // never log headers (contains provider key)
        requestBody: false,
        responseHeader: false,
        responseBody: false,
        error: true,
      ));
    return dio;
  }

  // ── Auth endpoints ─────────────────────────────────────────────────────────

  /// POST /register — create a new user account.
  ///
  /// Returns the platform API key issued by the backend.
  /// Throws [ApiConflict] if the email is already registered.
  Future<String> register({
    required String email,
    required String idToken,
  }) async {
    final response = await _execute(
      () => _dio.post(
        '/register',
        data: {'email': email},
        options: Options(headers: {'Authorization': 'Bearer $idToken'}),
      ),
    );
    final body = response.data as Map<String, dynamic>;
    return body['platform_api_key'] as String;
  }

  /// POST /login — authenticate and fetch the platform API key.
  Future<String> login({required String idToken}) async {
    final response = await _execute(
      () => _dio.post(
        '/login',
        options: Options(headers: {'Authorization': 'Bearer $idToken'}),
      ),
    );
    final body = response.data as Map<String, dynamic>;
    return body['platform_api_key'] as String;
  }

  /// GET /me/credits — fetch the current user's credit balance and tier.
  ///
  /// Returns a map with `credits` (int) and `tier` (String).
  ///
  /// Not currently called anywhere in the app — [ProjectsCubit] and
  /// [SettingsCubit] both read `credit_balance`/`tier` from a live Firestore
  /// listener on `users/{uid}/profile/data` instead (a one-shot REST fetch
  /// here meant the credit pill never reflected generation spend or a
  /// Stripe webhook's tier update without a restart). Kept as a thin wrapper
  /// around the backend endpoint in case a one-shot fetch is ever needed
  /// again (e.g. outside a widget tree).
  Future<Map<String, dynamic>> getCredits() async {
    final response = await _execute(() => _dio.get('/me/credits'));
    return (response.data as Map<String, dynamic>);
  }

  // ── Project endpoints ──────────────────────────────────────────────────────

  /// POST /projects — create a new project record in Firestore + Cloud SQL.
  ///
  /// [displayName] is the user-facing project name (≤ 60 characters, validated
  /// server-side). [generationSettings] sets the initial art style and subtitle
  /// preference; defaults are applied by the backend if omitted.
  ///
  /// Returns a map with `slug` and `display_name`.
  Future<Map<String, dynamic>> createProject({
    required String displayName,
    GenerationSettings? generationSettings,
  }) async {
    final body = <String, dynamic>{'display_name': displayName};
    if (generationSettings != null) {
      body['generation_settings'] = generationSettings.toFirestore();
    }
    final response = await _execute(
      () => _dio.post('/projects', data: body),
    );
    return (response.data as Map<String, dynamic>);
  }

  /// PATCH /projects/{slug}/settings — update generation settings for a project.
  ///
  /// The backend stores these in the Firestore project document and reads them
  /// when `/image-prompt` and `/video-prompt` are called. Mobile request bodies
  /// for generation endpoints are unchanged.
  Future<void> updateProjectSettings(
    String slug,
    GenerationSettings settings,
  ) async {
    await _execute(
      () => _dio.patch(
        '/projects/$slug/settings',
        data: settings.toFirestore(),
      ),
    );
  }

  /// DELETE /projects/{slug} — permanently delete a project.
  ///
  /// The backend cascades: Firestore subcollections, GCS objects under
  /// `{uid}/{slug}/`, and Cloud SQL row are all removed.
  Future<void> deleteProject(String slug) async {
    await _execute(() => _dio.delete('/projects/$slug'));
  }

  /// PATCH /projects/{slug} — update the mutable display name.
  ///
  /// Writes `display_name` and `updated_at` to the Firestore project root
  /// document. The immutable slug is unaffected.
  Future<void> updateProjectDisplayName(String slug, String newDisplayName) async {
    await _execute(
      () => _dio.patch('/projects/$slug', data: {'display_name': newDisplayName}),
    );
  }

  // ── Generation endpoints ──────────────────────────────────────────────────

  /// POST /assets — enqueue asset extraction from a story (async job).
  ///
  /// The backend parses [storyContent] and, once the job completes, writes
  /// the extracted asset documents directly to Firestore under
  /// `users/{uid}/projects/{slug}/assets/` and
  /// `users/{uid}/projects/{slug}/scenes/{n}/assets/` — the caller no longer
  /// creates these documents itself (that used to happen client-side after a
  /// synchronous response; moved server-side so a slow AI provider response
  /// can't hit the app's HTTP timeout or Cloud Run's own request timeout).
  ///
  /// Returns the `job_id` immediately. The caller should register it with
  /// [JobRegistryService] and track completion via the job document's status
  /// field (`users/{uid}/jobs/{job_id}`) — there's no single Firestore field
  /// to watch since extraction creates multiple new documents.
  ///
  /// [projectSlug] is included so the backend can log the extraction event for
  /// credit accounting.
  Future<String> extractAssets({
    required String projectSlug,
    required String storyContent,
  }) async {
    final response = await _execute(
      () => _dio.post('/assets', data: {
        'project_slug': projectSlug,
        'story': storyContent,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /refine-story — enqueue a full-story AI rewrite (FEAT-038).
  ///
  /// Identifies the project only — `story_content`, `generation_settings`,
  /// and any already-extracted character asset names are all resolved
  /// server-side from Firestore (see `backend/app/routers/generation.py`).
  /// The worker writes its result to the project document's
  /// `refined_story_preview` field, never to `story_content` directly. The
  /// app's Firestore listener on the project document fires when that field
  /// is set — see [StoryCubit] and its Refine Ready banner handling.
  Future<String> refineStory({required String projectSlug}) async {
    final response = await _execute(
      () => _dio.post('/refine-story', data: {
        'project_slug': projectSlug,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /image-prompt — enqueue image prompt generation for a single asset
  /// (async job).
  ///
  /// The worker generates the prompt text and writes it directly to the
  /// `prompt_body` field of the Firestore asset document at
  /// `users/{uid}/projects/{projectSlug}/{assetFirestorePath}`.
  ///
  /// The app's Firestore real-time listener on the asset document fires when
  /// the write completes — no response parsing is needed on the client.
  ///
  /// Returns the `job_id` immediately. The caller should register it with
  /// [JobRegistryService]; the loading spinner is cleared when the Firestore
  /// listener detects the `prompt_body` update (see AssetEditorCubit), not
  /// when this call returns.
  ///
  /// [assetFirestorePath] is the path segment below the project root:
  /// - Global asset  → `"assets/{assetId}"`
  /// - Scene-local   → `"scenes/{sceneId}/assets/{assetId}"`
  Future<String> generateImagePrompt({
    required String projectSlug,
    required String assetFirestorePath,
    required String name,
    required String type,
    required String description,
  }) async {
    final response = await _execute(
      () => _dio.post('/image-prompt', data: {
        'project_slug': projectSlug,
        'asset_path': assetFirestorePath,
        'name': name,
        'type': type,
        'description': description,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /image — enqueue an async image generation job for an asset.
  ///
  /// The image worker reads the asset's `prompt_body` from Firestore, generates
  /// the image, saves it to GCS at `{uid}/{projectSlug}/{assetFirestorePath}/image.png`,
  /// and writes the GCS path to the asset's `gcs_image_path` Firestore field.
  ///
  /// [conditioningGcsPath] is the GCS path of the referenced asset's image for
  /// variant assets (name starts with '@' and has a non-empty description). The
  /// worker uses it as a visual conditioning input.
  ///
  /// Returns the `job_id` immediately. The caller writes a [JobRegistryEntry]
  /// to the local Hive CE box and waits for either the Firestore listener or an
  /// FCM push notification to resolve the job.
  Future<String> generateImage({
    required String projectSlug,
    required String assetFirestorePath,
    String? conditioningGcsPath,
  }) async {
    final response = await _execute(
      () => _dio.post('/image', data: {
        'project_slug': projectSlug,
        'asset_path': assetFirestorePath,
        'conditioning_gcs_path': conditioningGcsPath,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /video-prompt — enqueue storyboard generation for a scene (async job).
  ///
  /// Identifies the scene only — the backend resolves the scene text, the
  /// ordered reference asset list (name + generated prompt text), and the
  /// project's art style / subtitle settings server-side from Firestore
  /// (see `backend/app/services/scene_assets.py`). The worker generates the
  /// storyboard and writes it directly to the `storyboard_body` field of the
  /// Firestore scene document.
  ///
  /// The app's Firestore real-time listener on the scene document fires when
  /// the write completes — no response parsing is needed on the client.
  ///
  /// Returns the `job_id` immediately. The caller should register it with
  /// [JobsCubit]; the loading spinner is cleared when the Firestore listener
  /// detects the `storyboard_body` update (see SceneCubit), not when this
  /// call returns.
  ///
  /// Per FEAT-014: subtitle suppression instructions and character count
  /// enforcement (≤ 4 character refs) are applied server-side.
  Future<String> generateVideoPrompt({
    required String projectSlug,
    required int sceneIndex,
  }) async {
    final response = await _execute(
      () => _dio.post('/video-prompt', data: {
        'project_slug': projectSlug,
        'scene_index': sceneIndex,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /video — enqueue an async scene video generation job.
  ///
  /// Identifies the scene only — the video worker reads the scene's
  /// `storyboard_body` and resolves the ordered reference asset images
  /// directly from Firestore/GCS server-side (see
  /// `backend/app/services/scene_assets.py`), generates a video clip with
  /// audio, saves it to GCS at
  /// `{uid}/{projectSlug}/scenes/{sceneIndex}/video.mp4`, and writes the GCS
  /// path to the scene's `gcs_video_path` Firestore field.
  ///
  /// Returns the `job_id` immediately. The caller writes a [JobRegistryEntry]
  /// and waits for the Firestore `gcs_video_path` update or FCM push.
  Future<String> generateVideo({
    required String projectSlug,
    required int sceneIndex,
  }) async {
    final response = await _execute(
      () => _dio.post('/video', data: {
        'project_slug': projectSlug,
        'scene_index': sceneIndex,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// POST /merge — enqueue a cloud video merge job (FEAT-021).
  ///
  /// Sends the ordered list of scenes with per-clip trim points and transition
  /// types. The merge worker reads all scene `video.mp4` files directly from
  /// GCS, runs FFmpeg server-side (no on-device processing), and saves
  /// `final.mp4` to GCS at `users/{uid}/{projectSlug}/final.mp4`.
  ///
  /// On completion the worker sets `gcs_final_path` on the Firestore project
  /// root document; the Flutter Firestore listener fires and the editor enables
  /// the "Download to Camera Roll" button. A FCM push notification also fires.
  ///
  /// [scenes] is the ordered list of scene entries — one per scene that should
  /// be included in the export (scenes without `gcs_video_path` are excluded by
  /// the caller). Each entry carries:
  ///   - `scene_index` (int) — the scene number / Firestore doc ID
  ///   - `trim_in` (double) — start offset in seconds
  ///   - `trim_out` (double) — end offset in seconds
  ///   - `transition_to_next` (String) — the gap transition to the next clip
  ///     (`"hard_cut"` | `"fade_black"` | `"dissolve"`); ignored for the last
  ///     scene entry.
  ///
  /// Returns the `job_id` immediately. The caller writes a [JobRegistryEntry]
  /// with `type: "merge"` and waits for the Firestore `gcs_final_path` update.
  Future<String> mergeClips({
    required String projectSlug,
    required List<Map<String, dynamic>> scenes,
  }) async {
    final response = await _execute(
      () => _dio.post('/merge', data: {
        'project_slug': projectSlug,
        'scenes': scenes,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// GET /job/{jobId}/status — poll for any generation job's status.
  ///
  /// Used on foreground return to recover job state for any entry in the
  /// local Hive CE registry that is still marked `pending` or `running`.
  /// The response fields mirror those of the former `/video/{id}/status`.
  Future<Map<String, dynamic>> getJobStatus({required String jobId}) async {
    final response = await _execute(
      () => _dio.get('/job/$jobId/status'),
    );
    return (response.data as Map<String, dynamic>);
  }

  /// POST /media/presigned-url — obtain a fresh presigned URL for a GCS object.
  ///
  /// GCS presigned URLs expire after 2 hours. Call this before streaming any
  /// media that was obtained from a Firestore `gcs_*_path` field.
  ///
  /// [gcsPath] is the raw GCS object path (e.g. the value of `gcs_image_path`
  /// or `gcs_video_path` from Firestore). The backend verifies the caller owns
  /// the object before issuing the URL.
  Future<String> getPresignedUrl({required String gcsPath}) async {
    final response = await _execute(
      () => _dio.post('/media/presigned-url', data: {'gcs_path': gcsPath}),
    );
    return (response.data as Map<String, dynamic>)['url'] as String;
  }

  // ── Manual asset management endpoints (FEAT-033–037) ─────────────────────

  /// POST /media/upload-url — obtain a presigned PUT URL for a manual asset
  /// image upload (FEAT-034).
  ///
  /// [objectPath] is the relative object key under `{uid}/{projectSlug}/`,
  /// e.g. `assets/{slug}/image.png` (style_adapted off) or
  /// `assets/{slug}/original.<ext>` (style_adapted on). Returns
  /// `(uploadUrl, gcsPath)` — the caller performs an HTTP PUT of the raw
  /// file bytes to [uploadUrl] with the same [contentType], then uses
  /// `gcsPath` as `gcs_image_path`, `original_upload_gcs_path`, or
  /// `conditioning_gcs_path` as appropriate.
  Future<(String uploadUrl, String gcsPath)> getUploadUrl({
    required String projectSlug,
    required String objectPath,
    required String contentType,
  }) async {
    final response = await _execute(
      () => _dio.post('/media/upload-url', data: {
        'project_slug': projectSlug,
        'object_path': objectPath,
        'content_type': contentType,
      }),
    );
    final body = response.data as Map<String, dynamic>;
    return (body['upload_url'] as String, body['gcs_path'] as String);
  }

  /// Uploads raw [bytes] directly to a GCS presigned PUT URL obtained from
  /// [getUploadUrl]. Uses a bare Dio PUT (not through [_execute]) since the
  /// presigned URL is not an ArkMask API endpoint and must not receive the
  /// `X-Platform-Key` / provider headers injected by [CredentialInterceptor].
  Future<void> uploadToPresignedUrl({
    required String uploadUrl,
    required List<int> bytes,
    required String contentType,
  }) async {
    try {
      await Dio().put<void>(
        uploadUrl,
        data: bytes,
        options: Options(
          headers: {'Content-Type': contentType},
          contentType: contentType,
        ),
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  /// POST /image-describe — generate a text description of an uploaded
  /// image (FEAT-034). Synchronous, single vision-model call — 1 credit.
  ///
  /// [gcsPath] is the value returned by [getUploadUrl] once the upload has
  /// completed. [type] is the asset type (`character` | `background` |
  /// `object`).
  Future<String> describeImage({
    required String gcsPath,
    required String type,
  }) async {
    final response = await _execute(
      () => _dio.post('/image-describe', data: {
        'gcs_path': gcsPath,
        'type': type,
      }),
    );
    return (response.data as Map<String, dynamic>)['description'] as String;
  }

  /// DELETE /assets — hard-delete an asset (FEAT-037).
  ///
  /// [assetFirestorePath] is the relative asset path, e.g. `assets/palace`
  /// or `scenes/2/assets/shade`. When [force] is false (default) and other
  /// assets reference this one via the `@` naming convention, throws
  /// [AssetDeleteBlockedException] listing the dependents instead of
  /// deleting — the caller should show them to the user and offer a
  /// force-delete retry.
  Future<void> deleteAsset({
    required String projectSlug,
    required String assetFirestorePath,
    bool force = false,
  }) async {
    try {
      await _dio.delete(
        '/assets',
        data: {
          'project_slug': projectSlug,
          'asset_path': assetFirestorePath,
          'force': force,
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final body = e.response?.data;
        final dependents = (body is Map ? body['dependents'] as List<dynamic>? : null) ?? [];
        throw AssetDeleteBlockedException(
          dependents: dependents
              .map((d) => AssetDependent(
                    assetPath: (d as Map)['asset_path'] as String,
                    name: d['name'] as String,
                  ))
              .toList(),
        );
      }
      throw _mapDioError(e);
    }
  }

  /// Fetches the GCS storage summary for a project (FEAT-027).
  ///
  /// Calls `GET /projects/{slug}/storage`. Returns a map with keys:
  /// `total_bytes`, `images_bytes`, `videos_bytes`, `export_bytes`.
  ///
  /// Throws [ApiError] on failure. The caller should treat failures as
  /// non-blocking and fall back to a zero summary.
  Future<Map<String, dynamic>> getProjectStorageSummary(String slug) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/projects/${Uri.encodeComponent(slug)}/storage',
    );
    return response.data ?? {};
  }

  /// GET /usage — fetch generation event history for the Usage Dashboard.
  Future<List<dynamic>> getUsageEvents() async {
    final response = await _execute(() => _dio.get('/usage'));
    return (response.data as Map<String, dynamic>)['events'] as List<dynamic>;
  }

  /// POST /keys/regenerate — regenerate the platform API key.
  Future<String> regenerateApiKey() async {
    final response = await _execute(() => _dio.post('/keys/regenerate'));
    return (response.data as Map<String, dynamic>)['platform_api_key'] as String;
  }

  // ── Billing endpoints ──────────────────────────────────────────────────────

  /// POST /billing/checkout — create a Stripe Checkout Session for [priceId].
  ///
  /// Returns the hosted Stripe Checkout URL. The caller opens it in the system
  /// browser via `url_launcher`. On completion Stripe fires a webhook that
  /// updates the user's tier and credits automatically.
  Future<String> createCheckoutSession({required String priceId}) async {
    final response = await _execute(
      () => _dio.post('/billing/checkout', data: {'price_id': priceId}),
    );
    return (response.data as Map<String, dynamic>)['url'] as String;
  }

  /// POST /billing/portal — create a Stripe Customer Portal session URL.
  ///
  /// Returns the hosted portal URL where the user can manage or cancel their
  /// subscription. Opens in the system browser.
  ///
  /// Throws [ApiInsufficientCredits] (402) if the user has no active subscription.
  Future<String> createPortalSession() async {
    final response = await _execute(() => _dio.post('/billing/portal'));
    return (response.data as Map<String, dynamic>)['url'] as String;
  }

  // ── File download ──────────────────────────────────────────────────────────

  /// Downloads a file from an arbitrary URL (e.g. GCS presigned URL) and
  /// returns the raw bytes.
  ///
  /// Used to save generated images and videos to the device filesystem after
  /// receiving a presigned GCS URL from `/image` or `/video/:id/status`.
  Future<List<int>> downloadBytes(String url) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      return response.data ?? [];
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw ApiUnknownError(message: e.toString());
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Executes a Dio request, mapping [DioException] to typed [ApiError].
  Future<Response<dynamic>> _execute(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw ApiUnknownError(message: e.toString());
    }
  }

  ApiError _mapDioError(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return ApiNetworkError(message: 'No internet connection. Check your connection and try again.');
    }

    final status = e.response?.statusCode;
    final body = e.response?.data;
    final message = (body is Map ? body['detail']?.toString() : null) ??
        e.message ??
        'An unexpected error occurred.';

    return switch (status) {
      401 => ApiUnauthorized(),
      402 => ApiInsufficientCredits(balance: body is Map ? body['credit_balance'] as int? : null),
      // 400 from a generation endpoint = provider rejected the content (safety
      // filter, invalid parameter, etc.).  Surface the provider's message so
      // the user can act on it (e.g. rephrase the prompt).
      400 => ApiValidationError(detail: message),
      409 => ApiConflict(message: message),
      422 => ApiValidationError(detail: message),
      _ => ApiServerError(statusCode: status ?? 500, message: message),
    };
  }
}
