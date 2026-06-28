import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the ArkMask vault — the user-chosen folder that contains all projects,
/// mirroring the Obsidian vault model.
///
/// The vault path is persisted in [SharedPreferences] (non-sensitive — it is
/// simply a directory path). The first time the user runs the app they are
/// prompted to choose or create a vault via [VaultSetupScreen].
///
/// Responsibilities:
/// - Persist and recall the vault root path.
/// - Launch the system folder picker so the user can choose any accessible folder.
/// - Migrate existing projects from the legacy `arkmask_projects/` location.
class VaultService extends ChangeNotifier {
  static const _prefKey = 'vault_path';

  String? _vaultPath;
  bool _isInitialized = false;

  /// True once [initialize] has completed (even if no vault is configured).
  bool get isInitialized => _isInitialized;

  /// True when a vault path has been chosen and persisted.
  bool get isConfigured => _vaultPath != null;

  /// The absolute path to the vault root directory, or null if not configured.
  String? get vaultPath => _vaultPath;

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Reads the saved vault path from [SharedPreferences].
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null) {
      // Validate that the saved path still exists on disk.
      final dir = Directory(saved);
      _vaultPath = await dir.exists() ? saved : null;
    }
    _isInitialized = true;
  }

  // ── Configuration ──────────────────────────────────────────────────────────

  /// Persists [path] as the vault root and notifies listeners.
  Future<void> setVaultPath(String path) async {
    _vaultPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, path);
    notifyListeners();
  }

  /// Ensures the app has the storage permission it needs to read/write the
  /// vault on the current Android version.
  ///
  /// - Android 11+ (API 30+): requests `MANAGE_EXTERNAL_STORAGE`, which takes
  ///   the user to the "All files access" Settings screen.
  /// - Android ≤ 10: requests the legacy `WRITE_EXTERNAL_STORAGE` permission.
  /// - iOS / other platforms: returns `true` immediately (no permission needed).
  ///
  /// Returns `true` when the required permission is granted.
  Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // MANAGE_EXTERNAL_STORAGE is the correct permission for Android 11+ so
    // dart:io File operations work on any user-chosen directory path.
    if (await Permission.manageExternalStorage.isGranted) return true;
    final result = await Permission.manageExternalStorage.request();
    if (result.isGranted) return true;

    // On older Android (API ≤ 29) fall back to WRITE_EXTERNAL_STORAGE.
    final legacy = await Permission.storage.request();
    return legacy.isGranted;
  }

  /// Opens the OS folder picker so the user can choose any accessible folder.
  ///
  /// On Android, [requestStoragePermission] must be granted before calling
  /// this; without it the returned path cannot be written via [dart:io].
  /// Returns the selected absolute path, or null if the user cancelled.
  Future<String?> pickVaultFolder() async {
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Vault Folder',
      lockParentWindow: true,
    );
  }

  /// Returns a sensible default vault path:
  /// - Android (permission granted): `/storage/emulated/0/ArkMask`
  ///   — visible in every file manager.
  /// - Android (no permission): app-specific external storage
  ///   (`<externalStorage>/ArkMask`) — writable without permission.
  /// - iOS: `<appDocuments>/ArkMask` — visible in Files app when
  ///   `UIFileSharingEnabled` is set in Info.plist.
  Future<String> getDefaultVaultPath() async {
    if (Platform.isAndroid) {
      // If the user has granted all-files access, use the public storage root
      // so the vault is visible directly in every file manager.
      if (await Permission.manageExternalStorage.isGranted) {
        return '/storage/emulated/0/ArkMask';
      }
      // Otherwise fall back to the app-specific external directory which is
      // always writable without a runtime permission.
      final appExt = await getExternalStorageDirectory();
      if (appExt != null) return p.join(appExt.path, 'ArkMask');
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'ArkMask');
  }

}
