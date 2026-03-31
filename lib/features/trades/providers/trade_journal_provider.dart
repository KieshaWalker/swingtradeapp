// =============================================================================
// features/trades/providers/trade_journal_provider.dart
// =============================================================================
// journalForTradeProvider(tradeId) — FutureProvider.family
//   Fetches the single TradeJournal row for a given trade (null if not yet written).
//
// tradeJournalNotifierProvider — AsyncNotifierProvider
//   upsertJournal(journal) — insert or update trade_journal for a trade.
//   Invalidates journalForTradeProvider(tradeId) on success.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/trade_journal.dart';

final journalForTradeProvider =
    FutureProvider.family<TradeJournal?, String>((ref, tradeId) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return null;

  final rows = await client
      .from('trade_journal')
      .select()
      .eq('trade_id', tradeId)
      .eq('user_id', user.id)
      .limit(1);

  if (rows.isEmpty) return null;
  return TradeJournal.fromJson(rows.first);
});

class TradeJournalNotifier extends AsyncNotifier<void> {
  SupabaseClient get _client => ref.read(supabaseClientProvider);

  @override
  Future<void> build() async {}

  Future<void> upsertJournal(TradeJournal journal) async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _client
          .from('trade_journal')
          .upsert(journal.toUpsertJson(user.id), onConflict: 'trade_id');
      ref.invalidate(journalForTradeProvider(journal.tradeId));
    });
  }
}

final tradeJournalNotifierProvider =
    AsyncNotifierProvider<TradeJournalNotifier, void>(
        TradeJournalNotifier.new);
