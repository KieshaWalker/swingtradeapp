// =============================================================================
// features/trades/providers/trades_provider.dart — Trades state management
// =============================================================================
// Providers defined here:
//
//   tradesProvider         — FutureProvider<List<Trade>>
//     Fetches all trades for current user from Supabase 'trades' table,
//     ordered by opened_at DESC.
//     Watched by: DashboardScreen, TradesScreen (_TradeList),
//                 openTradesProvider, closedTradesProvider
//
//   openTradesProvider     — Provider<AsyncValue<List<Trade>>>
//     Derived filter: status == open
//     Available for use; TradesScreen filters tradesProvider directly
//
//   closedTradesProvider   — Provider<AsyncValue<List<Trade>>>
//     Derived filter: status != open
//     Available for use; TradesScreen filters tradesProvider directly
//
//   tradesNotifierProvider — AsyncNotifierProvider<TradesNotifier, void>
//     Mutations — each method invalidates tradesProvider to refresh UI:
//       addTrade(trade)              ← called from AddTradeScreen on submit
//       closeTrade(tradeId,exitPrice)← called from TradeDetailScreen close dialog
//       deleteTrade(tradeId)         ← called from TradeDetailScreen delete dialog
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/trade.dart';

final tradesProvider = FutureProvider<List<Trade>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];

  final response = await client
      .from('trades')
      .select()
      .eq('user_id', user.id)
      .order('opened_at', ascending: true);

  return (response as List).map((e) => Trade.fromJson(e)).toList();
});

final openTradesProvider = Provider<AsyncValue<List<Trade>>>((ref) {
  return ref.watch(tradesProvider).whenData(
        (trades) => trades.where((t) => t.status == TradeStatus.open).toList(),
      );
});

final closedTradesProvider = Provider<AsyncValue<List<Trade>>>((ref) {
  return ref.watch(tradesProvider).whenData(
        (trades) => trades.where((t) => t.status != TradeStatus.open).toList(),
      );
});

class TradesNotifier extends AsyncNotifier<void> {
  SupabaseClient get _client => ref.read(supabaseClientProvider);

  @override
  Future<void> build() async {}

  Future<void> addTrade(Trade trade) async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // Core columns — guaranteed to exist (migration 001)
      final base = <String, dynamic>{
        'user_id':      user.id,
        'ticker':       trade.ticker,
        'option_type':  trade.optionType.name,
        'strategy':     trade.strategy.dbValue,
        'strike':       trade.strike,
        'expiration':   trade.toJson()['expiration'],
        'dte_at_entry': trade.dteAtEntry,
        'contracts':    trade.contracts,
        'entry_price':  trade.entryPrice,
        'status':       trade.status.name,
        if (trade.ivRank  != null) 'iv_rank': trade.ivRank,
        if (trade.delta   != null) 'delta':   trade.delta,
        if (trade.notes   != null) 'notes':   trade.notes,
      };

      final response = await _client
          .from('trades')
          .insert(base)
          .select('id')
          .single();

      // Extended columns (migration 006) — best-effort update
      final ext = <String, dynamic>{
        if (trade.priceRangeHigh      != null) 'price_range_high':      trade.priceRangeHigh,
        if (trade.priceRangeLow       != null) 'price_range_low':       trade.priceRangeLow,
        if (trade.impliedVolEntry     != null) 'implied_vol_entry':     trade.impliedVolEntry,
        if (trade.intradaySupport     != null) 'intraday_support':      trade.intradaySupport,
        if (trade.intradayResistance  != null) 'intraday_resistance':   trade.intradayResistance,
        if (trade.dailyBreakoutLevel  != null) 'daily_breakout_level':  trade.dailyBreakoutLevel,
        if (trade.dailyBreakdownLevel != null) 'daily_breakdown_level': trade.dailyBreakdownLevel,
        if (trade.entryPointType      != null) 'entry_point_type':      trade.entryPointType!.name,
        if (trade.maxLoss             != null) 'max_loss':              trade.maxLoss,
        if (trade.timeOfEntry         != null) 'time_of_entry':         trade.timeOfEntry,
        if (trade.stopLoss            != null) 'stop_loss':             trade.stopLoss,
        if (trade.takeProfit          != null) 'take_profit':           trade.takeProfit,
      };

      if (ext.isNotEmpty) {
        try {
          await _client
              .from('trades')
              .update(ext)
              .eq('id', response['id'] as String);
        } catch (_) {
          // Extended columns not yet migrated — data saved, extras skipped
        }
      }

      ref.invalidate(tradesProvider);
    });
  }

  Future<void> closeTrade({
    required String tradeId,
    required double exitPrice,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _client.from('trades').update({
        'exit_price': exitPrice,
        'status': 'closed',
        'closed_at': DateTime.now().toIso8601String(),
      }).eq('id', tradeId);
      ref.invalidate(tradesProvider);
    });
  }

  Future<void> deleteTrade(String tradeId) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _client.from('trades').delete().eq('id', tradeId);
      ref.invalidate(tradesProvider);
    });
  }
}

final tradesNotifierProvider =
    AsyncNotifierProvider<TradesNotifier, void>(TradesNotifier.new);

// ── Live mark overlay ─────────────────────────────────────────────────────────
// In-session map of tradeId → current option mid-price.
// Never written to DB — refreshed on demand, clears on app restart.

final liveMarksProvider =
    StateProvider<Map<String, double>>((ref) => {});

extension LiveMarksX on Map<String, double> {
  double? markFor(String tradeId) => this[tradeId];
}
