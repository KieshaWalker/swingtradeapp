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
      .order('opened_at', ascending: false);

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
      await _client.from('trades').insert({
        ...trade.toJson(),
        'user_id': user.id,
      });
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
