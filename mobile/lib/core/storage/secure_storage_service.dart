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
class SecureStorageService {
  SecureStorageService() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final FlutterSecureStorage _storage;

  // ── Platform API key ───────────────────────────────────────────────────────

  Future<void> savePlatformApiKey(String key) =>
      _storage.write(key: _StorageKey.platformApiKey, value: key);

  Future<String?> readPlatformApiKey() =>
      _storage.read(key: _StorageKey.platformApiKey);

  // ── Provider credentials ───────────────────────────────────────────────────

  Future<void> saveProviderType(ProviderType type) =>
      _storage.write(key: _StorageKey.providerType, value: type.name);

  Future<ProviderType?> readProviderType() async {
    final raw = await _storage.read(key: _StorageKey.providerType);
    if (raw == null) return null;
    return ProviderType.fromString(raw);
  }

  /// Saves the user-supplied AI provider API key.
  /// IMPORTANT: Never log this value. It is used in-flight per request and
  /// immediately discarded by the backend — it must never appear in any log.
  Future<void> saveProviderApiKey(String key) =>
      _storage.write(key: _StorageKey.providerApiKey, value: key);

  Future<String?> readProviderApiKey() =>
      _storage.read(key: _StorageKey.providerApiKey);

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
      _storage.delete(key: _StorageKey.platformApiKey),
      _storage.delete(key: _StorageKey.providerType),
      _storage.delete(key: _StorageKey.providerApiKey),
    ]);
  }
}
