// =============================================================================
// services/iv/expected_move_repository.dart
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import 'expected_move_models.dart';

class ExpectedMoveRepository {
  SupabaseClient get _db => Supabase.instance.client;
  static const _table = 'expected_move_snapshots';

  Future<List<ExpectedMoveSnapshot>> getHistory(
    String ticker, {
    required String periodType,
    int limit = 90,
  }) async {
    final rows = await _db
        .from(_table)
        .select()
        .eq('ticker', ticker.toUpperCase())
        .eq('period_type', periodType)
        .order('date', ascending: true)
        .limit(limit);
    return (rows as List)
        .map((r) => ExpectedMoveSnapshot.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<ExpectedMoveSnapshot?> getLatest(
    String ticker, {
    String periodType = 'daily',
  }) async {
    final rows = await _db
        .from(_table)
        .select()
        .eq('ticker', ticker.toUpperCase())
        .eq('period_type', periodType)
        .order('date', ascending: false)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    return ExpectedMoveSnapshot.fromJson(list.first as Map<String, dynamic>);
  }
}
