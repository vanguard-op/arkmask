import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/secure_storage_service.dart';
import 'settings_state.dart';

/// Cubit for the Settings Screen (FEAT-022, FEAT-023).
///
/// Loads the current provider type, platform API key (masked), and credit
/// balance on init. Handles sign-out.
class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit({
    required this.storage,
    required this.authService,
    required this.apiClient,
  }) : super(const SettingsLoading());

  final SecureStorageService storage;
  final AuthService authService;
  final ArkMaskApiClient apiClient;

  /// Loads all settings data from secure storage and backend.
  Future<void> load() async {
    emit(const SettingsLoading());
    try {
      final platformKey = await storage.readPlatformApiKey();
      final providerType = await storage.readProviderType();

      final masked = _maskKey(platformKey ?? '');

      emit(SettingsLoaded(
        platformKeyMasked: masked,
        platformKeyRevealed: false,
        providerType: providerType,
      ));

      // Fire-and-forget credits fetch.
      _fetchCredits();
    } catch (e) {
      emit(const SettingsError(message: 'Failed to load settings.'));
    }
  }

  Future<void> _fetchCredits() async {
    try {
      final data = await apiClient.getCredits();
      final credits = data['credits'] as int?;
      final tierStr = data['tier'] as String?;
      final tier = tierStr != null ? UserTier.fromString(tierStr) : null;
      if (state is SettingsLoaded) {
        emit((state as SettingsLoaded).copyWith(
          creditBalance: credits,
          tier: tier,
        ));
      }
    } catch (_) {
      // Credits fetch is non-critical — ignore failures gracefully.
    }
  }

  /// Toggles the platform API key between masked and revealed.
  void toggleKeyVisibility() {
    if (state is! SettingsLoaded) return;
    final s = state as SettingsLoaded;
    emit(s.copyWith(platformKeyRevealed: !s.platformKeyRevealed));
  }

  /// Signs out — clears credentials and emits [SettingsSignedOut].
  Future<void> signOut() async {
    if (state is! SettingsLoaded) return;
    final s = state as SettingsLoaded;
    emit(s.copyWith(isSigningOut: true));
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
}
