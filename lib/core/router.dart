// =============================================================================
// core/router.dart — Navigation & route definitions
// =============================================================================
// Widgets defined here:
//   • _AppShell       — persistent scaffold with 5-tab NavigationBar;
//                       wraps every main-feature screen
//   • _AuthCallbackScreen — loading screen shown while Supabase exchanges
//                           the email-link token; auto-redirects on auth event
//
// Providers defined here:
//   • routerProvider  — GoRouter instance; consumed by App in main.dart
//
// Route map:
//   /login             → LoginScreen      (features/auth)
//   /signup            → SignupScreen     (features/auth)
//   /auth/callback     → _AuthCallbackScreen
//   /                  → DashboardScreen  (features/dashboard)   [tab 0]
//   /trades            → TradesScreen     (features/trades)      [tab 1]
//   /trades/add        → AddTradeScreen   (features/trades)
//   /trades/:id        → TradeDetailScreen(features/trades) — receives Trade via extra
//   /calculator        → CalculatorScreen (features/calculator)  [tab 2]
//   /journal           → JournalScreen    (features/journal)     [tab 3]
//   /journal/add       → AddJournalScreen (features/journal)
//   /research          → ResearchScreen   (features/research)    [tab 4]
//   /ticker/:symbol    → TickerProfileScreen (features/ticker_profile) — no shell
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
import '../features/dashboard/screens/dashboard_screen.dart';
import '../features/journal/screens/add_journal_screen.dart';
import '../features/journal/screens/journal_screen.dart';
import '../features/research/screens/research_screen.dart';
import '../features/trades/models/trade.dart';
import '../features/trades/screens/add_trade_screen.dart';
import '../features/trades/screens/trade_detail_screen.dart';
import '../features/ticker_profile/screens/ticker_profile_screen.dart';
import '../features/trades/screens/trades_screen.dart';
import '../features/ticker_profile/screens/ticker_profile_screen.dart';
// Shell scaffold with bottom nav bar
class _AppShell extends StatelessWidget {
  final Widget child;
  final int currentIndex;

  const _AppShell({required this.child, required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF161B22),
        selectedIndex: currentIndex,
        indicatorColor: const Color(0xFF00C896).withValues(alpha: 0.2),
        onDestinationSelected: (i) {
          switch (i) {
            case 0:
              GoRouter.of(context).go('/');
            case 1:
              GoRouter.of(context).go('/trades');
            case 2:
              GoRouter.of(context).go('/calculator');
            case 3:
              GoRouter.of(context).go('/journal');
            case 4:
              GoRouter.of(context).go('/research');
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart),
            label: 'Trades',
          ),
          NavigationDestination(
            icon: Icon(Icons.calculate_outlined),
            selectedIcon: Icon(Icons.calculate),
            label: 'Calculator',
          ),
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book),
            label: 'Journal',
          ),
          NavigationDestination(
            icon: Icon(Icons.find_in_page_outlined),
            selectedIcon: Icon(Icons.find_in_page),
            label: 'Research',
          ),
        ],
      ),
    );
  }
}

int _shellIndex(String location) {
  if (location.startsWith('/trades')) return 1;
  if (location.startsWith('/calculator')) return 2;
  if (location.startsWith('/journal')) return 3;
  if (location.startsWith('/research')) return 4;
  return 0;
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

      // After Supabase exchanges the token, redirect to the desired landing page.
      // Change '/' below to any route (e.g. '/trades') to land somewhere else.
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

      // Shell routes (with bottom nav)
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppShell(
            currentIndex: _shellIndex(state.matchedLocation),
            child: const DashboardScreen(),
          ),
        ),
      ),
      GoRoute(
        path: '/trades',
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppShell(
            currentIndex: 1,
            child: const TradesScreen(),
          ),
        ),
        routes: [
          GoRoute(
            path: 'add',
            builder: (context, _) => const AddTradeScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (_, state) {
              final trade = state.extra as Trade;
              return TradeDetailScreen(trade: trade);
            },
          ),
        ],
      ),
      GoRoute(
        path: '/calculator',
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppShell(
            currentIndex: 2,
            child: const CalculatorScreen(),
          ),
        ),
      ),
      GoRoute(
        path: '/journal',
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppShell(
            currentIndex: 3,
            child: const JournalScreen(),
          ),
        ),
        routes: [
          GoRoute(
            path: 'add',
            builder: (context, _) => const AddJournalScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/research',
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppShell(
            currentIndex: 4,
            child: const ResearchScreen(),
          ),
        ),
      ),
      GoRoute(
        path: '/ticker/:symbol',
        builder: (_, state) => TickerProfileScreen(
          symbol: state.pathParameters['symbol']!,
        ),
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
