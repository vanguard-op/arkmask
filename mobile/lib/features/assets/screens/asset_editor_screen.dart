import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../app.dart';
import '../../../core/jobs/generation_job_manager.dart';
import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../cubit/asset_editor_cubit.dart';
import '../cubit/asset_editor_state.dart';

/// Asset MDX Editor Screen — FEAT-010, FEAT-011, FEAT-012, FEAT-013.
///
/// Displays a single asset's `prompt.mdx` frontmatter (name, type, description)
/// and image prompt body as editable fields. Generates image prompts via
/// `/image-prompt` and reference images via `/image`.
class AssetEditorScreen extends StatelessWidget {
  const AssetEditorScreen({
    super.key,
    required this.projectName,
    required this.assetDirPath,
  });

  final String projectName;
  final String assetDirPath;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => AssetEditorCubit(
        assetDirPath: assetDirPath,
        fileService: services.fileService,
        apiClient: services.apiClient,
        jobManager: services.jobManager,
      )..load(),
      child: _AssetEditorView(
        assetDirPath: assetDirPath,
        jobManager: services.jobManager,
      ),
    );
  }
}

class _AssetEditorView extends StatelessWidget {
  const _AssetEditorView({
    required this.assetDirPath,
    required this.jobManager,
  });

  final String assetDirPath;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AssetEditorCubit, AssetEditorState>(
      listener: (context, state) {
        if (state is AssetEditorLoaded) {
          if (state.promptError != null && state.promptError != '__credits__') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.promptError!),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => context.read<AssetEditorCubit>().generatePrompt(),
                ),
              ),
            );
            context.read<AssetEditorCubit>().clearPromptError();
          }
          if (state.promptError == '__credits__') {
            showCreditsExhaustedDialog(context);
            context.read<AssetEditorCubit>().clearPromptError();
          }
          if (state.imageError != null && state.imageError != '__credits__') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.imageError!),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => context.read<AssetEditorCubit>().generateImage(),
                ),
              ),
            );
            context.read<AssetEditorCubit>().clearImageError();
          }
          if (state.imageError == '__credits__') {
            showCreditsExhaustedDialog(context);
            context.read<AssetEditorCubit>().clearImageError();
          }
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: _AssetAppBar(
            assetDirPath: assetDirPath,
            state: state,
            jobManager: jobManager,
          ),
          body: switch (state) {
            AssetEditorLoading() => const _SkeletonBody(),
            AssetEditorError(:final message) => _ErrorBody(
                message: message,
                onRetry: () => context.read<AssetEditorCubit>().load(),
              ),
            AssetEditorLoaded() => _LoadedBody(
                state: state,
                assetDirPath: assetDirPath,
                jobManager: jobManager,
              ),
          },
        );
      },
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _AssetAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _AssetAppBar({
    required this.assetDirPath,
    required this.state,
    required this.jobManager,
  });

  final String assetDirPath;
  final AssetEditorState state;
  final GenerationJobManager jobManager;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final assetName = p.basename(assetDirPath);
    final promptKey = GenerationJobManager.promptKey(assetDirPath);
    final imageKey = GenerationJobManager.imageKey(assetDirPath);

    // Filesystem-backed baseline: read from loaded state so dots survive restarts.
    final loaded = state is AssetEditorLoaded ? state as AssetEditorLoaded : null;

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () => context.pop(),
      ),
      title: Text(
        assetName,
        style: AppTextStyles.body(context).copyWith(
          fontFamily: 'JetBrains Mono',
          color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        // Step indicator: 2 dots — Prompt and Image.
        // The job manager overlays running/failed during active generation;
        // filesystem state (hasPromptBody / hasImage) is the persistent source
        // of truth so dots survive app restarts.
        ListenableBuilder(
          listenable: jobManager,
          builder: (_, child) => _StepDotsAppBar(
            promptState: _resolveState(
              jobManager.stateFor(promptKey),
              fallbackDone: loaded?.prompt.promptBody.isNotEmpty ?? false,
            ),
            imageState: _resolveState(
              jobManager.stateFor(imageKey),
              fallbackDone: loaded?.hasImage ?? false,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
      ],
    );
  }

  /// Returns [liveState] when it carries active signal (running/failed).
  /// Falls back to [done] or [idle] derived from the persisted filesystem flag.
  static GenerationJobState _resolveState(
    GenerationJobState liveState, {
    required bool fallbackDone,
  }) {
    if (liveState == GenerationJobState.running ||
        liveState == GenerationJobState.failed) {
      return liveState;
    }
    return fallbackDone ? GenerationJobState.done : GenerationJobState.idle;
  }
}

// ── 2-dot step indicator (AppBar size) ───────────────────────────────────────

class _StepDotsAppBar extends StatelessWidget {
  const _StepDotsAppBar({
    required this.promptState,
    required this.imageState,
  });

  final GenerationJobState promptState;
  final GenerationJobState imageState;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dot(state: promptState, label: 'Prompt'),
        const SizedBox(width: AppSpacing.s2),
        _Dot(state: imageState, label: 'Image'),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.state, required this.label});

  final GenerationJobState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (state) {
      GenerationJobState.idle => isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
      GenerationJobState.running => isDark ? AppColors.primaryDark : AppColors.primaryLight,
      GenerationJobState.done => isDark ? AppColors.successDark : AppColors.successLight,
      GenerationJobState.failed => isDark ? AppColors.errorDark : AppColors.errorLight,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTextStyles.caption(context).copyWith(
            fontSize: 9,
            color: color,
          ),
        ),
      ],
    );
  }
}

