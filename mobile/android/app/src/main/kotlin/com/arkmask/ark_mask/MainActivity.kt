package com.arkmask.ark_mask

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Enable true edge-to-edge natively, before Flutter's first frame.
        //
        // The Dart-side SystemChrome.setEnabledSystemUIMode(edgeToEdge) call
        // in main() is a method-channel call that fires after
        // WidgetsFlutterBinding.ensureInitialized() but can still race the
        // native window/decor view setup on some devices and OS versions —
        // when it loses that race, Android silently falls back to its
        // legacy layout, where space is reserved for the system bars. Since
        // the app now reserves its own bottom space via a global SafeArea
        // (see app.dart), edge-to-edge needs to be reliably engaged so that
        // reservation is the only one in effect — calling WindowCompat here,
        // ahead of super.onCreate(), guarantees that from the very first
        // frame regardless of the method-channel race.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }
}
