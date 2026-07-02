import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// Keys for values stored in Flutter Secure Storage.
/// These are the only credential-related values the app persists.
abstract final class _StorageKey {
  static const String platformApiKey = 'platform_api_key';
  static const String providerType = 'provider_type';
  static const String providerApiKey = 'provider_api_key';
}

/// Manages credential storage in Flutter Secure Storage (iOS Keychain /
/// Android Keystore hardware-backed where available).
///
/// Stores:
/// - Platform API key (X-Platform-Key header)
/// - AI provider type (X-Provider-Type header)
/// - AI provider API key (X-Provider-Key header — BYOK, never logged or sent to any backend)
///
/// All three values are cleared on sign-out. Local project files are unaffected.
///
/// Every `_storage.read`/`write`/`delete` call is bounded by [_opTimeout] —
/// see the timeout rationale on [_read]. This matters beyond just this
/// class: [CredentialInterceptor] calls [readPlatformApiKey] /
/// [readProviderType] / [readProviderApiKey] on *every* API request to build
/// headers, and the splash screen's auth-routing check awaits
/// [hasProviderCredentials] before it can navigate anywhere — an unbounded
/// hang here doesn't just break one screen, it can freeze navigation and
/// every network call in the app.
class SecureStorageService {
  SecureStorageService() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final FlutterSecureStorage _storage;

  /// Bounds every Keystore/Keychain operation below.
  ///
  /// flutter_secure_storage's default Android path generates an RSA keypair
  /// in the Android Keystore (with key attestation, on many API 28+
  /// devices/OEMs) on first access, then wraps a per-value AES key with it.
  /// This is a well-documented source of indefinite hangs/ANRs on specific
  /// real-hardware Keystore implementations — the Android emulator's
  /// software-backed keystore doesn't reproduce it, which is why this can
  /// work fine in development and hang forever ("stuck on splash screen")
  /// only on a real device. Bounding every op means a stuck Keystore call
  /// degrades to "read returns null, as if no credentials were saved yet"
  /// instead of freezing the whole app indefinitely — the user reaches the
  /// login/provider-setup screen and can proceed, rather than being stuck
  /// with no recourse but a force-quit.
  static const _opTimeout = Duration(seconds: 8);

  Future<String?> _read(String key) => _storage
      .read(key: key)
      .timeout(_opTimeout, onTimeout: () => null);

  Future<void> _write(String key, String value) =>
      _storage.write(key: key, value: value).timeout(_opTimeout);

  Future<void> _delete(String key) =>
      _storage.delete(key: key).timeout(_opTimeout, onTimeout: () {});

  // ── Platform API key ───────────────────────────────────────────────────────

  Future<void> savePlatformApiKey(String key) =>
      _write(_StorageKey.platformApiKey, key);

  Future<String?> readPlatformApiKey() => _read(_StorageKey.platformApiKey);

  // ── Provider credentials ───────────────────────────────────────────────────

  Future<void> saveProviderType(ProviderType type) =>
      _write(_StorageKey.providerType, type.name);

  Future<ProviderType?> readProviderType() async {
    final raw = await _read(_StorageKey.providerType);
    if (raw == null) return null;
    return ProviderType.fromString(raw);
  }

  /// Saves the user-supplied AI provider API key.
  /// IMPORTANT: Never log this value. It is used in-flight per request and
  /// immediately discarded by the backend — it must never appear in any log.
  Future<void> saveProviderApiKey(String key) =>
      _write(_StorageKey.providerApiKey, key);

  Future<String?> readProviderApiKey() => _read(_StorageKey.providerApiKey);

  // ── Validation helpers ────────────────────────────────────────────────────

  /// Returns true if all three required headers can be populated.
  Future<bool> hasFullCredentials() async {
    final platform = await readPlatformApiKey();
    final provType = await readProviderType();
    final provKey = await readProviderApiKey();
    return platform != null &&
        platform.isNotEmpty &&
        provType != null &&
        provKey != null &&
        provKey.isNotEmpty;
  }

  /// Returns true if only the provider credentials are missing.
  Future<bool> hasProviderCredentials() async {
    final provType = await readProviderType();
    final provKey = await readProviderApiKey();
    return provType != null && provKey != null && provKey.isNotEmpty;
  }

  // ── Sign-out ───────────────────────────────────────────────────────────────

  /// Clears platform key and provider credentials on sign-out.
  /// Local project files on-device are not affected.
  Future<void> clearOnSignOut() async {
    await Future.wait([
      _delete(_StorageKey.platformApiKey),
      _delete(_StorageKey.providerType),
      _delete(_StorageKey.providerApiKey),
    ]);
  }
}
