import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';
import '../../projects/widgets/generation_step_dots.dart';
import '../cubit/asset_editor_cubit.dart';
import '../cubit/asset_editor_state.dart';

/// Asset MDX Editor Screen — FEAT-010, FEAT-011, FEAT-012, FEAT-013.
///
/// Displays a single asset's Firestore fields (name, type, description,
/// prompt_body) as editable form fields. Generates image prompts via
/// POST /image-prompt and reference images via POST /image (async).
///
/// [projectSlug] is the immutable project slug from the `:projectName` route
/// param. [assetPath] is the URL-decoded `:assetPath` route param, e.g.
/// `"assets/abc123"` or `"scenes/xyz/assets/def456"`.
class AssetEditorScreen extends StatelessWidget {
  const AssetEditorScreen({
    super.key,
    required this.projectSlug,
    required this.assetPath,
  });

  final String projectSlug;

  /// URL-decoded Firestore sub-path for the asset document, e.g.
  /// `"assets/abc123"` or `"scenes/xyz/assets/def456"`.
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    final services = ArkMaskServices.of(context);
    return BlocProvider(
      create: (_) => AssetEditorCubit(
        projectSlug: projectSlug,
        assetFirestorePath: assetPath,
        apiClient: services.apiClient,
        jobsCubit: services.jobsCubit,
      )..load(),
      child: _AssetEditorView(projectSlug: projectSlug, assetPath: assetPath),
    );
  }
}

class _AssetEditorView extends StatelessWidget {
  const _AssetEditorView({
    required this.projectSlug,
    required this.assetPath,
  });

  final String projectSlug;
  final String assetPath;

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
                  onPressed: () =>
                      context.read<AssetEditorCubit>().generatePrompt(),
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
                  onPressed: () =>
                      context.read<AssetEditorCubit>().generateImage(),
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
          appBar: _AssetAppBar(state: state),
          body: switch (state) {
            AssetEditorLoading() => const _SkeletonBody(),
            AssetEditorError(:final message) => _ErrorBody(
                message: message,
                onRetry: () => context.read<AssetEditorCubit>().load(),
              ),
            AssetEditorLoaded() => _LoadedBody(state: state),
          },
        );
      },
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _AssetAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _AssetAppBar({required this.state});

  final AssetEditorState state;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final loaded = state is AssetEditorLoaded ? state as AssetEditorLoaded : null;

    // Derive step states directly from Firestore-backed cubit state.
    final promptStep = loaded == null
        ? GenerationStepState.pending
        : loaded.isGeneratingPrompt
            ? GenerationStepState.running
            : loaded.promptError != null
                ? GenerationStepState.failed
                : loaded.hasPromptBody
                    ? GenerationStepState.done
                    : GenerationStepState.pending;

    final imageStep = loaded == null
        ? GenerationStepState.pending
        : loaded.isGeneratingImage
            ? GenerationStepState.running
            : loaded.imageError != null
                ? GenerationStepState.failed
                : loaded.hasImage
                    ? GenerationStepState.done
                    : GenerationStepState.pending;

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.arrowLeft),
        onPressed: () => context.pop(),
      ),
      title: Text(
        loaded?.name ?? '',
        style: AppTextStyles.body(context).copyWith(
          fontFamily: 'JetBrains Mono',
          color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        GenerationStepDots(steps: [promptStep, imageStep]),
        const SizedBox(width: AppSpacing.s3),
      ],
    );
  }
}

