import 'package:flutter/material.dart';

import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/models/models.dart';
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
///
/// Generation settings (art style + subtitle preference) can be configured
/// here at creation time. Defaults are applied if the user skips the
/// "Advanced" section.
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
  final _nameController = TextEditingController();
  String? _errorMessage;
  bool _isCreating = false;

  // ── Generation settings state ─────────────────────────────────────────────

  bool _showAdvanced = false;
  String _artStyle = kDefaultArtStyle;
  bool _isCustomStyle = false;
  late final TextEditingController _customStyleController;
  bool _videoSubtitles = false;

  @override
  void initState() {
    super.initState();
    _customStyleController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _customStyleController.dispose();
    super.dispose();
  }

  /// Client-side validation before the API call (server also validates;
  /// this avoids an unnecessary round trip for obvious errors).
  String? _validate(String name) {
    if (name.isEmpty) return 'Project name is required.';
    if (name.length > 60) return 'Project name must be 60 characters or fewer.';
    return null;
  }

  GenerationSettings get _currentSettings {
    final effectiveStyle = _isCustomStyle
        ? (_customStyleController.text.trim().isEmpty
            ? kDefaultArtStyle
            : _customStyleController.text.trim())
        : _artStyle;
    return GenerationSettings(
      artStyle: effectiveStyle,
      videoSubtitles: _videoSubtitles,
    );
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
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
      final result = await widget.apiClient.createProject(
        displayName: name,
        generationSettings: _currentSettings,
      );
      // Backend returns {"slug": "...", "display_name": "..."}.
      final slug = (result['slug'] ?? result['project_slug']) as String?;
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
    final charCount = _nameController.text.length;

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
        child: SingleChildScrollView(
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
              controller: _nameController,
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
            const SizedBox(height: AppSpacing.s4),

            // ── Advanced (Generation Settings) ─────────────────────────────
            _AdvancedToggle(
              expanded: _showAdvanced,
              isDark: isDark,
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            ),
            if (_showAdvanced) ...[
              const SizedBox(height: AppSpacing.s3),
              _GenerationSettingsSection(
                artStyle: _artStyle,
                isCustomStyle: _isCustomStyle,
                customController: _customStyleController,
                videoSubtitles: _videoSubtitles,
                isDark: isDark,
                onPresetSelected: (value) {
                  if (value == null) return;
                  if (value == _kCustomSentinel) {
                    setState(() {
                      _isCustomStyle = true;
                      if (kArtStylePresets.contains(_artStyle)) {
                        _customStyleController.clear();
                      }
                    });
                  } else {
                    setState(() {
                      _isCustomStyle = false;
                      _artStyle = value;
                    });
                  }
                },
                onCustomChanged: (v) => setState(() {}),
                onSubtitlesChanged: (v) => setState(() => _videoSubtitles = v),
              ),
            ],

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
      ),
    );
  }
}

// ── Shared sentinel for the "Custom…" dropdown option ────────────────────────

const _kCustomSentinel = '__custom__';

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({
    required this.expanded,
    required this.isDark,
    required this.onTap,
  });

  final bool expanded;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSizing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
            ),
            const SizedBox(width: AppSpacing.s1),
            Text(
              'Generation Settings',
              style: AppTextStyles.caption(context).copyWith(
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline generation settings form used inside [NewProjectBottomSheet].
class _GenerationSettingsSection extends StatelessWidget {
  const _GenerationSettingsSection({
    required this.artStyle,
    required this.isCustomStyle,
    required this.customController,
    required this.videoSubtitles,
    required this.isDark,
    required this.onPresetSelected,
    required this.onCustomChanged,
    required this.onSubtitlesChanged,
  });

  final String artStyle;
  final bool isCustomStyle;
  final TextEditingController customController;
  final bool videoSubtitles;
  final bool isDark;
  final void Function(String?) onPresetSelected;
  final void Function(String) onCustomChanged;
  final void Function(bool) onSubtitlesChanged;

  @override
  Widget build(BuildContext context) {
    final textColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final selectedDropdownValue = isCustomStyle ? _kCustomSentinel : artStyle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Art Style', style: AppTextStyles.caption(context)),
        const SizedBox(height: AppSpacing.s2),
        DropdownButtonFormField<String>(
          initialValue: selectedDropdownValue,
          isExpanded: true,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(
              horizontal: AppSpacing.s3,
              vertical: AppSpacing.s3,
            ),
          ),
          style: AppTextStyles.body(context).copyWith(color: textColor),
          items: [
            for (final preset in kArtStylePresets)
              DropdownMenuItem(
                value: preset,
                child: Text(preset, overflow: TextOverflow.ellipsis),
              ),
            DropdownMenuItem(
              value: _kCustomSentinel,
              child: Text(
                'Custom…',
                style: AppTextStyles.body(context).copyWith(
                  color: isDark ? AppColors.primaryDark : AppColors.primaryLight,
                ),
              ),
            ),
          ],
          onChanged: onPresetSelected,
        ),
        if (isCustomStyle) ...[
          const SizedBox(height: AppSpacing.s3),
          TextField(
            controller: customController,
            maxLength: 200,
            textInputAction: TextInputAction.done,
            onChanged: onCustomChanged,
            decoration: const InputDecoration(
              hintText: 'e.g. watercolor with soft pastel tones',
              labelText: 'Custom art style',
              counterText: '',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s4),
        SwitchListTile(
          title: Text('Video Subtitles', style: AppTextStyles.body(context)),
          subtitle: Text(
            'Allow subtitle text in generated videos.',
            style: AppTextStyles.caption(context).copyWith(
              color:
                  isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
            ),
          ),
          value: videoSubtitles,
          onChanged: onSubtitlesChanged,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
