// Values are injected at build time via --dart-define.
// Set SUPABASE_URL and SUPABASE_ANON_KEY as environment variables in Vercel.
// For local dev, run:
//   flutter run --dart-define=SUPABASE_URL=https://... --dart-define=SUPABASE_ANON_KEY=sb_...
class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://nbhjlxvofdlfcidkgnoo.supabase.co',
  );
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_Ket_RxhstMXPm_wwtdR-Sw_mVsA35tx',
  );
}
