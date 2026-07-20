import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// A single read-only scene block parsed from `refined_story_preview`.
class _PreviewScene {
  const _PreviewScene({required this.number, required this.body});
  final int number;
  final String body;
}

/// Parses `# N` headings the same way [StoryCubit] does — kept as a small
/// standalone copy since this screen deliberately has no cubit of its own
/// (it's a single-purpose review screen backed directly by one Firestore
/// document listener, see class doc below).
List<_PreviewScene> _parseScenes(String raw) {
  if (raw.trim().isEmpty) return [];
  // ignore: deprecated_member_use
  final headingPattern = RegExp(r'^# (\d+)\s*$', multiLine: true);
  final matches = headingPattern.allMatches(raw).toList();
  if (matches.isEmpty) {
    return [_PreviewScene(number: 1, body: raw.trim())];
  }
  final scenes = <_PreviewScene>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final number = int.parse(match.group(1)!);
    final bodyStart = match.end;
    final bodyEnd = i + 1 < matches.length ? matches[i + 1].start : raw.length;
    scenes.add(_PreviewScene(number: number, body: raw.substring(bodyStart, bodyEnd).trim()));
  }
  return scenes;
}

/// Refine Story Preview Screen (Screen 8a, FEAT-038).
///
/// Lets the user review the AI-rewritten story produced by `/refine-story`
/// before deciding whether to Apply it over `story_content` or Discard it —
/// the confirmation step that keeps the refine flow non-destructive (see
/// docs/ArkMask/risk_log.md R-026/R-027/R-028).
///
/// Deliberately has no dedicated Cubit — it reads `refined_story_preview`,
/// `refined_story_generated_at`, and `story_content` (for the scene-count
/// delta) directly off one Firestore document listener, and its two actions
/// are each a single Firestore write. This mirrors the "read-only review +
/// two terminal actions" shape of the screen without introducing bloc/cubit
/// machinery for state that never needs to survive navigation.
class RefineStoryPreviewScreen extends StatefulWidget {
  const RefineStoryPreviewScreen({super.key, required this.projectSlug});

  final String projectSlug;

  @override
  State<RefineStoryPreviewScreen> createState() => _RefineStoryPreviewScreenState();
}

class _RefineStoryPreviewScreenState extends State<RefineStoryPreviewScreen> {
  DocumentSnapshot<Map<String, dynamic>>? _snap;
  bool _loading = true;
  bool _busy = false; // Apply/Discard write in flight
  String? _error;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> get _projectDoc => FirebaseFirestore.instance
      .collection('users')
      .doc(_uid)
      .collection('projects')
      .doc(widget.projectSlug);

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _stream = _projectDoc.snapshots();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _snap = snapshot.data;
          _loading = false;
        }
        final data = _snap?.data();
        final refinedPreview = data?['refined_story_preview'] as String?;
        final storyContent = data?['story_content'] as String? ?? '';
        final refinedScenes = _parseScenes(refinedPreview ?? '');
        final currentSceneCount = _parseScenes(storyContent).length;
        final delta = refinedScenes.length - currentSceneCount;

        return Scaffold(
          appBar: _PreviewAppBar(
            newCount: refinedScenes.length,
            delta: delta,
          ),
          body: _loading
              ? const _SkeletonBody()
              : (refinedPreview == null
                  ? const _NothingToReview()
                  : _PreviewBody(scenes: refinedScenes, error: _error)),
          bottomNavigationBar: _loading || refinedPreview == null
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: _busy ? null : () => _discard(context),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(context).brightness == Brightness.dark
                                ? AppColors.errorDark
                                : AppColors.errorLight,
                          ),
                          child: const Text('Discard'),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _busy ? null : () => _apply(context),
                            child: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('Apply'),
                                      Text(
                                        'Replaces your current story',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _apply(BuildContext context) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final data = _snap?.data();
    final refinedPreview = data?['refined_story_preview'] as String? ?? '';
    // Whether the project had extracted assets or generated scenes/videos —
    // drives the follow-up "re-run Extract Assets" suggestion after Apply.
    final hadAssetsOrScenes = await _hasExistingAssetsOrScenes();

    try {
      await _projectDoc.update({
        'story_content': refinedPreview,
        'refined_story_preview': null,
        'refined_story_generated_at': null,
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (!context.mounted) return;
      context.pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hadAssetsOrScenes
                ? 'Refined story applied. Story structure changed — re-run Extract Assets '
                    'from the file browser to keep assets and scenes in sync.'
                : 'Refined story applied.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't complete this action.";
      });
    }
  }

  Future<void> _discard(BuildContext context) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _projectDoc.update({
        'refined_story_preview': null,
        'refined_story_generated_at': null,
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (!context.mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't complete this action.";
      });
    }
  }

  /// Mirrors StoryCubit._hasExistingAssetsOrScenes — used only to decide
  /// whether to show the post-Apply follow-up suggestion.
  Future<bool> _hasExistingAssetsOrScenes() async {
    final globalAssets = await _projectDoc.collection('assets').limit(1).get();
    if (globalAssets.docs.isNotEmpty) return true;
    final scenes = await _projectDoc.collection('scenes').get();
    for (final doc in scenes.docs) {
      final data = doc.data();
      if ((data['storyboard_body'] as String?)?.isNotEmpty == true) return true;
      if (data['gcs_video_path'] != null) return true;
      final sceneAssets = await doc.reference.collection('assets').limit(1).get();
      if (sceneAssets.docs.isNotEmpty) return true;
    }
    return false;
  }
}

class _PreviewAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PreviewAppBar({required this.newCount, required this.delta});

  final int newCount;
  final int delta;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final changed = delta != 0;
    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () => context.pop(),
      ),
      title: Text(
        'Refined Story',
        style: AppTextStyles.body(context).copyWith(
          fontFamily: 'JetBrains Mono',
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.s4),
          child: Center(
            child: Text(
              changed
                  ? '$newCount scenes (was ${newCount - delta})'
                  : '$newCount scenes',
              style: AppTextStyles.caption(context).copyWith(
                color: changed
                    ? (isDark ? AppColors.warningDark : AppColors.warningLight)
                    : (isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.scenes, required this.error});

  final List<_PreviewScene> scenes;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s3),
              child: Text(
                error!,
                style: AppTextStyles.bodySmall(context).copyWith(
                  color: isDark ? AppColors.errorDark : AppColors.errorLight,
                ),
              ),
            ),
          for (final scene in scenes) ...[
            Row(
              children: [
                Expanded(child: Divider(color: dividerColor, height: 1)),
                const SizedBox(width: AppSpacing.s2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2, vertical: 2),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppSizing.radiusXs),
                  ),
                  child: Text(
                    'SCENE ${scene.number}',
                    style: AppTextStyles.caption(context)
                        .copyWith(color: primaryColor, letterSpacing: 0.8),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(child: Divider(color: dividerColor, height: 1)),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(scene.body, style: AppTextStyles.bodyLarge(context)),
            const SizedBox(height: AppSpacing.s4),
          ],
        ],
      ),
    );
  }
}

class _NothingToReview extends StatelessWidget {
  const _NothingToReview();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Nothing to review.',
        style: AppTextStyles.body(context),
      ),
    );
  }
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(6, (i) {
          final width = (i % 3 == 0) ? double.infinity : (i % 2 == 0 ? 220.0 : 160.0);
          return Container(
            height: 14,
            width: width,
            margin: const EdgeInsets.only(bottom: AppSpacing.s3),
            decoration: BoxDecoration(
              color: base.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppSizing.radiusXs),
            ),
          );
        }),
      ),
    );
  }
}
