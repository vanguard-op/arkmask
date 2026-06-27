/// Structured error returned by [ArkMaskApiClient] on non-2xx responses
/// or network failures.
sealed class ApiError implements Exception {}

/// 401 — Invalid or expired platform API key.
/// The app should clear credentials and redirect to login.
final class ApiUnauthorized extends ApiError {
  ApiUnauthorized();
}

/// 402 — Insufficient credits.
/// Carry the current balance so the UI can show it in the paywall modal.
final class ApiInsufficientCredits extends ApiError {
  ApiInsufficientCredits({this.balance});
  final int? balance;
}

/// 409 — Conflict (e.g., email already registered).
final class ApiConflict extends ApiError {
  ApiConflict({required this.message});
  final String message;
}

/// 422 — Validation error from the backend.
final class ApiValidationError extends ApiError {
  ApiValidationError({required this.detail});
  final String detail;
}

/// 5xx — Backend or provider error.
final class ApiServerError extends ApiError {
  ApiServerError({required this.statusCode, required this.message});
  final int statusCode;
  final String message;
}

/// Network error — offline or timeout.
final class ApiNetworkError extends ApiError {
  ApiNetworkError({required this.message});
  final String message;
}

/// Any other unexpected error.
final class ApiUnknownError extends ApiError {
  ApiUnknownError({required this.message});
  final String message;
}
