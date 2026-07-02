import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';

/// Background/terminated-state FCM handler.
///
/// Runs in a separate, short-lived isolate with no access to app state
/// (JobsCubit, JobRegistryService, widget tree), so it intentionally does
/// nothing beyond letting the OS display the system notification. Job
/// resolution for pushes received while backgrounded happens when the app
/// returns to the foreground — see `FcmService.init` (`getInitialMessage` /
/// `onMessageOpenedApp`) and `JobsCubit.pollPendingJobs`, the documented
/// fallback in docs/ArkMask/architecture.md.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase if the project has been configured via `flutterfire configure`.
  // Until firebase_options.dart is populated with real values, Firebase features
  // (auth, FCM) are unavailable and the app runs in offline-only mode.
  if (isFirebaseConfigured) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  runApp(const ArkMaskApp());
}
