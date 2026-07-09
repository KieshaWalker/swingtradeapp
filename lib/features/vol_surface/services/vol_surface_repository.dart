// =============================================================================
// vol_surface/services/vol_surface_repository.dart
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/vol_surface_models.dart';

class VolSurfaceRepository {
  final SupabaseClient _db;
  static const _table = 'vol_surface_snapshots';

  VolSurfaceRepository(this._db);

  Future<List<VolSnapshot>> loadAll() async {
    const batchSize = 1000;
    final results = <VolSnapshot>[];
    var from = 0;
    while (true) {
      final response = await _db
          .from(_table)
          .select('id,ticker,obs_date,spot_price,parsed_at')
          .order('ticker', ascending: true)
          .order('obs_date', ascending: true)
          .range(from, from + batchSize - 1);
      final batch = (response as List<dynamic>)
          .map((r) => VolSnapshot.fromRow(r as Map<String, dynamic>))
          .toList();
      results.addAll(batch);
      if (batch.length < batchSize) break;
      from += batchSize;
    }
    return results;
  }

  /// Fetches the full `points` array for a single snapshot by id.
  Future<List<VolPoint>> loadPoints(String id) async {
    final response = await _db
        .from(_table)
        .select('points')
        .eq('id', id)
        .single();
    return (response['points'] as List)
        .map((p) => VolPoint.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(VolSnapshot snap) async {
    await _db
        .from(_table)
        .upsert(snap.toUpsertRow(), onConflict: 'user_id,ticker,obs_date');
  }
}
