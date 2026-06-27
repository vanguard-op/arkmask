import 'package:flutter/foundation.dart';

/// Live state of a single generation step.
enum GenerationJobState {
  idle,
  running,
  done,
  failed;

  bool get isActive => this == running;
  bool get isTerminal => this == done || this == failed;
}

/// Tracks in-progress and completed generation jobs for all assets and scenes.
///
/// Keys follow the convention:
/// - Asset prompt generation:    `<assetDirPath>:prompt`
/// - Asset image generation:     `<assetDirPath>:image`
/// - Scene storyboard generation:`<sceneDirPath>:storyboard`
/// - Scene video generation:     `<sceneDirPath>:video`
///
/// Widgets can use [ListenableBuilder] / [AnimatedBuilder] on this instance
/// to rebuild in response to state changes. The job manager is provided via
/// [ArkMaskServices] as a singleton for the lifetime of the app.
class GenerationJobManager extends ChangeNotifier {
  final _states = <String, GenerationJobState>{};
  final _errors = <String, String>{};

  // ── Key constructors ────────────────────────────────────────────────────────

  static String promptKey(String assetDirPath) => '$assetDirPath:prompt';
  static String imageKey(String assetDirPath) => '$assetDirPath:image';
  static String storyboardKey(String sceneDirPath) => '$sceneDirPath:storyboard';
  static String videoKey(String sceneDirPath) => '$sceneDirPath:video';

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// Returns the current state for [key]. Defaults to [idle] if not tracked.
  GenerationJobState stateFor(String key) =>
      _states[key] ?? GenerationJobState.idle;

  /// Returns the stored error message for a [failed] job, or null.
  String? errorFor(String key) => _errors[key];

  // ── Writes ─────────────────────────────────────────────────────────────────

  void markRunning(String key) => _set(key, GenerationJobState.running);
  void markDone(String key) => _set(key, GenerationJobState.done);
  void markFailed(String key, String error) =>
      _set(key, GenerationJobState.failed, error: error);
  void reset(String key) => _set(key, GenerationJobState.idle);

  void _set(String key, GenerationJobState state, {String? error}) {
    _states[key] = state;
    if (error != null) {
      _errors[key] = error;
    } else {
      _errors.remove(key);
    }
    notifyListeners();
  }
}
