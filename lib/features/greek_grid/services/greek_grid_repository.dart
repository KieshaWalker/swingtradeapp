// =============================================================================
// features/greek_grid/services/greek_grid_repository.dart
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/greek_grid_models.dart';

class GreekGridRepository {
  final SupabaseClient _db;
  GreekGridRepository(this._db);

  Future<void> upsertPoints(List<GreekGridPoint> points, String userId) async {
    if (points.isEmpty) return;
    final rows = points.map((p) => p.toUpsertRow(userId)).toList();
    await _db
        .from('greek_grid_snapshots')
        .upsert(rows, onConflict: 'user_id,ticker,obs_date,strike_band,expiry_bucket');
  }

  /// Load all historical grid points for [ticker], oldest first.
  Future<List<GreekGridPoint>> loadAll(String ticker) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];
    final rows = await _db
        .from('greek_grid_snapshots')
        .select()
        .eq('user_id', userId)
        .eq('ticker', ticker.toUpperCase())
        .order('obs_date', ascending: true);
    return (rows as List)
        .map((r) => GreekGridPoint.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Delete rows where expiry_date < today − 30 days.
  /// Returns the number of rows deleted.
  Future<int> purgeExpired(String userId) async {
    final result = await _db.rpc(
      'purge_expired_greek_grid',
      params: {'p_user_id': userId},
    );
    return (result as num?)?.toInt() ?? 0;
  }
}
