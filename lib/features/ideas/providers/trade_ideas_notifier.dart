// =============================================================================
// features/ideas/providers/trade_ideas_notifier.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/trade_idea.dart';

class TradeIdeasNotifier extends AsyncNotifier<List<TradeIdea>> {
  SupabaseClient get _db => Supabase.instance.client;

  @override
  Future<List<TradeIdea>> build() async {
    final rows = await _db
        .from('trade_ideas')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => TradeIdea.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> add(TradeIdea idea) async {
    await _db.from('trade_ideas').insert(idea.toJson());
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await _db.from('trade_ideas').delete().eq('id', id);
    ref.invalidateSelf();
  }
}

final tradeIdeasNotifierProvider =
    AsyncNotifierProvider<TradeIdeasNotifier, List<TradeIdea>>(
  TradeIdeasNotifier.new,
);
