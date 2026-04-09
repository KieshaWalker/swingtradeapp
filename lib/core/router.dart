// =============================================================================
// core/router.dart — Navigation & route definitions
// =============================================================================
// Widgets defined here:
//   • _AppShell       — persistent scaffold with 6-tab NavigationBar;
//                       wraps every main-feature screen
//   • _AuthCallbackScreen — loading screen shown while Supabase exchanges
//                           the email-link token; auto-redirects on auth event
//
// Providers defined here:
//   • routerProvider  — GoRouter instance; consumed by App in main.dart
//
// Route map:
//   /login             → LoginScreen           (features/auth)
//   /signup            → SignupScreen          (features/auth)
//   /auth/callback     → _AuthCallbackScreen
//   /                  → SummaryScreen         (features/summary)      [home]
//   /trades            → TradesScreen          (features/trades)
//   /trades/add        → AddTradeScreen        (features/trades)
//   /trades/:id        → TradeDetailScreen     (features/trades) — extra: Trade
//   /calculator        → CalculatorScreen      (features/calculator)
//   /journal           → JournalScreen         (features/journal)
//   /journal/add       → AddJournalScreen      (features/journal)
//   /economy           → EconomyPulseScreen    (features/economy)
//   /ticker            → TickerDashboardScreen (features/ticker_profile)
//   /ticker/:symbol    → TickerProfileScreen   (features/ticker_profile) — no shell
//
// Auth guard (redirect):
//   Unauthenticated users → /login
//   Authenticated users on /login or /signup → /
//   Watches authStateProvider (features/auth/providers/auth_provider.dart)
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/signup_screen.dart';
import '../features/calculator/screens/calculator_screen.dart';
import '../features/economy/screens/economy_pulse_screen.dart';
import '../features/journal/screens/add_journal_screen.dart';
import '../features/journal/screens/journal_screen.dart';
import '../features/ticker_profile/screens/ticker_dashboard_screen.dart';
import '../features/options/screens/options_chain_screen.dart';
import '../features/options/screens/option_decision_wizard.dart';
import '../features/ticker_profile/screens/ticker_profile_screen.dart';
import '../features/trades/models/trade.dart';
import '../features/trades/screens/add_trade_screen.dart';
import '../features/trades/screens/csv_import_screen.dart';
import '../features/trades/screens/trade_blocks_screen.dart';
import '../features/trades/screens/trade_detail_screen.dart';
import '../features/trades/screens/trade_journal_screen.dart';
import '../features/trades/screens/trades_screen.dart';
import '../features/summary/screens/summary_screen.dart';
import '../features/iv/screens/iv_screen.dart';
import '../features/blotter/screens/trade_blotter_screen.dart';

// Thin shell — just provides the route transition wrapper.
// Navigation is handled by AppMenuButton in each screen's AppBar.
class _AppShell extends StatelessWidget {
  final Widget child;
  const _AppShell({required this.child});

  @override
  Widget build(BuildContext context) => child;
}


final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isAuthed = authState.valueOrNull?.session != null;
      final location = state.matchedLocation;
      final isAuthRoute = location == '/login' || location == '/signup';
      final isCallback = location == '/auth/callback';

      if (isCallback) return isAuthed ? '/' : null;
      if (!isAuthed && !isAuthRoute) return '/login';
      if (isAuthed && isAuthRoute) return '/';
      return null;
    },
    routes: [
      // Auth
      GoRoute(path: '/login', builder: (context, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (context, _) => const SignupScreen()),
      GoRoute(path: '/auth/callback', builder: (context, _) => const _AuthCallbackScreen()),

      GoRoute(
        path: '/',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: SummaryScreen()),
        ),
      ),
      GoRoute(
        path: '/trades',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: TradesScreen()),
        ),
        routes: [
          GoRoute(
            path: 'add',
            builder: (context, _) => const AddTradeScreen(),
          ),
          GoRoute(
            path: 'blocks',
            builder: (_, _) => const TradeBlocksScreen(),
          ),
          GoRoute(
            path: 'import',
            builder: (_, _) => const CsvImportScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (_, state) {
              final trade = state.extra as Trade;
              return TradeDetailScreen(trade: trade);
            },
            routes: [
              GoRoute(
                path: 'journal',
                builder: (_, state) {
                  final trade = state.extra as Trade;
                  return TradeJournalScreen(trade: trade);
                },
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/calculator',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: CalculatorScreen()),
        ),
      ),
      
      GoRoute(
        path: '/journal',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: JournalScreen()),
        ),
        routes: [
          GoRoute(
            path: 'add',
            builder: (context, _) => const AddJournalScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/economy',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: EconomyPulseScreen()),
        ),
      ),
      GoRoute(
        path: '/blotter',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: TradeBlotterScreen()),
        ),
      ),
      // Tickers — dashboard + full-screen profile (no shell)
      GoRoute(
        path: '/ticker',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: TickerDashboardScreen()),
        ),
        routes: [
          GoRoute(
            path: ':symbol',
            builder: (_, state) => TickerProfileScreen(
              symbol: state.pathParameters['symbol']!,
            ),
            routes: [
              GoRoute(
                path: 'chains',
                builder: (_, state) => OptionsChainScreen(
                  symbol: state.pathParameters['symbol']!,
                ),
                routes: [
                  GoRoute(
                    path: 'wizard',
                    builder: (_, state) => OptionDecisionWizard(
                      symbol: state.pathParameters['symbol']!,
                    ),
                  ),
                  GoRoute(
                    path: 'iv',
                    builder: (_, state) => IvScreen(
                      symbol: state.pathParameters['symbol']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

// Shown briefly while Supabase exchanges the PKCE token from the email link.
// The authStateProvider stream will fire and GoRouter will redirect to '/' automatically.
class _AuthCallbackScreen extends StatelessWidget {
  const _AuthCallbackScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Confirming your account…'),
          ],
        ),
      ),
    );
  }
}
