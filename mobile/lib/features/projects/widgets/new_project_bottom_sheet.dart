import 'package:flutter/material.dart';

import '../../../core/filesystem/project_file_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Bottom sheet for creating a new project (FEAT-004 / Screen 6).
///
/// Validates the name, creates the project directory structure on device,
/// and calls [onCreated] with the resulting project name.
///
/// Not dismissable by drag while the keyboard is open.
class NewProjectBottomSheet extends StatefulWidget {
  const NewProjectBottomSheet({
    super.key,
    required this.fileService,
    required this.onCreated,
  });

  final ProjectFileService fileService;
  final void Function(String projectName) onCreated;

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

  Future<void> _create() async {
    final name = _controller.text.trim();

    // Local validation.
    final validationError = widget.fileService.validateProjectName(name);
    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

    // Check for duplicate.
    final exists = await widget.fileService.projectExists(name);
    if (exists) {
      setState(() => _errorMessage = 'A project with this name already exists.');
      return;
    }

    setState(() {
      _errorMessage = null;
      _isCreating = true;
    });

    try {
      final meta = await widget.fileService.createProject(name);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onCreated(meta.name);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _errorMessage = 'Failed to create project. Try again.';
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
