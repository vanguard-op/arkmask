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
    required this.platformKeyRaw,
    required this.platformKeyRevealed,
    this.providerType,
    this.creditBalance,
    this.tier,
    this.isSigningOut = false,
    this.isRegeneratingKey = false,
  });

  /// Masked display (e.g. "••••••••1a2b"). Shown when [platformKeyRevealed] is false.
  final String platformKeyMasked;

  /// The actual raw key, read from secure storage. Never logged or sent anywhere.
  final String platformKeyRaw;

  /// Whether the key is currently revealed in the UI.
  final bool platformKeyRevealed;

  /// The value currently shown in the key tile — raw when revealed, masked otherwise.
  String get platformKeyDisplay =>
      platformKeyRevealed ? platformKeyRaw : platformKeyMasked;

  final ProviderType? providerType;
  final int? creditBalance;
  final UserTier? tier;
  final bool isSigningOut;

  /// True while the platform API key regeneration request is in flight.
  final bool isRegeneratingKey;

  SettingsLoaded copyWith({
    String? platformKeyMasked,
    String? platformKeyRaw,
    bool? platformKeyRevealed,
    ProviderType? providerType,
    int? creditBalance,
    UserTier? tier,
    bool? isSigningOut,
    bool? isRegeneratingKey,
  }) =>
      SettingsLoaded(
        platformKeyMasked: platformKeyMasked ?? this.platformKeyMasked,
        platformKeyRaw: platformKeyRaw ?? this.platformKeyRaw,
        platformKeyRevealed: platformKeyRevealed ?? this.platformKeyRevealed,
        providerType: providerType ?? this.providerType,
        creditBalance: creditBalance ?? this.creditBalance,
        tier: tier ?? this.tier,
        isSigningOut: isSigningOut ?? this.isSigningOut,
        isRegeneratingKey: isRegeneratingKey ?? this.isRegeneratingKey,
      );

  @override
  List<Object?> get props => [
        platformKeyMasked,
        platformKeyRaw,
        platformKeyRevealed,
        providerType,
        creditBalance,
        tier,
        isSigningOut,
        isRegeneratingKey,
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
