import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/models.dart';
import '../../../core/storage/secure_storage_service.dart';
import 'provider_setup_state.dart';

/// Cubit for Provider Setup Screen (FEAT-003) and Provider Settings (FEAT-022).
///
/// Handles provider selection, API key input, saving to secure storage,
/// and pre-population when accessed from Settings.
class ProviderSetupCubit extends Cubit<ProviderSetupState> {
  ProviderSetupCubit({required this.storage})
      : super(const ProviderSetupIdle());

  final SecureStorageService storage;

  /// Loads existing provider selection from secure storage (Settings mode).
  Future<void> loadExisting() async {
    final type = await storage.readProviderType();
    emit(ProviderSetupIdle(selectedProvider: type));
  }

  /// Selects a provider. If a key is already entered and the provider changes,
  /// the caller must show a confirmation dialog before calling this.
  void selectProvider(ProviderType provider) {
    emit(ProviderSetupIdle(
      selectedProvider: provider,
      keyObscured: state.keyObscured,
    ));
  }

  void toggleKeyVisibility() {
    emit(ProviderSetupIdle(
      selectedProvider: state.selectedProvider,
      keyObscured: !state.keyObscured,
    ));
  }

  /// Validates and saves the provider type + key to secure storage.
  Future<bool> save({required String apiKey}) async {
    final trimmedKey = apiKey.trim();
    final provider = state.selectedProvider;

    if (provider == null || trimmedKey.isEmpty) {
      emit(ProviderSetupValidationError(
        selectedProvider: provider,
        providerError: provider == null ? 'Select a provider.' : null,
        keyError: trimmedKey.isEmpty ? 'API key is required.' : null,
      ));
      return false;
    }

    emit(ProviderSetupSaving(selectedProvider: provider));

    await storage.saveProviderType(provider);
    await storage.saveProviderApiKey(trimmedKey);

    emit(ProviderSetupSaved(selectedProvider: provider));
    return true;
  }

  void reset() => emit(ProviderSetupIdle(selectedProvider: state.selectedProvider));
}
