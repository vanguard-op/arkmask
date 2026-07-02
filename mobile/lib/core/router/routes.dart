/// Named route constants for GoRouter.
///
/// All navigation in ArkMask goes through named routes — never hard-coded
/// path strings in widget code. Route guards (auth, provider setup) are
/// implemented as [GoRouter.redirect] callbacks in router.dart.
abstract final class Routes {
  // ── Auth ───────────────────────────────────────────────────────────────────

  /// Splash / Welcome Screen — app entry point and auth router.
  static const String splash = '/';

  /// Registration Screen (FEAT-001).
  static const String register = '/register';

  /// Login Screen (FEAT-002, FEAT-031).
  static const String login = '/login';

  /// AI Provider Setup Screen (FEAT-003, FEAT-022).
  static const String providerSetup = '/provider-setup';

  // ── Projects ───────────────────────────────────────────────────────────────

  /// Home / Projects List Screen (FEAT-006).
  static const String home = '/home';

  /// Project File Browser Screen (FEAT-005).
  /// Path parameter: `:projectName` carries the immutable project slug
  /// (URL-encoded). Navigation always uses the slug — never the display name.
  static const String projectBrowser = '/project/:projectName';

  // ── Settings ───────────────────────────────────────────────────────────────

  /// Settings Screen (FEAT-022, FEAT-023, FEAT-025).
  static const String settings = '/settings';

  /// Usage Dashboard Screen (FEAT-024).
  static const String usage = '/settings/usage';

  /// Upgrade / Paywall Screen.
  static const String upgrade = '/upgrade';

  /// Billing return screen — the target of Stripe Checkout's success_url /
  /// cancel_url and the Customer Portal's return_url (see
  /// backend/app/config.py), all set to `arkmask://billing-return?status=...`.
  /// Stripe Checkout/Portal is opened in the system browser
  /// (LaunchMode.externalApplication — see upgrade_screen.dart), so a plain
  /// https URL can't hand control back to the app; this custom-scheme deep
  /// link can (see the arkmask:// intent-filter / CFBundleURLTypes entries
  /// in AndroidManifest.xml / Info.plist). Distinguishes success/cancel/
  /// portal via the `status` query parameter.
  static const String billingReturn = '/billing-return';

  // ── Editor screens (Phase 2+) — declared here as stubs for router skeleton ─

  static const String storyEditor = '/project/:projectName/story';
  static const String assetEditor = '/project/:projectName/asset/:assetPath';
  static const String sceneDetail = '/project/:projectName/scene/:sceneId';
  static const String videoEditor = '/project/:projectName/editor';
  static const String videoPlayer = '/player';
}
