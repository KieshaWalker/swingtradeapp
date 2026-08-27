// =============================================================================
// core/router.dart — Navigation & route definitions
// =============================================================================
// Widgets defined here:
//   • _AppShell           — thin shell; wraps every main-feature screen
//   • _AuthCallbackScreen — loading screen shown while Supabase exchanges
//                           the email-link token; auto-redirects on auth event
//
// Providers defined here:
//   • routerProvider  — GoRouter instance; consumed by App in main.dart
//
// Route map:
//   /login                → LoginScreen           (features/auth)
//   /signup               → SignupScreen          (features/auth)
//   /auth/callback        → _AuthCallbackScreen
//   /settings/schwab-auth → SchwabBootstrapScreen (features/settings)
//   /                     → SummaryScreen         (features/summary)   [home]
//   /trades               → TradesScreen          (features/trades)
//   /trades/add           → AddTradeScreen        (features/trades)
//   /trades/blocks        → TradeBlocksScreen     (features/trades)
//   /trades/import        → CsvImportScreen       (features/trades)
//   /trades/:id           → TradeDetailScreen     (features/trades) — extra: Trade
//   /trades/:id/journal   → TradeJournalScreen    (features/trades) — extra: Trade
//   /calculator           → CalculatorScreen      (features/calculator)
//   /economy              → EconomyPulseScreen    (features/economy)
//   /vol-surface          → VolSurfaceScreen      (features/vol_surface, global)
//   /macro                → MacroScoreScreen      (features/macro)
//   /macro/iv-crush       → IvCrushTrackerScreen  (features/macro)
//   /positions            → PositionsScreen       (features/positions)
//   /trend-lines          → TrendLinesScreen      (features/trend_lines)
//   /ticker               → TickerDashboardScreen (features/ticker_profile)
//   /ticker/:symbol       → TickerProfileScreen   (features/ticker_profile) — no shell
//     …/chains            → OptionsChainScreen    (features/options)
//     …/chains/wizard     → OptionDecisionWizard  (features/options)
//     …/chains/iv         → IvScreen              (features/iv)
//     …/chains/greeks     → GreekChartScreen      (features/options)
//     …/greek-grid        → GreekGridScreen       (features/greek_grid)
//     …/vol-surface       → VolSurfaceScreen      (features/vol_surface, scoped)
//
// Auth guard (redirect):
//   Unauthenticated users → /login
//   Authenticated users on /login or /signup → /
//   Uses _RouterNotifier + refreshListenable so GoRouter is never recreated
//   on auth events (prevents navigation reset to initialLocation on token refresh).
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/signup_screen.dart';
import '../features/calculator/screens/calculator_screen.dart';
import '../features/economy/screens/economy_pulse_screen.dart';
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
import '../features/options/screens/greek_chart_screen.dart';
import '../features/vol_surface/screens/vol_surface_screen.dart';
import '../features/greek_grid/screens/greek_grid_screen.dart';
import '../features/settings/screens/schwab_bootstrap_screen.dart';
import '../features/macro/screens/macro_score_screen.dart';
import '../features/macro/screens/iv_crush_tracker_screen.dart';
import '../features/positions/screens/positions_screen.dart';
import '../features/trend_lines/screens/trend_lines_screen.dart';

// =============================================================================
// _RouterNotifier
// =============================================================================
// Bridges Riverpod auth state into GoRouter's refreshListenable.
//
// WHY: if routerProvider used ref.watch(authStateProvider), the entire GoRouter
// instance would be recreated on every Supabase auth event (token refresh,
// session ping, etc.), which resets navigation to initialLocation: '/'.
// Using ref.listen + ChangeNotifier means GoRouter is created ONCE and only
// re-evaluates the redirect function when auth state changes — navigation
// history is preserved.
class _RouterNotifier extends ChangeNotifier {
  final Ref _ref;

  _RouterNotifier(this._ref) {
    _ref.listen<AsyncValue<dynamic>>(authStateProvider, (_, _) {
      notifyListeners();
    });
  }

  String? redirect(BuildContext context, GoRouterState state) {
    final authState   = _ref.read(authStateProvider);
    final isAuthed    = authState.valueOrNull?.session != null;
    final location    = state.matchedLocation;
    final isAuthRoute = location == '/login' || location == '/signup';
    final isCallback  = location == '/auth/callback';

    if (isCallback) return isAuthed ? '/' : null;
    if (!isAuthed && !isAuthRoute) return '/login';
    if (isAuthed && isAuthRoute) return '/';
    return null;
  }
}

