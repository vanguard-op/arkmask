import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';

@immutable
sealed class SettingsState extends Equatable {
  const SettingsState();
  @override
  List<Object?> get props => [];
}

final class SettingsLoading extends SettingsState {
  const SettingsLoading();
}

final class SettingsLoaded extends SettingsState {
  const SettingsLoaded({
    required this.platformKeyMasked,
    required this.platformKeyRevealed,
    this.providerType,
    this.creditBalance,
    this.tier,
    this.isSigningOut = false,
  });

  /// Masked display (e.g. "ark_••••••••1234").
  final String platformKeyMasked;

  /// Whether the key is currently revealed in the UI.
  final bool platformKeyRevealed;

  final ProviderType? providerType;
  final int? creditBalance;
  final UserTier? tier;
  final bool isSigningOut;

  SettingsLoaded copyWith({
    String? platformKeyMasked,
    bool? platformKeyRevealed,
    ProviderType? providerType,
    int? creditBalance,
    UserTier? tier,
    bool? isSigningOut,
  }) =>
      SettingsLoaded(
        platformKeyMasked: platformKeyMasked ?? this.platformKeyMasked,
        platformKeyRevealed: platformKeyRevealed ?? this.platformKeyRevealed,
        providerType: providerType ?? this.providerType,
        creditBalance: creditBalance ?? this.creditBalance,
        tier: tier ?? this.tier,
        isSigningOut: isSigningOut ?? this.isSigningOut,
      );

  @override
  List<Object?> get props => [
        platformKeyMasked,
        platformKeyRevealed,
        providerType,
        creditBalance,
        tier,
        isSigningOut,
      ];
}

final class SettingsSignedOut extends SettingsState {
  const SettingsSignedOut();
}

final class SettingsError extends SettingsState {
  const SettingsError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
