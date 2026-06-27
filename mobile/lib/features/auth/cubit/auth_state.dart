import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// State for [RegistrationCubit].
@immutable
sealed class RegistrationState extends Equatable {
  const RegistrationState();
  @override
  List<Object?> get props => [];
}

final class RegistrationIdle extends RegistrationState {
  const RegistrationIdle();
}

final class RegistrationSubmitting extends RegistrationState {
  const RegistrationSubmitting();
}

final class RegistrationSuccess extends RegistrationState {
  const RegistrationSuccess();
}

final class RegistrationEmailConflict extends RegistrationState {
  const RegistrationEmailConflict();
}

final class RegistrationFailure extends RegistrationState {
  const RegistrationFailure({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}

// ── Login ─────────────────────────────────────────────────────────────────────

@immutable
sealed class LoginState extends Equatable {
  const LoginState();
  @override
  List<Object?> get props => [];
}

final class LoginIdle extends LoginState {
  const LoginIdle();
}

final class LoginSubmitting extends LoginState {
  const LoginSubmitting();
}

final class LoginSuccess extends LoginState {
  const LoginSuccess();
}

final class LoginFailure extends LoginState {
  const LoginFailure({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}

final class PasswordResetSent extends LoginState {
  const PasswordResetSent();
}

final class PasswordResetFailure extends LoginState {
  const PasswordResetFailure({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}
