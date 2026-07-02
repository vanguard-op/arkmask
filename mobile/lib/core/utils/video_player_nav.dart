import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../router/routes.dart';

/// Resolves a presigned URL for [gcsPath] and navigates to
/// [Routes.videoPlayer].
///
/// GCS presigned URLs are not generated ahead of time and stored anywhere —
/// every playback needs a fresh one fetched via
/// `ArkMaskApiClient.getPresignedUrl`. Previously, callers pushed
/// [Routes.videoPlayer] with the raw GCS object path (e.g.
/// `"uid/slug/scenes/2/video.mp4"`) directly as the `path` query param,
/// skipping this resolution step entirely. `VideoPlayerScreen` only treats a
/// `path` starting with `http://`/`https://` as a network URL — anything
/// else is treated as a local filesystem path, fails the `File.exists()`
/// check immediately, and shows "Unable to play video". This helper is the
/// one place that resolution now happens, so every video.mp4 / final.mp4 tap
/// goes through it instead of each call site reimplementing (or skipping)
/// the presign step.
///
/// Shows a brief loading indicator while the presigned URL is being fetched
/// (this is a fast network call, but not instant) and a snackbar on failure.
/// [gcsPath] is also passed through to [Routes.videoPlayer] so
/// `VideoPlayerScreen` can transparently fetch a fresh presigned URL if this
/// one expires mid-playback (2-hour TTL — see architecture.md).
Future<void> openVideoPlayer(
  BuildContext context, {
  required String gcsPath,
  required String title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(),
    ),
  );

  String presignedUrl;
  try {
    presignedUrl = await ArkMaskServices.of(context)
        .apiClient
        .getPresignedUrl(gcsPath: gcsPath);
  } catch (_) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not load video. Please try again.')),
    );
    return;
  }

  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

  router.push(
    Uri(
      path: Routes.videoPlayer,
      queryParameters: {
        'path': Uri.encodeComponent(presignedUrl),
        'gcsPath': Uri.encodeComponent(gcsPath),
        'title': title,
      },
    ).toString(),
  );
}
