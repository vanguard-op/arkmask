import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app.dart';

/// Shows a bottom sheet with a single "Download to Camera Roll" action for
/// [gcsPath], triggered by long-pressing a video.mp4 / final.mp4 row in the
/// file browser (FEAT-021 / FEAT-026).
///
/// Previously the only way to save a video to the gallery was the "Download
/// to Camera Roll" button inside the video editor's export-complete modal
/// (see [EditorCubit.downloadToGallery] in editor_cubit.dart, still used by
/// that screen) — once that modal was dismissed, there was no way back to
/// it, and video.mp4/final.mp4 rows in the file browser had no download
/// affordance at all. This gives every video row its own independent
/// download entry point, mirroring the same fetch → temp file → Gal.putVideo
/// steps as the editor's flow but without requiring EditorCubit/Firestore
/// state — it only needs a GCS path.
void showDownloadToGallerySheet(
  BuildContext context, {
  required String gcsPath,
  required String fileNameHint,
}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Download to Camera Roll'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _downloadVideoToGallery(
                context,
                gcsPath: gcsPath,
                fileNameHint: fileNameHint,
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// Fetches a fresh presigned URL for [gcsPath], downloads the bytes, and
/// saves the result to the device gallery via [Gal.putVideo]. Shows a
/// loading dialog while in flight and a snackbar on completion/failure.
///
/// Mirrors EditorCubit.downloadToGallery()'s steps exactly (presigned URL →
/// download bytes → write temp file → Gal.putVideo → delete temp file) so
/// behavior is identical regardless of which entry point triggered it.
Future<void> _downloadVideoToGallery(
  BuildContext context, {
  required String gcsPath,
  required String fileNameHint,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  File? tmpFile;
  try {
    final apiClient = ArkMaskServices.of(context).apiClient;

    // 1. Obtain a fresh presigned URL.
    final url = await apiClient.getPresignedUrl(gcsPath: gcsPath);

    // 2. Download the bytes.
    final bytes = await apiClient.downloadBytes(url);

    // 3. Write bytes to a temporary file — Gal.putVideo requires a path.
    final tmpDir = await getTemporaryDirectory();
    // Forward-compat notice that RegExp will become `final` in a future Dart
    // release (implement `Pattern` instead of `RegExp`); constructing one via
    // `RegExp(pattern)` remains the supported API and has no replacement.
    // ignore: deprecated_member_use
    final safeName = fileNameHint.replaceAll(RegExp(r'[^\w.-]'), '_');
    final tmpPath = p.join(tmpDir.path, 'arkmask_$safeName');
    tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(bytes);

    // 4. Save to the device gallery.
    await Gal.putVideo(tmpPath);

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Saved to your gallery.')),
    );
  } catch (_) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not save video. Please try again.')),
    );
  } finally {
    // 5. Clean up the temp file regardless of outcome.
    try {
      if (tmpFile != null && await tmpFile.exists()) {
        await tmpFile.delete();
      }
    } catch (_) {}
  }
}
