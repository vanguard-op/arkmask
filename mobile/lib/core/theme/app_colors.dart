import 'package:flutter/material.dart';

/// All color tokens for ArkMask, sourced directly from docs/ArkMask/branding.md.
///
/// ArkMask is a dark-first application. Dark mode is the primary experience.
/// Never use hardcoded hex values in UI code — reference these tokens instead.
abstract final class AppColors {
  // ── Primary ────────────────────────────────────────────────────────────────

  /// Amber-gold primary: buttons, active states, selected indicators.
  static const Color primaryDark = Color(0xFFC9A047);
  static const Color primaryLight = Color(0xFFA07D28);

  static const Color primaryHoverDark = Color(0xFFDFB558);
  static const Color primaryHoverLight = Color(0xFF8A6B1E);

  /// Semi-transparent primary fill used for selected row backgrounds, chips.
  static const Color primarySubtleDark = Color(0x20C9A047);
  static const Color primarySubtleLight = Color(0x15C9A047);

  /// Text rendered on primary-colored surfaces.
  static const Color primaryOnDark = Color(0xFF111318);
  static const Color primaryOnLight = Color(0xFFFFFFFF);

  // ── Surface ────────────────────────────────────────────────────────────────

  static const Color surfaceBaseDark = Color(0xFF111318);
  static const Color surfaceBaseLight = Color(0xFFF5F4F0);

  static const Color surfaceRaisedDark = Color(0xFF1A1D24);
  static const Color surfaceRaisedLight = Color(0xFFFFFFFF);

  static const Color surfaceOverlayDark = Color(0xFF22262F);
  static const Color surfaceOverlayLight = Color(0xFFECEAE4);

  static const Color surfaceSunkenDark = Color(0xFF0C0E12);
  static const Color surfaceSunkenLight = Color(0xFFEAEAE4);

  /// Applied as an overlay (not solid) for hover states.
  static const Color surfaceHoverDark = Color(0x0AFFFFFF);
  static const Color surfaceHoverLight = Color(0x08000000);

  // ── Text ───────────────────────────────────────────────────────────────────

  static const Color textPrimaryDark = Color(0xFFF0EDE6);
  static const Color textPrimaryLight = Color(0xFF1A1A1A);

  static const Color textSecondaryDark = Color(0xFF8A8A8A);
  static const Color textSecondaryLight = Color(0xFF6B6B6B);

  static const Color textTertiaryDark = Color(0xFF555A66);
  static const Color textTertiaryLight = Color(0xFF9CA3AF);

  static const Color textOnPrimaryDark = Color(0xFF111318);
  static const Color textOnPrimaryLight = Color(0xFFFFFFFF);

  // ── Border ─────────────────────────────────────────────────────────────────

  static const Color borderSubtleDark = Color(0x0FFFFFFF);
  static const Color borderSubtleLight = Color(0x0F000000);

  static const Color borderDefaultDark = Color(0x1AFFFFFF);
  static const Color borderDefaultLight = Color(0x1A000000);

  static const Color borderStrongDark = Color(0x30FFFFFF);
  static const Color borderStrongLight = Color(0x30000000);

  // ── Semantic ───────────────────────────────────────────────────────────────

  static const Color successDark = Color(0xFF4ADE80);
  static const Color successLight = Color(0xFF16A34A);

  static const Color successSubtleDark = Color(0x184ADE80);
  static const Color successSubtleLight = Color(0x1516A34A);

  static const Color warningDark = Color(0xFFFBBF24);
  static const Color warningLight = Color(0xFFD97706);

  static const Color warningSubtleDark = Color(0x18FBBF24);
  static const Color warningSubtleLight = Color(0x15D97706);

  static const Color errorDark = Color(0xFFF87171);
  static const Color errorLight = Color(0xFFDC2626);

  static const Color errorSubtleDark = Color(0x18F87171);
  static const Color errorSubtleLight = Color(0x15DC2626);

  static const Color infoDark = Color(0xFF60A5FA);
  static const Color infoLight = Color(0xFF2563EB);

  static const Color infoSubtleDark = Color(0x1860A5FA);
  static const Color infoSubtleLight = Color(0x152563EB);

  // ── Job State ──────────────────────────────────────────────────────────────
  // Generation jobs are central to ArkMask's UX. These tokens reflect pipeline
  // state throughout the interface.

  static const Color statePendingDark = Color(0xFF555A66);
  static const Color statePendingLight = Color(0xFF9CA3AF);

  static const Color stateRunningDark = Color(0xFF60A5FA);
  static const Color stateRunningLight = Color(0xFF2563EB);

  static const Color stateDoneDark = Color(0xFF4ADE80);
  static const Color stateDoneLight = Color(0xFF16A34A);

  static const Color stateFailedDark = Color(0xFFF87171);
  static const Color stateFailedLight = Color(0xFFDC2626);

  // ── Focus / Shadow ─────────────────────────────────────────────────────────

  /// Amber glow focus ring — 3px spread, applied via BoxShadow.
  static const Color focusRingDark = Color(0x4CC9A047);  // 30% opacity
  static const Color focusRingLight = Color(0x40A07D28); // 25% opacity

  /// Scrim behind modals and bottom sheets.
  static const Color scrim = Color(0x99000000); // 60% black
}
