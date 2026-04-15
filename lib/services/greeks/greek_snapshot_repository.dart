// =============================================================================
// services/greeks/greek_snapshot_repository.dart
// =============================================================================
// Supabase I/O for greek_snapshots table.
//
// SQL (run once in Supabase SQL editor):
// ─────────────────────────────────────────────────────────────────────────────
// -- Drop old table if upgrading from single-bucket schema:
// -- drop table if exists greek_snapshots;
//
// create table greek_snapshots (
//   id             uuid primary key default gen_random_uuid(),
//   user_id        uuid references auth.users not null,
//   ticker         text not null,
//   obs_date       date not null,
//   dte_bucket     int  not null default 31,   -- 4 | 7 | 31
//   underlying_price float8 not null,
//   call_strike    float8, call_dte int,
//   call_delta     float8, call_gamma float8,
//   call_theta     float8, call_vega  float8,
//   call_rho       float8, call_iv    float8, call_oi int,
//   put_strike     float8, put_dte  int,
//   put_delta      float8, put_gamma  float8,
//   put_theta      float8, put_vega   float8,
//   put_rho        float8, put_iv     float8, put_oi  int,
//   persisted_at   timestamptz default now(),
//   unique(user_id, ticker, obs_date, dte_bucket)
// );
// alter table greek_snapshots enable row level security;
// create policy "Users manage own greek snapshots"
//   on greek_snapshots for all using (auth.uid() = user_id);
// ─────────────────────────────────────────────────────────────────────────────
import 'package:supabase_flutter/supabase_flutter.dart';
import 'greek_snapshot_models.dart';

class GreekSnapshotRepository {
  final SupabaseClient _db;
  const GreekSnapshotRepository(this._db);

  static const _table = 'greek_snapshots';

  /// Upsert today's ATM greek snapshot for a ticker + DTE bucket.
  Future<void> save(GreekSnapshot snap) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    await _db.from(_table).upsert(
      snap.toJson(userId),
      onConflict: 'user_id,ticker,obs_date,dte_bucket',
    );
  }

  /// Load history for a ticker + DTE bucket, newest first.
  Future<List<GreekSnapshot>> getHistory(
    String ticker, {
    required int dteBucket,
    int limit = 90,
  }) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];
    final rows = await _db
        .from(_table)
        .select()
        .eq('user_id', userId)
        .eq('ticker', ticker.toUpperCase())
        .eq('dte_bucket', dteBucket)
        .order('obs_date', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => GreekSnapshot.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}
