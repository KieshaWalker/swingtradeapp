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
    final response = await _db
        .from(_table)
        .select('id,ticker,obs_date,spot_price,points,parsed_at')
        .order('ticker', ascending: true)
        .order('obs_date', ascending: true);
    return (response as List<dynamic>)
        .map((r) => VolSnapshot.fromRow(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(VolSnapshot snap) async {
    await _db
        .from(_table)
        .upsert(snap.toUpsertRow(), onConflict: 'user_id,ticker,obs_date');
  }

  Future<void> delete(VolSnapshot snap) async {
    await _db
        .from(_table)
        .delete()
        .eq('ticker', snap.ticker)
        .eq('obs_date', snap.obsDateStr);
  }

  Future<void> deleteByTicker(String ticker) async {
    await _db.from(_table).delete().eq('ticker', ticker);
  }
}
