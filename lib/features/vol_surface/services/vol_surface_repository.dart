// =============================================================================
// vol_surface/services/vol_surface_repository.dart
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/vol_surface_models.dart';

/// One cached points array plus when it was fetched.
class _CachedPoints {
  final List<VolPoint> points;
  final DateTime fetchedAt;
  const _CachedPoints(this.points, this.fetchedAt);
}

class VolSurfaceRepository {
  final SupabaseClient _db;
  static const _table = 'vol_surface_snapshots';

  /// Points cache, keyed by snapshot id.
  ///
  /// Before this existed, every selection in VolSurfaceScreen re-fetched the
  /// blob: _selectSnap() hangs the loaded points on a local _activeSnap, never
  /// back onto volSurfaceProvider, whose list always carries points: []. So
  /// AMD -> NVDA -> AMD paid for AMD twice, and each selection also pulls the
  /// previous day's snapshot for the delta grid — which the next click along
  /// then re-fetches as its own active snapshot. pg_stat_statements had
  /// `select points ... where id = $1` at 40.2% of all database time over 266
  /// calls, the single largest consumer in the database.
  ///
  /// Freshness follows the data: a snapshot for a past obs_date is immutable
  /// once the session is over, so it is cached for the life of the app. Today's
  /// row is re-upserted hourly by vol-surface-pull, so it gets a short TTL
  /// rather than being pinned to whatever the first fetch of the day returned.
  final _pointsCache = <String, _CachedPoints>{};
  static const _maxCachedSnapshots = 24;
  static const _todayTtl = Duration(minutes: 5);

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

  /// Fetches the `points` array for a single snapshot by id, memoised.
  ///
  /// Pass [obsDate] so the cache can tell an immutable historical snapshot from
  /// today's, which vol-surface-pull rewrites hourly. Without it the entry is
  /// treated as mutable and expires on the short TTL.
  Future<List<VolPoint>> loadPoints(String id, {DateTime? obsDate}) async {
    final cached = _pointsCache[id];
    if (cached != null && _isFresh(cached, obsDate)) {
      // Re-insert to mark most-recently-used for the eviction order below.
      _pointsCache.remove(id);
      _pointsCache[id] = cached;
      return cached.points;
    }

    // Read the narrow projection added in 077 — 8 keys instead of 41, ~110 KB
    // against ~752 KB, so Postgres detoasts a fraction of what it used to.
    // `points` itself is untouched and still holds every field for analysis.
    //
    // Rows written before 077's trigger have points_slim = null until 078's
    // backfill reaches them, so fall back to the full blob rather than render
    // an empty surface. Once the backfill drains, this second query stops
    // firing. VolPoint.fromJson null-casts everything except strike and dte,
    // both of which the projection always carries.
    var raw = (await _db
        .from(_table)
        .select('points_slim')
        .eq('id', id)
        .single())['points_slim'] as List?;

    raw ??= (await _db
        .from(_table)
        .select('points')
        .eq('id', id)
        .single())['points'] as List?;

    final points = (raw ?? const [])
        .map((p) => VolPoint.fromJson(p as Map<String, dynamic>))
        .toList();

    _pointsCache[id] = _CachedPoints(points, DateTime.now());
    // Dart maps preserve insertion order, so the first key is the oldest use.
    while (_pointsCache.length > _maxCachedSnapshots) {
      _pointsCache.remove(_pointsCache.keys.first);
    }
    return points;
  }

  /// Historical snapshots never change; today's is re-upserted hourly.
  bool _isFresh(_CachedPoints entry, DateTime? obsDate) {
    if (obsDate == null) {
      return DateTime.now().difference(entry.fetchedAt) < _todayTtl;
    }
    final now = DateTime.now();
    final isToday = obsDate.year == now.year &&
        obsDate.month == now.month &&
        obsDate.day == now.day;
    if (!isToday) return true;
    return now.difference(entry.fetchedAt) < _todayTtl;
  }

  Future<void> save(VolSnapshot snap) async {
    await _db
        .from(_table)
        .upsert(snap.toUpsertRow(), onConflict: 'user_id,ticker,obs_date');
    // The row this just rewrote is now stale in the cache. Its id is not known
    // here (upsert may have inserted), so drop everything rather than serve a
    // surface that no longer matches the database.
    _pointsCache.clear();
  }
}
