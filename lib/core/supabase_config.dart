// Values are injected at build time via --dart-define.
// Set SUPABASE_URL and SUPABASE_ANON_KEY as environment variables in Vercel.
// For local dev, run:
//   flutter run --dart-define=SUPABASE_URL=https://... --dart-define=SUPABASE_ANON_KEY=sb_...
// =============================================================================
// core/supabase_config.dart — Supabase project credentials
// =============================================================================
// Consumed by:
//   • main.dart — Supabase.initialize() on app startup
//   • auth_provider.dart — supabaseClientProvider reads the initialized instance
//
// Supabase tables used:
//   • trades          — read/write by tradesProvider & TradesNotifier
//   • journal_entries — read/write by journalProvider & JournalNotifier
//   • auth.users      — managed by Supabase Auth (authNotifierProvider)
// =============================================================================
class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://hnuokvosmgmkzpetimtm.supabase.co',
  );
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhudW9rdm9zbWdta3pwZXRpbXRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQwMjY2NDUsImV4cCI6MjA4OTYwMjY0NX0.tl3lTUEh_hG0c0BG3zy_Yq70lbqv_TJcRUl_QsvfT0Q',
  );
}
