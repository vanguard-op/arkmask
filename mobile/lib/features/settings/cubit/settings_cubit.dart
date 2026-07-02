import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/jobs/job_registry_service.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/secure_storage_service.dart';
import 'settings_state.dart';

/// Cubit for the Settings Screen (FEAT-022, FEAT-023).
///
/// Loads the current provider type and platform API key (masked) on init.
/// Credit balance and tier are live — see [_subscribeToProfile]. Handles
/// sign-out.
class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit({
    required this.storage,
    required this.authService,
    required this.apiClient,
    required this.jobRegistryService,
  }) : super(const SettingsLoading());

  final SecureStorageService storage;
  final AuthService authService;
  final ArkMaskApiClient apiClient;
  final JobRegistryService jobRegistryService;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;

  /// Loads all settings data from secure storage and backend.
  Future<void> load() async {
    emit(const SettingsLoading());
    try {
      final platformKey = await storage.readPlatformApiKey();
      final providerType = await storage.readProviderType();

      final raw = platformKey ?? '';
      final masked = _maskKey(raw);

      emit(SettingsLoaded(
        platformKeyMasked: masked,
        platformKeyRaw: raw,
        platformKeyRevealed: false,
        providerType: providerType,
      ));

      _subscribeToProfile();
    } catch (e) {
      emit(const SettingsError(message: 'Failed to load settings.'));
    }
  }

  /// Subscribes to the user's Firestore profile document
  /// (`users/{uid}/profile/data`) so credit balance / tier stay live —
  /// e.g. a Stripe subscription upgrade (written by the webhook straight to
  /// this document) now appears immediately instead of requiring an app
  /// restart. Mirrors ProjectsCubit's identical fix for the Home screen pill.
  void _subscribeToProfile() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _profileSub?.cancel();
    _profileSub = FirebaseFirestore.instance
        .doc('users/$uid/profile/data')
        .snapshots()
        .listen(
          (snap) {
            if (!snap.exists) return;
            final data = snap.data();
            if (data == null) return;
            final credits = data['credit_balance'] as int?;
            final tierStr = data['tier'] as String?;
            final tier = tierStr != null ? UserTier.fromString(tierStr) : null;
            if (state is SettingsLoaded) {
              emit((state as SettingsLoaded).copyWith(
                creditBalance: credits,
                tier: tier,
              ));
            }
          },
          onError: (_) {
            // Non-critical — the pill just shows "—" until the next
            // successful snapshot; the rest of the screen is unaffected.
          },
        );
  }

  /// Toggles the platform API key between masked and revealed.
  void toggleKeyVisibility() {
    if (state is! SettingsLoaded) return;
    final s = state as SettingsLoaded;
    emit(s.copyWith(platformKeyRevealed: !s.platformKeyRevealed));
  }

  /// Regenerates the platform API key (FEAT-025).
  ///
  /// Calls the backend, saves the new key to secure storage, and updates the
  /// masked display. Emits an error snackbar if the request fails.
  Future<void> regenerateKey() async {
    if (state is! SettingsLoaded) return;
    final s = state as SettingsLoaded;
    emit(s.copyWith(isRegeneratingKey: true));
    try {
      final newKey = await apiClient.regenerateApiKey();
      await storage.savePlatformApiKey(newKey);
      emit((state as SettingsLoaded).copyWith(
        isRegeneratingKey: false,
        platformKeyRaw: newKey,
        platformKeyMasked: _maskKey(newKey),
        platformKeyRevealed: false,
      ));
    } catch (_) {
      // Restore the non-loading state; the screen surfaces the error via listener.
      if (state is SettingsLoaded) {
        emit((state as SettingsLoaded).copyWith(isRegeneratingKey: false));
      }
      rethrow;
    }
  }

  /// Signs out — clears credentials and emits [SettingsSignedOut].
  ///
  /// The Hive CE job registry is cleared first (FEAT-023) so orphaned job
  /// entries from this session do not persist into the next login.
  Future<void> signOut() async {
    if (state is! SettingsLoaded) return;
    final s = state as SettingsLoaded;
    emit(s.copyWith(isSigningOut: true));
    // Stop listening before auth clears — otherwise the profile snapshot
    // listener immediately hits a permission-denied error once signed out.
    await _profileSub?.cancel();
    await jobRegistryService.clearAll();
    await authService.signOut();
    emit(const SettingsSignedOut());
  }

  /// Masks a platform API key for display.
  ///
  /// Shows last 4 characters only: "ark_••••••••1a2b"
  String _maskKey(String key) {
    if (key.length <= 4) return key;
    final last4 = key.substring(key.length - 4);
    return '••••••••$last4';
  }

  @override
  Future<void> close() async {
    await _profileSub?.cancel();
    return super.close();
  }
}
