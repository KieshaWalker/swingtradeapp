// =============================================================================
// features/ticker_profile/providers/ticker_profile_notifier.dart
// =============================================================================
// Tier 4 — AsyncNotifier mutations for the Ticker Profile feature.
//
// tickerProfileNotifierProvider — TickerProfileNotifier
//   Methods (each invalidates the relevant Tier-1 provider):
//     addNote(symbol, body, tags)
//     deleteNote(noteId, symbol)
//     addSRLevel(symbol, SupportResistanceLevel)
//     invalidateSRLevel(levelId, symbol, note)
//     addInsiderBuy(symbol, TickerInsiderBuy)
//     deleteInsiderBuy(buyId, symbol)
//     upsertEarningsReaction(symbol, TickerEarningsReaction)
//     deleteEarningsReaction(reactionId, symbol)
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/ticker_profile_models.dart';
import 'ticker_profile_providers.dart';

class TickerProfileNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  // ─── Watched tickers ───────────────────────────────────────────────────────

  Future<void> addWatchedTicker(String ticker) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    await client.from('watched_tickers').upsert(
      {'user_id': user.id, 'ticker': ticker.toUpperCase()},
      onConflict: 'user_id,ticker',
    );
    ref.invalidate(watchedTickersProvider);
  }

  Future<void> removeWatchedTicker(String ticker) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    await client
        .from('watched_tickers')
        .delete()
        .eq('user_id', user.id)
        .eq('ticker', ticker.toUpperCase());
    ref.invalidate(watchedTickersProvider);
  }

  // ─── Notes ─────────────────────────────────────────────────────────────────

  Future<void> addNote(String symbol, String body, List<String> tags) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_profile_notes').insert({
        'user_id': user.id,
        'ticker': symbol.toUpperCase(),
        'body': body,
        'tags': tags,
      });
      ref.invalidate(tickerNotesProvider(symbol));
    });
  }

  Future<void> deleteNote(String noteId, String symbol) async {
    final client = ref.read(supabaseClientProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client
          .from('ticker_profile_notes')
          .delete()
          .eq('id', noteId);
      ref.invalidate(tickerNotesProvider(symbol));
    });
  }

  // ─── S/R Levels ────────────────────────────────────────────────────────────

  Future<void> addSRLevel(
      String symbol, SupportResistanceLevel level) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_support_resistance').insert({
        'user_id': user.id,
        ...level.toJson(),
      });
      ref.invalidate(tickerSRLevelsProvider(symbol));
    });
  }

  Future<void> invalidateSRLevel(
      String levelId, String symbol, String? invalidationNote) async {
    final client = ref.read(supabaseClientProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_support_resistance').update({
        'invalidated_at': DateTime.now().toIso8601String(),
        'invalidation_note': invalidationNote,
      }).eq('id', levelId);
      ref.invalidate(tickerSRLevelsProvider(symbol));
    });
  }

  // ─── Insider Buys ──────────────────────────────────────────────────────────

  Future<void> addInsiderBuy(String symbol, TickerInsiderBuy buy) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_insider_buys').insert({
        'user_id': user.id,
        ...buy.toJson(),
      });
      ref.invalidate(tickerInsiderBuysProvider(symbol));
    });
  }

  Future<void> addInsiderBuys(
      String symbol, List<TickerInsiderBuy> buys) async {
    if (buys.isEmpty) return;
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_insider_buys').insert(
            buys.map((b) => {'user_id': user.id, ...b.toJson()}).toList(),
          );
      ref.invalidate(tickerInsiderBuysProvider(symbol));
    });
  }

  Future<void> deleteInsiderBuy(String buyId, String symbol) async {
    final client = ref.read(supabaseClientProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client
          .from('ticker_insider_buys')
          .delete()
          .eq('id', buyId);
      ref.invalidate(tickerInsiderBuysProvider(symbol));
    });
  }

  // ─── Earnings Reactions ────────────────────────────────────────────────────

  Future<void> upsertEarningsReaction(
      String symbol, TickerEarningsReaction reaction) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('ticker_earnings_reactions').upsert(
        {
          'user_id': user.id,
          ...reaction.toJson(),
        },
        onConflict: 'user_id,ticker,earnings_date',
      );
      ref.invalidate(tickerEarningsReactionsProvider(symbol));
    });
  }

  Future<void> deleteEarningsReaction(
      String reactionId, String symbol) async {
    final client = ref.read(supabaseClientProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client
          .from('ticker_earnings_reactions')
          .delete()
          .eq('id', reactionId);
      ref.invalidate(tickerEarningsReactionsProvider(symbol));
    });
  }
}

final tickerProfileNotifierProvider =
    AsyncNotifierProvider<TickerProfileNotifier, void>(
        TickerProfileNotifier.new);
