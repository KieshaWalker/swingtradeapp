// =============================================================================
// main.dart — App entry point
// =============================================================================
// Widgets defined here:
//   • App (ConsumerWidget) — root widget; watches routerProvider and builds
//     MaterialApp.router with AppTheme.dark applied globally
//
// Integrations:
//   • Initializes Supabase via SupabaseConfig (core/supabase_config.dart)
//   • Wraps everything in ProviderScope so all Riverpod providers are available
//   • Hands routing to routerProvider (core/router.dart)
//   • Applies dark theme from AppTheme (core/theme.dart)
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/router.dart';
import 'core/supabase_config.dart';
import 'core/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.implicit,
    ),
  );

  runApp(const ProviderScope(child: App()));
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Swing Options Trader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
