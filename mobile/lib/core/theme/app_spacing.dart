/// Spacing tokens from docs/ArkMask/branding.md.
/// All values are on a 4px base grid.
abstract final class AppSpacing {
  static const double s1 = 4;   // Icon-to-label gap, badge inner padding
  static const double s2 = 8;   // Tight — between related elements, chip padding
  static const double s3 = 12;  // Compact row padding (file browser items)
  static const double s4 = 16;  // Default — card inner padding, list item padding
  static const double s5 = 20;  // Section inner padding (editor toolbar, panel headers)
  static const double s6 = 24;  // Generous — between card groups, dialog padding
  static const double s8 = 32;  // Major separation — between unrelated panels
  static const double s12 = 48; // Layout-level — screen top padding, safe area buffer
}

/// Sizing tokens from docs/ArkMask/branding.md.
abstract final class AppSizing {
  // Border radii
  static const double radiusXs = 3;    // Small badges, tag chips
  static const double radiusSm = 6;    // Input fields, small buttons, thumbnail corners
  static const double radiusMd = 10;   // Cards, panels, drawers
  static const double radiusLg = 16;   // Bottom sheets, modals
  static const double radiusFull = 9999; // Avatar circles, pill buttons, progress bars

  // Touch targets
  static const double touchMin = 44;   // Minimum touch target height

  // Button heights
  static const double buttonSm = 32;   // Compact buttons (generation triggers)
  static const double buttonMd = 44;   // Standard buttons
  static const double buttonLg = 52;   // Primary CTA buttons (onboarding, export)

  // Input
  static const double inputHeight = 48;

  // Icon sizes
  static const double iconXs = 14;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 28;

  // Component-specific
  static const double fileBrowserRow = 40;
  static const double timelineTrackHeight = 72;
  static const double thumbnailAsset = 56;
  static const double thumbnailScene = 80;
}
