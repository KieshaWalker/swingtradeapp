// =============================================================================
// features/auth/providers/auth_provider.dart — Auth state & actions
// =============================================================================
// Providers defined here:
//
//   supabaseClientProvider  — SupabaseClient singleton; read by tradesProvider,
//                             journalProvider, TradesNotifier, JournalNotifier
//
//   authStateProvider       — Stream<AuthState>; watched by routerProvider
//                             (core/router.dart) to trigger auth redirects
//
//   currentUserProvider     — Current User?; read in AddTradeScreen and
//                             AddJournalScreen to attach user_id on insert
//
//   authNotifierProvider    — AuthNotifier (AsyncNotifier); provides:
//       signUp(email, pw) → called from SignupScreen
//       signIn(email, pw) → called from LoginScreen
//       signOut()         → called from DashboardScreen logout button
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseClientProvider).auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(supabaseClientProvider).auth.currentUser;
});

class AuthNotifier extends AsyncNotifier<void> {
  SupabaseClient get _client => ref.read(supabaseClientProvider);

  @override
  Future<void> build() async {}

  Future<void> signUp({required String email, required String password}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => _client.auth.signUp(email: email, password: password),
    );
  }

  Future<void> signIn({required String email, required String password}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => _client.auth.signInWithPassword(email: email, password: password),
    );
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _client.auth.signOut());
  }
}

final authNotifierProvider =
    AsyncNotifierProvider<AuthNotifier, void>(AuthNotifier.new);
