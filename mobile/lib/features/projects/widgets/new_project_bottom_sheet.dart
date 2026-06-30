import 'package:flutter/material.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Bottom sheet for creating a new project (FEAT-004 / Screen 6).
///
/// Calls `POST /projects` via [ArkMaskApiClient], which creates the Firestore
/// project root document and Cloud SQL row. On success it calls [onCreated]
/// with the **immutable project slug** returned by the backend.
///
/// The slug is used for all subsequent navigation and Firestore references —
/// it never changes even if the user later renames the project.
class NewProjectBottomSheet extends StatefulWidget {
  const NewProjectBottomSheet({
    super.key,
    required this.apiClient,
    required this.onCreated,
  });

  final ArkMaskApiClient apiClient;

  /// Called with the immutable project slug after successful creation.
  final void Function(String projectSlug) onCreated;

  @override
  State<NewProjectBottomSheet> createState() => _NewProjectBottomSheetState();
}

class _NewProjectBottomSheetState extends State<NewProjectBottomSheet> {
  final _controller = TextEditingController();
  String? _errorMessage;
  bool _isCreating = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Client-side validation before the API call (server also validates;
  /// this avoids an unnecessary round trip for obvious errors).
  String? _validate(String name) {
    if (name.isEmpty) return 'Project name is required.';
    if (name.length > 60) return 'Project name must be 60 characters or fewer.';
    return null;
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    final validationError = _validate(name);
    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

    setState(() {
      _errorMessage = null;
      _isCreating = true;
    });

    try {
      final result = await widget.apiClient.createProject(displayName: name);
      final slug = result['project_slug'] as String?;
      if (slug == null || slug.isEmpty) {
        throw Exception('Backend returned empty project slug.');
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onCreated(slug);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _errorMessage = 'Failed to create project. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final charCount = _controller.text.length;

    return Padding(
      // Push the sheet up with the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSizing.radiusLg),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Handle bar ─────────────────────────────────────────────────
            const SizedBox(height: AppSpacing.s3),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.borderStrongDark : AppColors.borderStrongLight,
                  borderRadius: BorderRadius.circular(AppSizing.radiusFull),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s5),
            // ── Title ──────────────────────────────────────────────────────
            Text('New Project', style: AppTextStyles.h2(context)),
            const SizedBox(height: AppSpacing.s4),
            // ── Name field ─────────────────────────────────────────────────
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 60,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() => _errorMessage = null),
              onSubmitted: (_) => _create(),
              decoration: InputDecoration(
                labelText: 'Project Name',
                counterText: '',
                errorText: _errorMessage,
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            // ── Character counter ──────────────────────────────────────────
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$charCount / 60',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s6),
            // ── Action buttons ─────────────────────────────────────────────
            Row(
              children: [
                TextButton(
                  onPressed: _isCreating ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isCreating ? null : _create,
                    child: _isCreating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : const Text('Create'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s6),
          ],
        ),
      ),
    );
  }
}
