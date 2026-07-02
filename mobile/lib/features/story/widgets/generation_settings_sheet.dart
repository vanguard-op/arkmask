import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../cubit/story_cubit.dart';
import '../cubit/story_state.dart';

/// Bottom sheet for viewing and editing a project's [GenerationSettings].
///
/// Opened from the story editor AppBar. Changes are saved immediately via
/// [StoryCubit.updateGenerationSettings] which writes to the Firestore project
/// document — the backend reads these values when `/image-prompt` and
/// `/video-prompt` are called.
class GenerationSettingsSheet extends StatefulWidget {
  const GenerationSettingsSheet({
    super.key,
    required this.initial,
    required this.onSave,
  });

  /// The current settings to pre-populate the form.
  final GenerationSettings initial;

  /// Called with the updated [GenerationSettings] when the user taps "Apply".
  final void Function(GenerationSettings) onSave;

  @override
  State<GenerationSettingsSheet> createState() =>
      _GenerationSettingsSheetState();
}

class _GenerationSettingsSheetState extends State<GenerationSettingsSheet> {
  late String _artStyle;
  late bool _videoSubtitles;

  /// Tracks whether the user has selected the "Custom" option and is entering
  /// a free-form style string.
  bool _isCustomStyle = false;
  late final TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _artStyle = widget.initial.artStyle;
    _videoSubtitles = widget.initial.videoSubtitles;

    // Determine if the current value is a preset or a custom string.
    _isCustomStyle = !kArtStylePresets.contains(_artStyle);
    _customController = TextEditingController(
      text: _isCustomStyle ? _artStyle : '',
    );
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _onPresetSelected(String? value) {
    if (value == null) return;
    if (value == _kCustomSentinel) {
      setState(() {
        _isCustomStyle = true;
        // Seed the text field with the current value so it's easy to edit.
        if (!kArtStylePresets.contains(_artStyle)) {
          _customController.text = _artStyle;
        } else {
          _customController.clear();
        }
        _artStyle = _customController.text;
      });
    } else {
      setState(() {
        _isCustomStyle = false;
        _artStyle = value;
      });
    }
  }

  void _onCustomChanged(String value) {
    setState(() => _artStyle = value.trim().isEmpty ? kDefaultArtStyle : value.trim());
  }

  void _apply() {
    final effective = _isCustomStyle
        ? (_customController.text.trim().isEmpty
            ? kDefaultArtStyle
            : _customController.text.trim())
        : _artStyle;

    widget.onSave(GenerationSettings(
      artStyle: effective,
      videoSubtitles: _videoSubtitles,
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      // Lift the sheet above the keyboard when the custom text field is focused.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color:
              isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
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
            // ── Handle bar ──────────────────────────────────────────────────
            const SizedBox(height: AppSpacing.s3),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.borderStrongDark
                      : AppColors.borderStrongLight,
                  borderRadius:
                      BorderRadius.circular(AppSizing.radiusFull),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s5),

            // ── Title ────────────────────────────────────────────────────────
            Text('Generation Settings', style: AppTextStyles.h2(context)),
            const SizedBox(height: AppSpacing.s1),
            Text(
              'Controls the visual style for all image and video generation in this project.',
              style: AppTextStyles.caption(context).copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.s5),

            // ── Art Style ────────────────────────────────────────────────────
            Text('Art Style', style: AppTextStyles.caption(context)),
            const SizedBox(height: AppSpacing.s2),
            _ArtStyleDropdown(
              selectedPreset: _isCustomStyle ? _kCustomSentinel : _artStyle,
              onChanged: _onPresetSelected,
              isDark: isDark,
            ),

            // Custom style text field — shown only when "Custom" is selected.
            if (_isCustomStyle) ...[
              const SizedBox(height: AppSpacing.s3),
              TextField(
                controller: _customController,
                autofocus: true,
                maxLength: 200,
                textInputAction: TextInputAction.done,
                onChanged: _onCustomChanged,
                decoration: const InputDecoration(
                  hintText: 'e.g. watercolor with soft pastel tones',
                  labelText: 'Custom art style',
                  counterText: '',
                ),
              ),
            ],

            const SizedBox(height: AppSpacing.s5),

            // ── Subtitles toggle ─────────────────────────────────────────────
            _SubtitlesToggle(
              value: _videoSubtitles,
              onChanged: (v) => setState(() => _videoSubtitles = v),
              isDark: isDark,
            ),

            const SizedBox(height: AppSpacing.s6),

            // ── Apply button ─────────────────────────────────────────────────
            ElevatedButton(
              onPressed: _apply,
              child: const Text('Apply'),
            ),
            const SizedBox(height: AppSpacing.s6),
          ],
        ),
        ),
      ),
    );
  }
}

/// Sentinel value used in the dropdown to represent the "Custom..." option.
const _kCustomSentinel = '__custom__';

class _ArtStyleDropdown extends StatelessWidget {
  const _ArtStyleDropdown({
    required this.selectedPreset,
    required this.onChanged,
    required this.isDark,
  });

  final String selectedPreset;
  final void Function(String?) onChanged;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;

    return DropdownButtonFormField<String>(
      initialValue: selectedPreset,
      isExpanded: true,
      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      )),
      style: AppTextStyles.body(context).copyWith(color: textColor),
      items: [
        // Preset options
        for (final preset in kArtStylePresets)
          DropdownMenuItem(
            value: preset,
            child: Text(preset, overflow: TextOverflow.ellipsis),
          ),
        // Custom option — always last
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
      onChanged: onChanged,
    );
  }
}

class _SubtitlesToggle extends StatelessWidget {
  const _SubtitlesToggle({
    required this.value,
    required this.onChanged,
    required this.isDark,
  });

  final bool value;
  final void Function(bool) onChanged;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight,
        ),
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
      ),
      child: SwitchListTile(
        title: Text('Video Subtitles', style: AppTextStyles.body(context)),
        subtitle: Text(
          value
              ? 'Subtitles are allowed — use 【text】 in scene descriptions.'
              : 'Subtitles are suppressed in all generated videos.',
          style: AppTextStyles.caption(context).copyWith(
            color:
                isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
          ),
        ),
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s1,
        ),
      ),
    );
  }
}

/// Opens [GenerationSettingsSheet] as a modal bottom sheet.
///
/// Reads the current [GenerationSettings] from [StoryCubit] state and saves
/// changes back via [StoryCubit.updateGenerationSettings].
void showGenerationSettingsSheet(BuildContext context) {
  final state = context.read<StoryCubit>().state;
  if (state is! StoryLoaded) return;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GenerationSettingsSheet(
      initial: state.generationSettings,
      onSave: (updated) {
        if (context.mounted) {
          context.read<StoryCubit>().updateGenerationSettings(updated);
        }
      },
    ),
  );
}
