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
  ///
  /// PostgREST caps every response at 1000 rows and truncates silently, so a
  /// single unbounded select drops the newest dates once a ticker accumulates
  /// >1000 rows (~45 trading days). Page until a short page marks the end.
  Future<List<GreekGridPoint>> loadAll(String ticker) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];
    const pageSize = 1000;
    final points = <GreekGridPoint>[];
    for (var offset = 0;; offset += pageSize) {
      final rows = await _db
          .from('greek_grid_snapshots')
          .select()
          .eq('user_id', userId)
          .eq('ticker', ticker.toUpperCase())
          .order('obs_date', ascending: true)
          .order('id', ascending: true)
          .range(offset, offset + pageSize - 1);
      points.addAll((rows as List)
          .map((r) => GreekGridPoint.fromJson(r as Map<String, dynamic>)));
      if (rows.length < pageSize) break;
    }
    return points;
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
