import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';

@immutable
sealed class ProviderSetupState extends Equatable {
  const ProviderSetupState({
    required this.selectedProvider,
    required this.keyObscured,
  });

  final ProviderType? selectedProvider;
  final bool keyObscured;

  @override
  List<Object?> get props => [selectedProvider, keyObscured];
}

final class ProviderSetupIdle extends ProviderSetupState {
  const ProviderSetupIdle({
    super.selectedProvider,
    super.keyObscured = true,
  });
}

final class ProviderSetupSaving extends ProviderSetupState {
  const ProviderSetupSaving({
    required super.selectedProvider,
    super.keyObscured = true,
  });
}

final class ProviderSetupSaved extends ProviderSetupState {
  const ProviderSetupSaved({
    required super.selectedProvider,
    super.keyObscured = true,
  });
}

final class ProviderSetupValidationError extends ProviderSetupState {
  const ProviderSetupValidationError({
    required this.providerError,
    required this.keyError,
    super.selectedProvider,
    super.keyObscured = true,
  });

  final String? providerError;
  final String? keyError;

  @override
  List<Object?> get props => [selectedProvider, keyObscured, providerError, keyError];
}