// =============================================================================
// _AppShell
// =============================================================================
// Thin shell — just provides the route transition wrapper.
// Navigation is handled by AppMenuButton in each screen's AppBar.
class _AppShell extends StatelessWidget {
  final Widget child;
  const _AppShell({required this.child});

  @override
  Widget build(BuildContext context) => child;
}

// =============================================================================
// routerProvider
// =============================================================================
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);

  return GoRouter(
    initialLocation:    '/',
    refreshListenable:  notifier,
    redirect:           notifier.redirect,
    routes: [
      GoRoute(
        path: '/settings/schwab-auth',
        builder: (_, _) => const SchwabBootstrapScreen(),
      ),

      // Auth
      GoRoute(path: '/login',  builder: (context, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (context, _) => const SignupScreen()),
      GoRoute(
        path: '/auth/callback',
        builder: (context, _) => const _AuthCallbackScreen(),
      ),

      GoRoute(
        path: '/',
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: _AppShell(child: SummaryScreen())),
      ),
      GoRoute(
        path: '/trades',
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: _AppShell(child: TradesScreen())),
        routes: [
          GoRoute(path: 'add',    builder: (context, _) => const AddTradeScreen()),
          GoRoute(path: 'blocks', builder: (_, _) => const TradeBlocksScreen()),
          GoRoute(path: 'import', builder: (_, _) => const CsvImportScreen()),
          GoRoute(
            path: ':id',
            // These screens need the Trade passed via `extra`, which doesn't
            // survive a browser refresh / direct deep link — fall back to the
            // trades list instead of crashing on the null cast.
            redirect: (_, state) => state.extra == null ? '/trades' : null,
            builder: (_, state) {
              final trade = state.extra as Trade;
              return TradeDetailScreen(trade: trade);
            },
            routes: [
              GoRoute(
                path: 'journal',
                redirect: (_, state) => state.extra == null ? '/trades' : null,
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
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: _AppShell(child: CalculatorScreen())),
      ),
      GoRoute(
        path: '/economy',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: EconomyPulseScreen()),
        ),
      ),
      // Global multi-ticker vol surface (no symbol). Linked from the vol
      // surface panel; the per-ticker view lives under /ticker/:symbol.
      GoRoute(
        path: '/vol-surface',
        builder: (_, _) => const VolSurfaceScreen(),
      ),
      // Macro score detail — linked from the Home macro card and the
      // economic phase panel.
      GoRoute(
        path: '/macro',
        builder: (_, _) => const MacroScoreScreen(),
        routes: [
          GoRoute(
            path: 'iv-crush',
            builder: (_, _) => const IvCrushTrackerScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/positions',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: PositionsScreen()),
        ),
      ),

      GoRoute(
        path: '/trend-lines',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: _AppShell(child: TrendLinesScreen()),
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
            builder: (_, state) =>
                TickerProfileScreen(symbol: state.pathParameters['symbol']!),
            routes: [
              GoRoute(
                path: 'chains',
                builder: (_, state) =>
                    OptionsChainScreen(symbol: state.pathParameters['symbol']!),
                routes: [
                  GoRoute(
                    path: 'wizard',
                    builder: (_, state) => OptionDecisionWizard(
                      symbol: state.pathParameters['symbol']!,
                    ),
                  ),
                  GoRoute(
                    path: 'iv',
                    builder: (_, state) =>
                        IvScreen(symbol: state.pathParameters['symbol']!),
                  ),
                  GoRoute(
                    path: 'greeks',
                    builder: (_, state) => GreekChartScreen(
                      symbol: state.pathParameters['symbol']!,
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'greek-grid',
                builder: (_, state) => GreekGridScreen(
                  symbol: state.pathParameters['symbol']!,
                ),
              ),
              GoRoute(
                path: 'vol-surface',
                builder: (_, state) => VolSurfaceScreen(
                  symbol: state.pathParameters['symbol']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

// =============================================================================
// _AuthCallbackScreen
// =============================================================================
// Shown briefly while Supabase exchanges the PKCE token from the email link.
// _RouterNotifier will fire notifyListeners() and GoRouter will redirect to '/'.
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
