import 'package:dio/dio.dart';

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
  Future<Map<String, dynamic>> getCredits() async {
    final response = await _execute(() => _dio.get('/me/credits'));
    return (response.data as Map<String, dynamic>);
  }

  // ── Generation endpoints (Phase 2+, declared for completeness) ─────────────

  /// POST /assets — extract characters, backgrounds, objects from story text.
  Future<Map<String, dynamic>> extractAssets({required String storyContent}) async {
    final response = await _execute(
      () => _dio.post('/assets', data: {'story': storyContent}),
    );
    return (response.data as Map<String, dynamic>);
  }

  /// POST /image-prompt — generate an image prompt for an asset.
  Future<String> generateImagePrompt({
    required String name,
    required String type,
    required String description,
  }) async {
    final response = await _execute(
      () => _dio.post('/image-prompt', data: {
        'name': name,
        'type': type,
        'description': description,
      }),
    );
    return (response.data as Map<String, dynamic>)['prompt'] as String;
  }

  /// POST /image — generate a reference image for an asset.
  ///
  /// Returns the GCS presigned URL (2-hour TTL) for downloading the image.
  Future<String> generateImage({required String promptBody}) async {
    final formData = FormData.fromMap({'prompt': promptBody});
    final response = await _execute(
      () => _dio.post('/image', data: formData),
    );
    return (response.data as Map<String, dynamic>)['url'] as String;
  }

  /// POST /video-prompt — generate a scene storyboard prompt.
  ///
  /// [scene] is the scene's story text. [assets] is a list of maps with
  /// `name` and `prompt` keys (the asset's name and its generated image prompt
  /// body from prompt.mdx). No images are sent — the AI uses the prompt text
  /// as the visual reference.
  Future<String> generateVideoPrompt({
    required String scene,
    required List<Map<String, String>> assets,
  }) async {
    final response = await _execute(
      () => _dio.post('/video-prompt', data: {
        'scene': scene,
        'assets': assets,
      }),
    );
    return (response.data as Map<String, dynamic>)['storyboard'] as String;
  }

  /// POST /video — enqueue a scene video generation job.
  ///
  /// [prompt] is the storyboard text from `ark.mdx`. [refImages] is a list
  /// of maps with `data` (base64-encoded PNG bytes) and `mime_type` keys —
  /// one entry per scene asset that has a generated image on disk.
  ///
  /// Returns the `job_id` for polling via [getVideoJobStatus].
  Future<String> generateVideo({
    required String prompt,
    required List<Map<String, String>> refImages,
  }) async {
    final response = await _execute(
      () => _dio.post('/video', data: {
        'prompt': prompt,
        'ref_images': refImages,
      }),
    );
    return (response.data as Map<String, dynamic>)['job_id'] as String;
  }

  /// GET /video/{jobId}/status — poll for video generation job completion.
  Future<Map<String, dynamic>> getVideoJobStatus({required String jobId}) async {
    final response = await _execute(
      () => _dio.get('/video/$jobId/status'),
    );
    return (response.data as Map<String, dynamic>);
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
