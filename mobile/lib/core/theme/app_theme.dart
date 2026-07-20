import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_text_styles.dart';

/// Builds the dark and light [ThemeData] for ArkMask from design tokens.
/// Dark mode is the primary experience per docs/ArkMask/branding.md.
abstract final class AppTheme {
  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final primary = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final onPrimary = isDark
        ? AppColors.primaryOnDark
        : AppColors.primaryOnLight;
    final surfaceBase = isDark
        ? AppColors.surfaceBaseDark
        : AppColors.surfaceBaseLight;
    final surfaceRaised = isDark
        ? AppColors.surfaceRaisedDark
        : AppColors.surfaceRaisedLight;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimaryLight;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondaryLight;
    final borderDefault = isDark
        ? AppColors.borderDefaultDark
        : AppColors.borderDefaultLight;
    final error = isDark ? AppColors.errorDark : AppColors.errorLight;

    final bodyStyle = isDark ? AppTextStyles.bodyDark : AppTextStyles.bodyLight;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: surfaceBase,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: onPrimary,
        secondary: primary,
        onSecondary: onPrimary,
        error: error,
        onError: onPrimary,
        surface: surfaceRaised,
        onSurface: textPrimary,
      ),
      textTheme: GoogleFonts.dmSansTextTheme(
        TextTheme(
          displayLarge: isDark
              ? AppTextStyles.displayDark
              : AppTextStyles.displayLight,
          titleLarge: isDark ? AppTextStyles.h1Dark : AppTextStyles.h1Light,
          titleMedium: isDark ? AppTextStyles.h2Dark : AppTextStyles.h2Light,
          titleSmall: isDark ? AppTextStyles.h3Dark : AppTextStyles.h3Light,
          bodyLarge: isDark
              ? AppTextStyles.bodyLargeDark
              : AppTextStyles.bodyLargeLight,
          bodyMedium: isDark ? AppTextStyles.bodyDark : AppTextStyles.bodyLight,
          bodySmall: isDark
              ? AppTextStyles.bodySmallDark
              : AppTextStyles.bodySmallLight,
          labelSmall: isDark
              ? AppTextStyles.captionDark
              : AppTextStyles.captionLight,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceBase,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: isDark ? AppTextStyles.h2Dark : AppTextStyles.h2Light,
        iconTheme: IconThemeData(color: textSecondary, size: AppSizing.iconMd),
      ),
      cardTheme: CardThemeData(
        color: surfaceRaised,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusMd),
          side: BorderSide(color: borderDefault),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          minimumSize: const Size(0, AppSizing.buttonMd),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          ),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textSecondary,
          minimumSize: const Size(0, AppSizing.buttonMd),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(0, AppSizing.buttonMd),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s2,
          ),
          side: BorderSide(color: borderDefault),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? AppColors.surfaceSunkenDark
            : AppColors.surfaceSunkenLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          borderSide: BorderSide(color: borderDefault),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          borderSide: BorderSide(color: borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
          borderSide: BorderSide(color: error),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        hintStyle: bodyStyle.copyWith(
          color: isDark
              ? AppColors.textTertiaryDark
              : AppColors.textTertiaryLight,
        ),
        constraints: const BoxConstraints(minHeight: AppSizing.inputHeight),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark
            ? AppColors.surfaceOverlayDark
            : AppColors.surfaceOverlayLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSizing.radiusLg),
          ),
        ),
        modalElevation: 0,
        showDragHandle: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark
            ? AppColors.surfaceOverlayDark
            : AppColors.surfaceOverlayLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusMd),
          side: BorderSide(
            color: isDark
                ? AppColors.borderSubtleDark
                : AppColors.borderSubtleLight,
          ),
        ),
        titleTextStyle: isDark ? AppTextStyles.h2Dark : AppTextStyles.h2Light,
        contentTextStyle: isDark
            ? AppTextStyles.bodyDark
            : AppTextStyles.bodyLight,
      ),
      dividerTheme: DividerThemeData(
        color: isDark
            ? AppColors.borderSubtleDark
            : AppColors.borderSubtleLight,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark
            ? AppColors.surfaceOverlayDark
            : AppColors.surfaceOverlayLight,
        contentTextStyle: isDark
            ? AppTextStyles.bodyDark
            : AppTextStyles.bodyLight,
        // Explicit action color — without this, SnackBarAction (e.g. the
        // "Retry" buttons scattered across the app) falls back to Material's
        // default action color, which reads too close to the snackbar's own
        // surfaceOverlay background to be legible. Primary matches every
        // other actionable-text color in the theme (buttons, links).
        actionTextColor: primary,
        disabledActionTextColor: isDark
            ? AppColors.textTertiaryDark
            : AppColors.textTertiaryLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
