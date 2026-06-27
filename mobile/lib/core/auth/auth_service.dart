import 'package:firebase_auth/firebase_auth.dart';

import '../storage/secure_storage_service.dart';

/// Result of a registration or login operation.
sealed class AuthResult {}

final class AuthSuccess extends AuthResult {
  AuthSuccess({required this.platformApiKey});
  final String platformApiKey;
}

final class AuthFailure extends AuthResult {
  AuthFailure({required this.message, this.isEmailConflict = false});
  final String message;

  /// True when the server returned 409 (email already registered).
  final bool isEmailConflict;
}

/// Wraps Firebase Auth and the ArkMask backend auth endpoints.
///
/// Responsible for:
/// - Registration (Firebase + backend user creation + platform key receipt)
/// - Login (Firebase sign-in + backend platform key fetch)
/// - Session persistence (Firebase handles token refresh automatically)
/// - Password reset (Firebase Auth built-in flow — no backend needed)
/// - Sign-out (Firebase sign-out + secure storage clear)
///
/// The platform API key returned by the backend on registration/login is
/// persisted by this service in [SecureStorageService]. Feature code never
/// stores the key directly.
class AuthService {
  AuthService({
    required this.storageService,
    required this.firebaseAuth,
  });

  final SecureStorageService storageService;
  final FirebaseAuth firebaseAuth;

  /// True when a Firebase session is currently active.
  bool get isSignedIn => firebaseAuth.currentUser != null;

  /// Stream of Firebase auth state changes — used by the router to react to
  /// sign-in and sign-out events.
  Stream<User?> get authStateChanges => firebaseAuth.authStateChanges();

  // ── Registration ────────────────────────────────────────────────────────────

  /// Creates a Firebase Auth user and a corresponding ArkMask backend user.
  ///
  /// On success, saves the returned [platformApiKey] to secure storage.
  /// The [apiRegistrationCall] callback is provided by the feature layer
  /// (auth cubit) so this service does not depend on [ArkMaskApiClient]
  /// directly, keeping the dependency graph clean.
  ///
  /// Flow:
  /// 1. Create Firebase user (email + password).
  /// 2. Get Firebase ID token.
  /// 3. Call backend `/register` → receive platform API key.
  /// 4. Save key to secure storage.
  Future<AuthResult> register({
    required String email,
    required String password,
    required Future<String> Function(String idToken) apiRegistrationCall,
  }) async {
    try {
      final credential = await firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final idToken = await credential.user!.getIdToken();
      final platformKey = await apiRegistrationCall(idToken!);
      await storageService.savePlatformApiKey(platformKey);
      return AuthSuccess(platformApiKey: platformKey);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        return AuthFailure(
          message: 'An account with this email already exists.',
          isEmailConflict: true,
        );
      }
      if (e.code == 'weak-password') {
        return AuthFailure(message: 'Password must be at least 8 characters.');
      }
      return AuthFailure(message: 'Registration failed. Please try again.');
    } catch (_) {
      return AuthFailure(message: 'Registration failed. Check your connection and try again.');
    }
  }

  // ── Login ────────────────────────────────────────────────────────────────────

  /// Signs in with email and password via Firebase Auth, then fetches the
  /// platform API key from the backend and saves it to secure storage.
  Future<AuthResult> login({
    required String email,
    required String password,
    required Future<String> Function(String idToken) apiLoginCall,
  }) async {
    try {
      final credential = await firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final idToken = await credential.user!.getIdToken();
      final platformKey = await apiLoginCall(idToken!);
      await storageService.savePlatformApiKey(platformKey);
      return AuthSuccess(platformApiKey: platformKey);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential') {
        return AuthFailure(message: 'Incorrect email or password.');
      }
      return AuthFailure(message: 'Login failed. Please try again.');
    } catch (_) {
      return AuthFailure(message: 'Login failed. Check your connection and try again.');
    }
  }

  // ── Password reset ────────────────────────────────────────────────────────────

  /// Sends a Firebase Auth password reset email.
  ///
  /// Always returns without error regardless of whether the email is registered
  /// (prevents account enumeration — FEAT-031 acceptance criteria).
  Future<void> sendPasswordReset({required String email}) async {
    try {
      await firebaseAuth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException {
      // Swallow — same response shown whether email is registered or not.
    }
  }

  // ── Sign-out ────────────────────────────────────────────────────────────────

  /// Signs out of Firebase and clears all credentials from secure storage.
  ///
  /// Local project files on-device are NOT affected (per FEAT-023 spec).
  Future<void> signOut() async {
    await Future.wait([
      firebaseAuth.signOut(),
      storageService.clearOnSignOut(),
    ]);
  }
}