// ── Loaded body ───────────────────────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({required this.state});

  final AssetEditorLoaded state;

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
                _PromptBodySection(state: state),

              const SizedBox(height: AppSpacing.s4),

              // ── Image area ──────────────────────────────────────────────
              if (!state.isPassThrough)
                _ImageSection(state: state),

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
            color: isPassThrough
                ? primaryColor
                : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
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
    _descController = TextEditingController(text: widget.state.description);
  }

  @override
  void didUpdateWidget(_FrontmatterCard old) {
    super.didUpdateWidget(old);
    // Sync the controller when Firestore delivers an external update and the
    // field is not currently being edited by the user.
    if (old.state.description != widget.state.description &&
        _descController.text != widget.state.description) {
      _descController.text = widget.state.description;
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
    final dividerColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;
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
          // NAME (read-only — set by backend on asset creation)
          _FieldRow(
            label: 'NAME',
            child: Text(
              widget.state.name,
              style: AppTextStyles.body(context),
            ),
          ),
          Divider(height: 1, color: dividerColor),
          // TYPE (segmented selector)
          _FieldRow(
            label: 'TYPE',
            child: _TypeSelector(
              selected: widget.state.type,
              primaryColor: primaryColor,
              onChanged: (t) =>
                  context.read<AssetEditorCubit>().onTypeChanged(t),
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
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiaryLight,
                ),
                contentPadding: EdgeInsets.zero,
              ),
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
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondaryLight,
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
                      : (isDark
                          ? AppColors.borderDefaultDark
                          : AppColors.borderDefaultLight),
                ),
              ),
              child: Text(
                _label(type),
                style: AppTextStyles.bodySmall(context).copyWith(
                  color: isSelected
                      ? primaryColor
                      : (isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight),
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
  const _PromptBodySection({required this.state});

  final AssetEditorLoaded state;

  @override
  State<_PromptBodySection> createState() => _PromptBodySectionState();
}

class _PromptBodySectionState extends State<_PromptBodySection> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.promptBody ?? '');
  }

  @override
  void didUpdateWidget(_PromptBodySection old) {
    super.didUpdateWidget(old);
    // Sync when the Firestore listener delivers a new prompt_body (e.g. after
    // generation completes) and the field is not being actively edited.
    final newBody = widget.state.promptBody ?? '';
    final oldBody = old.state.promptBody ?? '';
    if (oldBody != newBody && _controller.text != newBody) {
      _controller.text = newBody;
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

    final hasBody = s.hasPromptBody;
    final canGenerate = !s.isGeneratingPrompt && s.description.isNotEmpty;

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
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
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
                    final confirmed = await _confirmOverwrite(
                        context, 'Replace the existing image prompt?');
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
              color: isDark
                  ? AppColors.surfaceSunkenDark
                  : AppColors.surfaceSunkenLight,
              borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            ),
            child: s.isGeneratingPrompt
                ? Text(
                    'Generating prompt...',
                    style: AppTextStyles.monoBody(context).copyWith(
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiaryLight,
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
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiaryLight,
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
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: primaryColor),
            )
          : Icon(LucideIcons.sparkles, size: AppSizing.iconSm, color: primaryColor),
      label: Text(
        hasBody ? 'Regenerate' : 'Generate Prompt',
        style: AppTextStyles.bodySmall(context).copyWith(color: primaryColor),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(
            color: canGenerate
                ? primaryColor.withValues(alpha: 0.4)
                : Colors.transparent),
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
  const _ImageSection({required this.state});

  final AssetEditorLoaded state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final services = ArkMaskServices.of(context);
    final canGenerate = !state.isGeneratingImage && state.hasPromptBody;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image preview or placeholder.
          if (state.isGeneratingImage)
            _GeneratingImagePlaceholder(
                isDark: isDark, primaryColor: primaryColor)
          else if (state.hasImage)
            // Fetch a fresh presigned URL each time gcsImagePath changes.
            // ValueKey forces a new FutureBuilder when the GCS path changes
            // (new image generated), bypassing Flutter's widget diffing cache.
            FutureBuilder<String>(
              key: ValueKey(state.gcsImagePath),
              future: services.apiClient
                  .getPresignedUrl(gcsPath: state.gcsImagePath!),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _ImageLoadingPlaceholder(isDark: isDark);
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return _ImagePlaceholder(isDark: isDark);
                }
                final url = snapshot.data!;
                return GestureDetector(
                  onTap: () => _openFullscreen(context, url,
                      heroTag: 'asset-image-${state.gcsImagePath}'),
                  child: Hero(
                    tag: 'asset-image-${state.gcsImagePath}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppSizing.radiusMd),
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        height: 240,
                        width: double.infinity,
                        errorBuilder: (ctx, err, stack) =>
                            _ImagePlaceholder(isDark: isDark),
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return _ImageLoadingPlaceholder(isDark: isDark);
                        },
                      ),
                    ),
                  ),
                );
              },
            )
          else
            _ImagePlaceholder(isDark: isDark),

          const SizedBox(height: AppSpacing.s3),

          // Generate / Regenerate Image button
          OutlinedButton.icon(
            onPressed: canGenerate
                ? () async {
                    if (state.hasImage) {
                      final confirmed = await _confirmOverwrite(
                        context,
                        'Replace the existing reference image? This will use '
                        '${CreditCost.imageGeneration} credits.',
                      );
                      if (!confirmed) return;
                    }
                    if (context.mounted) {
                      context.read<AssetEditorCubit>().generateImage();
                    }
                  }
                : null,
            icon: Icon(LucideIcons.image,
                size: AppSizing.iconSm, color: primaryColor),
            label: Text(
              state.hasImage ? 'Regenerate Image' : 'Generate Image',
              style: AppTextStyles.body(context).copyWith(color: primaryColor),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: canGenerate
                    ? primaryColor.withValues(alpha: 0.4)
                    : Colors.transparent,
              ),
              minimumSize: const Size.fromHeight(AppSizing.buttonMd),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSizing.radiusSm),
              ),
            ),
          ),

          // Helper text when prompt body is absent
          if (!state.hasPromptBody)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s1),
              child: Text(
                'Generate a prompt first to enable image generation.',
                style: AppTextStyles.caption(context).copyWith(
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiaryLight,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  /// Opens the generated image fullscreen with a hero animation.
  void _openFullscreen(BuildContext context, String url,
      {required String heroTag}) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (context, animation, _) => FadeTransition(
          opacity: animation,
          child: _FullscreenImageViewer(url: url, heroTag: heroTag),
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
  const _FullscreenImageViewer({
    required this.url,
    required this.heroTag,
  });

  final String url;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 6.0,
              child: Center(
                child: Hero(
                  tag: heroTag,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (ctx, err, stack) => const Icon(
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

// ── Image placeholder widgets ─────────────────────────────────────────────────

class _GeneratingImagePlaceholder extends StatelessWidget {
  const _GeneratingImagePlaceholder({
    required this.isDark,
    required this.primaryColor,
  });

  final bool isDark;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}

class _ImageLoadingPlaceholder extends StatelessWidget {
  const _ImageLoadingPlaceholder({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSunkenDark : AppColors.surfaceSunkenLight,
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
      ),
      child: const Center(child: CircularProgressIndicator()),
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
