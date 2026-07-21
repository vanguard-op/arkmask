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

/// A single dependent asset returned by `DELETE /assets`'s 409 response
/// (FEAT-037) — another asset in the project has a `ref` chain (FEAT-013)
/// that resolves through the one being deleted, directly or transitively.
class AssetDependent {
  AssetDependent({required this.assetPath, required this.name, required this.ref});

  /// Relative path of the dependent asset, e.g. `scenes/3/assets/shade-variant`.
  final String assetPath;

  /// The dependent's own `name` field (display label only), e.g. `Shade (moody variant)`.
  final String name;

  /// The dependent's own `ref` field — the asset_path it points to directly
  /// (may be the asset being deleted, or another asset further along the
  /// chain that ultimately resolves to it).
  final String? ref;
}

/// Thrown by [ArkMaskApiClient.deleteAsset] when the backend blocks the
/// delete because one or more other assets reference this one and `force`
/// was not set (FEAT-037). The UI should list [dependents] and offer a
/// force-delete retry.
class AssetDeleteBlockedException implements Exception {
  AssetDeleteBlockedException({required this.dependents});
  final List<AssetDependent> dependents;
}
