import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../app.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/ark_mask_symbol.dart';

/// Vault Setup Screen — lets the user choose the folder that will serve as
/// their ArkMask vault (analogous to the Obsidian vault chooser).
///
/// Shown:
/// - On first launch, before any other screen.
/// - From Settings → "Change Vault", when the user wants to move their vault.
///
/// After a vault is chosen:
/// 1. If legacy projects exist in `arkmask_projects/`, the user is offered
///    a one-time migration (copy — originals are untouched).
/// 2. [VaultService.setVaultPath] and [ProjectFileService.initialize] are called.
/// 3. Navigation proceeds to [Routes.splash].
class VaultSetupScreen extends StatefulWidget {
  /// When true the screen is shown in "change vault" mode (already configured).
  final bool isChange;

  const VaultSetupScreen({super.key, this.isChange = false});

  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen> {
  String? _selectedPath;
  bool _isWorking = false;
  String? _error;

  // ── Path selection helpers ─────────────────────────────────────────────────

  Future<void> _pickFolder() async {
    final services = ArkMaskServices.of(context);

    // On Android, request storage permission before opening the picker.
    // Without MANAGE_EXTERNAL_STORAGE the returned path cannot be written
    // via dart:io on Android 11+.
    final granted = await services.vaultService.requestStoragePermission();
    if (!granted && mounted) {
      setState(() {
        _error =
            'Storage permission is required to use a custom vault location. '
            'Please grant "All files access" in Settings and try again.';
      });
      return;
    }

    final path = await services.vaultService.pickVaultFolder();
    if (path != null && mounted) {
      setState(() {
        _selectedPath = path;
        _error = null;
      });
    }
  }

  Future<void> _useDefaultLocation() async {
    final services = ArkMaskServices.of(context);

    // Request permission so getDefaultVaultPath() can return the public
    // storage root when available; failure is non-fatal (we fall back).
    await services.vaultService.requestStoragePermission();

    final path = await services.vaultService.getDefaultVaultPath();
    if (mounted) {
      setState(() {
        _selectedPath = path;
        _error = null;
      });
    }
  }

  // ── Confirm vault ──────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    if (_selectedPath == null) return;
    setState(() {
      _isWorking = true;
      _error = null;
    });

    try {
      final services = ArkMaskServices.of(context);
      final vaultPath = _selectedPath!;

      // Create the vault directory if it doesn't exist.
      await Directory(vaultPath).create(recursive: true);

      // Commit vault path and (re)initialize the file service.
      await services.vaultService.setVaultPath(vaultPath);
      if (widget.isChange) {
        await services.fileService.reinitialize(vaultPath);
      } else {
        await services.fileService.initialize(vaultPath);
      }

      if (!mounted) return;
      // Navigate to home if already signed in, otherwise splash handles routing.
      context.go(Routes.splash);
    } catch (e) {
      if (mounted) {
        setState(() {
          // Show the real error so the user (or a bug report) knows what went
          // wrong rather than only the generic "choose a different location" copy.
          _error = 'Could not use this folder: $e';
          _isWorking = false;
        });
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final textSecondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final textTertiary =
        isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight;

    return Scaffold(
      backgroundColor:
          isDark ? AppColors.surfaceBaseDark : AppColors.surfaceBaseLight,
      appBar: widget.isChange
          ? AppBar(
              title: const Text('Change Vault'),
              leading: IconButton(
                icon: const Icon(LucideIcons.arrowLeft),
                onPressed: () => context.pop(),
              ),
            )
          : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s6,
            vertical: AppSpacing.s4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.isChange) ...[
                const Spacer(flex: 2),
                // ── Branding ────────────────────────────────────────────────
                Center(child: ArkMaskSymbol(color: primaryColor, size: 56)),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'Choose Your Vault',
                  style: AppTextStyles.h1(context),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(
                  'A vault is the folder where all your ArkMask projects '
                  'will be stored. Choose any folder on your device — '
                  'it will be accessible from your Files app.',
                  style: AppTextStyles.body(context).copyWith(
                    color: textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(flex: 1),
              ] else ...[
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'Choose a new folder to use as your vault. '
                  'Your existing projects will remain in the current location '
                  'unless you copy them.',
                  style: AppTextStyles.body(context).copyWith(
                    color: textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),
              ],

              // ── Picker buttons ─────────────────────────────────────────────
              ElevatedButton.icon(
                onPressed: _isWorking ? null : _pickFolder,
                icon: const Icon(LucideIcons.folderOpen),
                label: const Text('Choose Folder'),
              ),
              const SizedBox(height: AppSpacing.s3),
              OutlinedButton.icon(
                onPressed: _isWorking ? null : _useDefaultLocation,
                icon: const Icon(LucideIcons.home),
                label: const Text('Use Default Location'),
              ),

              const SizedBox(height: AppSpacing.s4),

              // ── Selected path display ──────────────────────────────────────
              if (_selectedPath != null) ...[
                _VaultPathCard(
                  path: _selectedPath!,
                  isDark: isDark,
                  textTertiary: textTertiary,
                ),
                const SizedBox(height: AppSpacing.s4),
              ],

              // ── Error ──────────────────────────────────────────────────────
              if (_error != null) ...[
                Text(
                  _error!,
                  style: AppTextStyles.caption(context).copyWith(
                    color: isDark ? AppColors.errorDark : AppColors.errorLight,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s3),
              ],

              // ── Confirm ────────────────────────────────────────────────────
              if (_selectedPath != null)
                _isWorking
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppSpacing.s4),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : ElevatedButton(
                        onPressed: _confirm,
                        child: Text(widget.isChange ? 'Switch Vault' : 'Open Vault'),
                      ),

              if (!widget.isChange) const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Vault path display card ────────────────────────────────────────────────────

class _VaultPathCard extends StatelessWidget {
  const _VaultPathCard({
    required this.path,
    required this.isDark,
    required this.textTertiary,
  });

  final String path;
  final bool isDark;
  final Color textTertiary;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;
    final surfaceColor =
        isDark ? AppColors.surfaceRaisedDark : AppColors.surfaceRaisedLight;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(AppSizing.radiusMd),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.folderCheck, color: primaryColor, size: AppSizing.iconMd),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(path),
                  style: AppTextStyles.body(context).copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  path,
                  style: AppTextStyles.caption(context).copyWith(
                    color: textTertiary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
