// =============================================================================
// core/app_config.dart — App deployment URL
// =============================================================================
// Used by:
//   • auth_provider.dart — emailRedirectTo on signUp (email confirmation link)
//
// Set APP_URL as an environment variable in Vercel (Build & Deployment Settings)
// alongside SUPABASE_URL and SUPABASE_ANON_KEY.
//
// For local dev:
//   flutter run --dart-define=APP_URL=http://localhost:8080 ...
// =============================================================================
class AppConfig {
  static const String appUrl = String.fromEnvironment(
    'APP_URL',
    defaultValue: 'https://swing-options-trader.vercel.app',
  );
}
