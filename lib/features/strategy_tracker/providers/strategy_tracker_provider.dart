// =============================================================================
// features/strategy_tracker/providers/strategy_tracker_provider.dart
// =============================================================================
// Providers:
//   strategyTrackerProvider     — AsyncNotifierProvider<List<StrategySetup>>
//     Loads strategy_setups from DB, then joins with tradesProvider so that
//     every trade tag or close automatically refreshes strategy stats without
//     a second network call.
//     Mutations: addSetup, updateSetup, deleteSetup
//
//   strategySetupNamesProvider  — FutureProvider<List<({String id, String name})>>
//     Lightweight id+name list for the Add Trade screen strategy dropdown.
//     Cheaper than watching the full strategyTrackerProvider there.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../features/trades/providers/trades_provider.dart';
import '../models/strategy_models.dart';

class StrategyTrackerNotifier extends AsyncNotifier<List<StrategySetup>> {
  SupabaseClient get _db => Supabase.instance.client;

  @override
  Future<List<StrategySetup>> build() async {
    // ref.watch must be called synchronously before any await so Riverpod
    // registers the dependency. When tradesProvider changes (tag, close,
    // delete), this notifier rebuilds automatically.
    final tradesValue = ref.watch(tradesProvider);

    final setupRows = await _db
        .from('strategy_setups')
        .select()
        .order('created_at', ascending: false);

    final allTrades = tradesValue.valueOrNull ?? [];
    final tagged    = allTrades.where((t) => t.strategySetupId != null).toList();

    return (setupRows as List).map((raw) {
      final j       = raw as Map<String, dynamic>;
      final id      = j['id'] as String;
      final linked  = tagged.where((t) => t.strategySetupId == id).toList();
      return StrategySetup.fromJson(j, linkedTrades: linked);
    }).toList();
  }

  Future<void> addSetup(StrategySetup setup) async {
    final user = _db.auth.currentUser;
    if (user == null) return;
    await _db.from('strategy_setups').insert({
      ...setup.toInsertJson(),
      'user_id': user.id,
    });
    ref.invalidateSelf();
    ref.invalidate(strategySetupNamesProvider);
  }

  Future<void> updateSetup(String id, StrategySetup setup) async {
    await _db
        .from('strategy_setups')
        .update(setup.toInsertJson())
        .eq('id', id);
    ref.invalidateSelf();
    ref.invalidate(strategySetupNamesProvider);
  }

  Future<void> deleteSetup(String id) async {
    await _db.from('strategy_setups').delete().eq('id', id);
    ref.invalidateSelf();
    ref.invalidate(strategySetupNamesProvider);
  }
}

final strategyTrackerProvider =
    AsyncNotifierProvider<StrategyTrackerNotifier, List<StrategySetup>>(
  StrategyTrackerNotifier.new,
);

// Lightweight provider for the Add Trade screen dropdown — just id + name.
final strategySetupNamesProvider =
    FutureProvider<List<({String id, String name})>>((ref) async {
  final client = Supabase.instance.client;
  final user   = client.auth.currentUser;
  if (user == null) return [];

  final rows = await client
      .from('strategy_setups')
      .select('id, name')
      .eq('user_id', user.id)
      .order('name', ascending: true);

  return (rows as List).map((r) {
    final m = r as Map<String, dynamic>;
    return (id: m['id'] as String, name: m['name'] as String);
  }).toList();
});
