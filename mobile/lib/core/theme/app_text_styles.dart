import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Typography tokens from docs/ArkMask/branding.md.
///
/// Two typefaces:
/// - [GoogleFonts.dmSans] for all UI text.
/// - [GoogleFonts.jetBrainsMono] for MDX body, file paths, and prompts.
///
/// Usage: [AppTextStyles.h1(context)] or [AppTextStyles.h1Dark].
abstract final class AppTextStyles {
  // ── DM Sans — Display / UI ─────────────────────────────────────────────────

  /// 28px / 700 / lh 1.15 / ls -0.5 — screen titles on empty/onboarding states.
  static TextStyle displayDark = GoogleFonts.dmSans(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.15,
    letterSpacing: -0.5,
    color: AppColors.textPrimaryDark,
  );

  /// 22px / 700 / lh 1.2 / ls -0.3 — section headers, project name.
  static TextStyle h1Dark = GoogleFonts.dmSans(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.3,
    color: AppColors.textPrimaryDark,
  );

  /// 18px / 600 / lh 1.3 / ls -0.2 — panel titles, card headers.
  static TextStyle h2Dark = GoogleFonts.dmSans(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.2,
    color: AppColors.textPrimaryDark,
  );

  /// 15px / 600 / lh 1.35 — asset names, scene labels.
  static TextStyle h3Dark = GoogleFonts.dmSans(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: AppColors.textPrimaryDark,
  );

  /// 16px / 400 / lh 1.5 — MDX body text, story content.
  static TextStyle bodyLargeDark = GoogleFonts.dmSans(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textPrimaryDark,
  );

  /// 14px / 400 / lh 1.5 — UI body text, list items, descriptions.
  static TextStyle bodyDark = GoogleFonts.dmSans(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textPrimaryDark,
  );

  /// 12px / 400 / lh 1.4 / ls 0.1 — captions, timestamps, helper text.
  static TextStyle bodySmallDark = GoogleFonts.dmSans(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    letterSpacing: 0.1,
    color: AppColors.textSecondaryDark,
  );

  /// 11px / 500 / lh 1.3 / ls 0.4 — ALL-CAPS labels, badges, file type tags.
  static TextStyle captionDark = GoogleFonts.dmSans(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0.4,
    color: AppColors.textSecondaryDark,
  );

  // ── JetBrains Mono — MDX body, file paths, prompts ────────────────────────

  /// 13px / 400 / lh 1.6 — prompt body in MDX editor, file paths.
  static TextStyle monoBodyDark = GoogleFonts.jetBrainsMono(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.6,
    color: AppColors.textPrimaryDark,
  );

  /// 11px / 400 / lh 1.5 — inline code, frontmatter field values.
  static TextStyle monoSmallDark = GoogleFonts.jetBrainsMono(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textPrimaryDark,
  );

  // ── Light mode variants ────────────────────────────────────────────────────

  static TextStyle displayLight = displayDark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle h1Light = h1Dark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle h2Light = h2Dark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle h3Light = h3Dark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle bodyLargeLight = bodyLargeDark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle bodyLight = bodyDark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle bodySmallLight = bodySmallDark.copyWith(color: AppColors.textSecondaryLight);
  static TextStyle captionLight = captionDark.copyWith(color: AppColors.textSecondaryLight);
  static TextStyle monoBodyLight = monoBodyDark.copyWith(color: AppColors.textPrimaryLight);
  static TextStyle monoSmallLight = monoSmallDark.copyWith(color: AppColors.textPrimaryLight);

  // ── Context-aware helpers ──────────────────────────────────────────────────
  // Returns the correct style variant based on the current theme brightness.

  static TextStyle display(BuildContext context) =>
      _isDark(context) ? displayDark : displayLight;

  static TextStyle h1(BuildContext context) =>
      _isDark(context) ? h1Dark : h1Light;

  static TextStyle h2(BuildContext context) =>
      _isDark(context) ? h2Dark : h2Light;

  static TextStyle h3(BuildContext context) =>
      _isDark(context) ? h3Dark : h3Light;

  static TextStyle bodyLarge(BuildContext context) =>
      _isDark(context) ? bodyLargeDark : bodyLargeLight;

  static TextStyle body(BuildContext context) =>
      _isDark(context) ? bodyDark : bodyLight;

  static TextStyle bodySmall(BuildContext context) =>
      _isDark(context) ? bodySmallDark : bodySmallLight;

  static TextStyle caption(BuildContext context) =>
      _isDark(context) ? captionDark : captionLight;

  static TextStyle monoBody(BuildContext context) =>
      _isDark(context) ? monoBodyDark : monoBodyLight;

  static TextStyle monoSmall(BuildContext context) =>
      _isDark(context) ? monoSmallDark : monoSmallLight;

  static bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
}
