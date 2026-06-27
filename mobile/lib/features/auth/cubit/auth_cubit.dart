import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/auth/auth_service.dart';
import 'auth_state.dart';

/// Cubit for the Registration Screen (FEAT-001).
class RegistrationCubit extends Cubit<RegistrationState> {
  RegistrationCubit({
    required this.authService,
    required this.apiClient,
  }) : super(const RegistrationIdle());

  final AuthService authService;
  final ArkMaskApiClient apiClient;

  /// Submits the registration form.
  ///
  /// Delegates to [AuthService.register], which calls Firebase Auth and then
  /// the backend `/register` endpoint to receive the platform API key.
  Future<void> register({
    required String email,
    required String password,
  }) async {
    emit(const RegistrationSubmitting());
    final result = await authService.register(
      email: email,
      password: password,
      apiRegistrationCall: (idToken) => apiClient.register(
        email: email.trim(),
        idToken: idToken,
      ),
    );

    switch (result) {
      case AuthSuccess():
        emit(const RegistrationSuccess());
      case AuthFailure(:final isEmailConflict) when isEmailConflict:
        emit(const RegistrationEmailConflict());
      case AuthFailure(:final message):
        emit(RegistrationFailure(message: message));
    }
  }

  void reset() => emit(const RegistrationIdle());
}

// ── Login Cubit ───────────────────────────────────────────────────────────────

/// Cubit for the Login Screen (FEAT-002, FEAT-031).
class LoginCubit extends Cubit<LoginState> {
  LoginCubit({
    required this.authService,
    required this.apiClient,
  }) : super(const LoginIdle());

  final AuthService authService;
  final ArkMaskApiClient apiClient;

  /// Submits the login form.
  Future<void> login({
    required String email,
    required String password,
  }) async {
    emit(const LoginSubmitting());
    final result = await authService.login(
      email: email,
      password: password,
      apiLoginCall: (idToken) => apiClient.login(idToken: idToken),
    );

    switch (result) {
      case AuthSuccess():
        emit(const LoginSuccess());
      case AuthFailure(:final message):
        emit(LoginFailure(message: message));
    }
  }

  /// Sends a Firebase Auth password reset email (FEAT-031).
  ///
  /// Always emits [PasswordResetSent] regardless of whether the email is
  /// registered — prevents account enumeration.
  Future<void> sendPasswordReset({required String email}) async {
    try {
      await authService.sendPasswordReset(email: email);
      emit(const PasswordResetSent());
    } catch (_) {
      emit(const PasswordResetSent()); // same message always — no enumeration
    }
  }

  void reset() => emit(const LoginIdle());
}
