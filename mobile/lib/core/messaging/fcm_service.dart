import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../jobs/jobs_cubit.dart';

/// Wires Firebase Cloud Messaging into [JobsCubit], per
/// docs/ArkMask/architecture.md (Component: Push Notification Service).
///
/// FCM is the *primary* signal that an async generation job (image, video,
/// merge, prompt, asset extraction) has completed. Unlike a Firestore
/// listener owned by the screen that enqueued the job, FCM delivery does not
/// depend on any particular screen being mounted — a push resolves the job
/// in [JobsCubit] no matter where the user currently is in the app.
///
/// [JobsCubit.pollPendingJobs] is the documented fallback for a missed push
/// (device offline, stale token, app force-closed by the OS before the push
/// arrived).
class FcmService {
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedAppSub;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<User?>? _authSub;

  /// Registers listeners and the device token. Safe to call once at app
  /// startup. Fails silently (degrading to polling-only resolution) if
  /// Firebase is not configured or permission is denied — this must never
  /// block app startup.
  Future<void> init({required JobsCubit jobsCubit}) async {
    try {
      final messaging = FirebaseMessaging.instance;

      // iOS and Android 13+ require explicit permission. Denial is
      // non-fatal: JobsCubit.pollPendingJobs still resolves jobs on
      // foreground return, just with higher latency.
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // App is in the foreground when the job completes.
      _foregroundSub = FirebaseMessaging.onMessage.listen(
        (message) => _handleJobCompletion(message, jobsCubit),
      );

      // App was backgrounded and the user tapped the system notification.
      _openedAppSub = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _handleJobCompletion(message, jobsCubit),
      );

      // App was fully terminated and cold-started by tapping the push.
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleJobCompletion(initialMessage, jobsCubit);
      }

      // Register (and keep registered) the device token on the user's
      // profile so the backend can target this device. Re-runs whenever
      // auth state changes (e.g. sign-in after app launch) since the token
      // fetched before login has nowhere to be written yet.
      _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user != null) _registerToken(messaging);
      });
      await _registerToken(messaging);
      _tokenRefreshSub = messaging.onTokenRefresh.listen(_persistToken);
    } catch (e, st) {
      debugPrint('FcmService.init failed (non-fatal, falls back to polling): $e\n$st');
    }
  }

  /// Parses the job-completion payload (architecture.md "FCM Data Payload
  /// (all job types)": `{ job_id, type, project_id, scene_index, asset_name,
  /// status }`) and resolves the job in [jobsCubit].
  void _handleJobCompletion(RemoteMessage message, JobsCubit jobsCubit) {
    final data = message.data;
    final jobId = data['job_id'] as String?;
    final status = data['status'] as String?;
    if (jobId == null || status == null) return;

    // Worker payload uses 'completed'/'failed'; the registry's terminal
    // status vocabulary is 'success'/'failed' (see JobRegistryEntry).
    final registryStatus = status == 'completed' ? 'success' : status;
    jobsCubit.resolve(jobId, registryStatus);
  }

  Future<void> _registerToken(FirebaseMessaging messaging) async {
    final token = await messaging.getToken();
    if (token != null) await _persistToken(token);
  }

  /// Stores the current FCM token on `users/{uid}/profile/data.fcm_token`
  /// (architecture.md line 55) so workers can target this device.
  Future<void> _persistToken(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .doc('users/$uid/profile/data')
          .set({'fcm_token': token}, SetOptions(merge: true));
    } catch (_) {
      // Non-fatal — this device falls back to polling-only resolution until
      // the next successful token write.
    }
  }

  void dispose() {
    _foregroundSub?.cancel();
    _openedAppSub?.cancel();
    _tokenRefreshSub?.cancel();
    _authSub?.cancel();
  }
}
