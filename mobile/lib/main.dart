import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase if the project has been configured via `flutterfire configure`.
  // Until firebase_options.dart is populated with real values, Firebase features
  // (auth, FCM) are unavailable and the app runs in offline-only mode.
  if (isFirebaseConfigured) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  runApp(const ArkMaskApp());
}