// ── Loaded body ───────────────────────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({
    required this.state,
    required this.assetDirPath,
    required this.jobManager,
  });

  final AssetEditorLoaded state;
  final String assetDirPath;
  final GenerationJobManager jobManager;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Reference indicator (scene-local only) ──────────────────
              if (!state.isGlobal) _ReferenceIndicatorBanner(state: state),

              // ── Frontmatter card ────────────────────────────────────────
              _FrontmatterCard(state: state),

              const SizedBox(height: AppSpacing.s4),

              // ── Prompt body section ─────────────────────────────────────
              if (!state.isPassThrough)
                _PromptBodySection(state: state, assetDirPath: assetDirPath),

              const SizedBox(height: AppSpacing.s4),

              // ── Image area ──────────────────────────────────────────────
              if (!state.isPassThrough)
                _ImageSection(state: state, assetDirPath: assetDirPath),

              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Reference indicator ───────────────────────────────────────────────────────

class _ReferenceIndicatorBanner extends StatelessWidget {
  const _ReferenceIndicatorBanner({required this.state});

  final AssetEditorLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPassThrough = state.isPassThrough;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceOverlayDark : AppColors.surfaceOverlayLight,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
      ),
      child: Row(
        children: [
          Icon(
            isPassThrough ? LucideIcons.link : LucideIcons.imageOff,
            size: AppSizing.iconSm,
            color: isPassThrough ? primaryColor : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
          ),
          const SizedBox(width: AppSpacing.s2),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s2,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: isPassThrough
                  ? primaryColor.withValues(alpha: 0.15)
                  : (isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight),
              borderRadius: BorderRadius.circular(AppSizing.radiusXs),
            ),
            child: Text(
              isPassThrough ? 'Using global image' : 'Generating variant',
              style: AppTextStyles.caption(context).copyWith(
                color: isPassThrough
                    ? primaryColor
                    : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Frontmatter card ──────────────────────────────────────────────────────────

class _FrontmatterCard extends StatefulWidget {
  const _FrontmatterCard({required this.state});

  final AssetEditorLoaded state;

  @override
  State<_FrontmatterCard> createState() => _FrontmatterCardState();
}

class _FrontmatterCardState extends State<_FrontmatterCard> {
  late final TextEditingController _descController;

  @override
  void initState() {
    super.initState();
    _descController =
        TextEditingController(text: widget.state.prompt.description);
  }

  @override
  void didUpdateWidget(_FrontmatterCard old) {
    super.didUpdateWidget(old);
    if (old.state.prompt.description != widget.state.prompt.description &&
        _descController.text != widget.state.prompt.description) {
      _descController.text = widget.state.prompt.description;
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // NAME (read-only)
          _FieldRow(
            label: 'NAME',
            child: Text(
              widget.state.prompt.name,
              style: AppTextStyles.body(context),
            ),
          ),
          Divider(height: 1, color: dividerColor),
          // TYPE (segmented selector)
          _FieldRow(
            label: 'TYPE',
            child: _TypeSelector(
              selected: widget.state.prompt.type,
              primaryColor: primaryColor,
              onChanged: (t) => context.read<AssetEditorCubit>().onTypeChanged(t),
            ),
          ),
          Divider(height: 1, color: dividerColor),
          // DESCRIPTION
          _FieldRow(
            label: 'DESCRIPTION',
            child: TextField(
              controller: _descController,
              maxLines: null,
              style: AppTextStyles.body(context),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Describe this asset\'s role and visual style...',
                hintStyle: AppTextStyles.body(context).copyWith(
                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                ),
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (_) {}, // track changes on blur only
              onEditingComplete: () {
                context
                    .read<AssetEditorCubit>()
                    .onDescriptionChanged(_descController.text);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTextStyles.caption(context).copyWith(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          child,
        ],
      ),
    );
  }
}

class _TypeSelector extends StatelessWidget {
  const _TypeSelector({
    required this.selected,
    required this.primaryColor,
    required this.onChanged,
  });

  final AssetType selected;
  final Color primaryColor;
  final ValueChanged<AssetType> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: AssetType.values.map((type) {
        final isSelected = type == selected;
        return Padding(
          padding: const EdgeInsets.only(right: AppSpacing.s2),
          child: GestureDetector(
            onTap: () => onChanged(type),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: isSelected
                    ? primaryColor.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppSizing.radiusSm),
                border: Border.all(
                  color: isSelected
                      ? primaryColor
                      : (isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight),
                ),
              ),
              child: Text(
                _label(type),
                style: AppTextStyles.bodySmall(context).copyWith(
                  color: isSelected
                      ? primaryColor
                      : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _label(AssetType type) => switch (type) {
        AssetType.character => 'Character',
        AssetType.background => 'Background',
        AssetType.object => 'Object',
      };
}

// ── Prompt body section ───────────────────────────────────────────────────────

class _PromptBodySection extends StatefulWidget {
  const _PromptBodySection({required this.state, required this.assetDirPath});

  final AssetEditorLoaded state;
  final String assetDirPath;

  @override
  State<_PromptBodySection> createState() => _PromptBodySectionState();
}

class _PromptBodySectionState extends State<_PromptBodySection> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.prompt.promptBody);
  }

  @override
  void didUpdateWidget(_PromptBodySection old) {
    super.didUpdateWidget(old);
    if (old.state.prompt.promptBody != widget.state.prompt.promptBody &&
        _controller.text != widget.state.prompt.promptBody) {
      _controller.text = widget.state.prompt.promptBody;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final s = widget.state;

    final hasBody = s.prompt.promptBody.isNotEmpty;
    final canGenerate = !s.isGeneratingPrompt && s.prompt.description.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header row
          Row(
            children: [
              Text(
                'IMAGE PROMPT',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              // Generate / Regenerate button
              _GeneratePromptButton(
                hasBody: hasBody,
                isGenerating: s.isGeneratingPrompt,
                canGenerate: canGenerate,
                primaryColor: primaryColor,
                onPressed: () async {
                  if (hasBody) {
                    final confirmed = await _confirmOverwrite(context, 'Replace the existing image prompt?');
                    if (!confirmed) return;
                  }
                  if (context.mounted) {
                    context.read<AssetEditorCubit>().generatePrompt();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          // Body text field (JetBrains Mono)
          Container(
            constraints: const BoxConstraints(minHeight: 120),
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
            child: s.isGeneratingPrompt
                ? Text(
                    'Generating prompt...',
                    style: AppTextStyles.monoBody(context).copyWith(
                      color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                : TextField(
                    controller: _controller,
                    maxLines: null,
                    style: AppTextStyles.monoBody(context),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText:
                          'No image prompt generated yet. Add a description and tap Generate Prompt.',
                      hintStyle: AppTextStyles.monoBody(context).copyWith(
                        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    onEditingComplete: () => context
                        .read<AssetEditorCubit>()
                        .onPromptBodyChanged(_controller.text),
                  ),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmOverwrite(BuildContext context, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Replace existing content?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

class _GeneratePromptButton extends StatelessWidget {
  const _GeneratePromptButton({
    required this.hasBody,
    required this.isGenerating,
    required this.canGenerate,
    required this.primaryColor,
    required this.onPressed,
  });

  final bool hasBody;
  final bool isGenerating;
  final bool canGenerate;
  final Color primaryColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: canGenerate ? onPressed : null,
      icon: isGenerating
          ? SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: primaryColor),
            )
          : Icon(LucideIcons.sparkles, size: AppSizing.iconSm, color: primaryColor),
      label: Text(
        hasBody ? 'Regenerate' : 'Generate Prompt',
        style: AppTextStyles.bodySmall(context).copyWith(color: primaryColor),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: canGenerate ? primaryColor.withValues(alpha: 0.4) : Colors.transparent),
        minimumSize: const Size(0, AppSizing.buttonSm),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        ),
      ),
    );
  }
}

// ── Image section ─────────────────────────────────────────────────────────────

class _ImageSection extends StatelessWidget {
  const _ImageSection({required this.state, required this.assetDirPath});

  final AssetEditorLoaded state;
  final String assetDirPath;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final imageFile = File(p.join(assetDirPath, 'image.png'));
    final canGenerate = !state.isGeneratingImage && state.prompt.promptBody.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image preview — tap to view fullscreen.
          if (state.hasImage && !state.isGeneratingImage)
            GestureDetector(
              onTap: () => _openFullscreen(context, imageFile),
              child: Hero(
                tag: 'asset-image-${imageFile.path}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSizing.radiusMd),
                  child: Image.file(
                    imageFile,
                    fit: BoxFit.cover,
                    height: 240,
                    width: double.infinity,
                    errorBuilder: (context, err, stack) => _ImagePlaceholder(isDark: isDark),
                  ),
                ),
              ),
            )
          else if (state.isGeneratingImage)
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
                borderRadius: BorderRadius.circular(AppSizing.radiusMd),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(
                    color: primaryColor,
                    backgroundColor: Colors.transparent,
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'Generating image...',
                    style: AppTextStyles.caption(context).copyWith(
                      color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                    ),
                  ),
                ],
              ),
            )
          else
            _ImagePlaceholder(isDark: isDark),

          const SizedBox(height: AppSpacing.s3),

          // Generate Image button
          OutlinedButton.icon(
            onPressed: canGenerate
                ? () async {
                    if (state.hasImage) {
                      final confirmed = await _confirmOverwrite(
                        context,
                        'Replace the existing reference image? This will use ${CreditCost.imageGeneration} credits.',
                      );
                      if (!confirmed) return;
                    }
                    if (context.mounted) {
                      context.read<AssetEditorCubit>().generateImage();
                    }
                  }
                : null,
            icon: Icon(LucideIcons.image, size: AppSizing.iconSm, color: primaryColor),
            label: Text(
              state.hasImage ? 'Regenerate Image' : 'Generate Image',
              style: AppTextStyles.body(context).copyWith(color: primaryColor),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: canGenerate ? primaryColor.withValues(alpha: 0.4) : Colors.transparent,
              ),
              minimumSize: const Size.fromHeight(AppSizing.buttonMd),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSizing.radiusSm),
              ),
            ),
          ),

          // Disabled tooltip helper text
          if (state.prompt.promptBody.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s1),
              child: Text(
                'Generate a prompt first to enable image generation.',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  /// Opens the generated image fullscreen with a hero animation.
  /// Pinch-to-zoom and pan are supported via [InteractiveViewer].
  void _openFullscreen(BuildContext context, File imageFile) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (context, animation, _) => FadeTransition(
          opacity: animation,
          child: _FullscreenImageViewer(imageFile: imageFile),
        ),
      ),
    );
  }

  Future<bool> _confirmOverwrite(BuildContext context, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Replace existing image?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

// ── Fullscreen image viewer ───────────────────────────────────────────────────

class _FullscreenImageViewer extends StatelessWidget {
  const _FullscreenImageViewer({required this.imageFile});

  final File imageFile;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Close on tap outside the image (the AppBar close button also works).
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Pinch-to-zoom + pan via InteractiveViewer.
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 6.0,
              child: Center(
                child: Hero(
                  tag: 'asset-image-${imageFile.path}',
                  child: Image.file(
                    imageFile,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 64,
                    ),
                  ),
                ),
              ),
            ),

            // Close button top-right.
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: GestureDetector(
                // Stop the tap bubbling up to the background dismissal detector.
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(AppSizing.radiusFull),
                  ),
                  padding: const EdgeInsets.all(AppSpacing.s2),
                  child: const Icon(LucideIcons.x, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark ? AppColors.borderDefaultDark : AppColors.borderDefaultLight,
          style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.image,
            size: AppSizing.iconLg,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'No image generated',
            style: AppTextStyles.caption(context).copyWith(
              color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Loading / Error ───────────────────────────────────────────────────────────

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        children: [
          Container(
            height: 120,
            decoration: BoxDecoration(
              color: base.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            height: 80,
            decoration: BoxDecoration(
              color: base.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: AppTextStyles.body(context)),
          const SizedBox(height: AppSpacing.s4),
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
