import 'package:dio/dio.dart';

import '../storage/secure_storage_service.dart';

/// Dio interceptor that injects ArkMask generation headers on every request.
///
/// Headers injected:
/// - `X-Platform-Key` — the platform API key that identifies the user
///   for billing and credit deduction.
/// - `X-Provider-Type` — `"gemini"` or `"bytedance"`, routing the backend
///   to the correct AI provider.
/// - `X-Provider-Key` — the user-supplied AI provider API key (BYOK).
///   **Never log this value.** It is never stored server-side.
///
/// Auth endpoints (`/register`, `/login`) do not require generation headers
/// and skip this interceptor via [_isAuthEndpoint].
class CredentialInterceptor extends Interceptor {
  CredentialInterceptor({required this.storage});

  final SecureStorageService storage;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_isAuthEndpoint(options.path)) {
      return handler.next(options);
    }

    final platformKey = await storage.readPlatformApiKey();
    final providerType = await storage.readProviderType();
    final providerKey = await storage.readProviderApiKey();

    // Guard: if the platform key is absent the request would reach the backend
    // without X-Platform-Key, causing a confusing 422 instead of a meaningful
    // 401. Reject early so the caller receives ApiUnauthorized and the UI can
    // redirect to login, matching real 401 behaviour.
    if (platformKey == null) {
      return handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: options,
            statusCode: 401,
            data: {'detail': 'Platform API key not found. Please log in again.'},
          ),
        ),
        true,
      );
    }

    options.headers['X-Platform-Key'] = platformKey;
    if (providerType != null) {
      options.headers['X-Provider-Type'] = providerType.headerValue;
    }
    if (providerKey != null) {
      // Never log providerKey — it is a BYOK secret.
      options.headers['X-Provider-Key'] = providerKey;
    }

    handler.next(options);
  }

  /// Auth-only endpoints do not carry generation headers.
  bool _isAuthEndpoint(String path) =>
      path.contains('/register') || path.contains('/login');
}
