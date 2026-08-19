// =============================================================================
// services/iv/iv_storage_service.dart
// =============================================================================
// Supabase I/O for iv_snapshots table.
//
//  getHistory()      — last 252 trading days for a ticker (for IVR/IVP)
//  getLatest()       — single most-recent snapshot for a ticker
//  getLatestBatch()  — latest snapshot per ticker for watchlist view
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';
import 'iv_models.dart';

class IvStorageService {
  static final IvStorageService _i = IvStorageService._();
  IvStorageService._();
  factory IvStorageService() => _i;

  SupabaseClient get _db => Supabase.instance.client;

  /// Explicit column list for every read. Never use bare select() here.
  ///
  /// iv_snapshots carries two heavy JSONB columns that no reader on this path
  /// needs, and select=* pulled both. `rnd` is the expensive one — historical
  /// rows hold ~20 slices x 200 grid points, ~300 KB each, so a 56-row META
  /// history serialized to ~16 MB and PostgREST answered 500. IvSnapshot has no
  /// rnd field at all, so every one of those bytes was parsed and discarded.
  /// `gex_by_strike` (~5.5 KB/row) is mapped onto the model but has no reader
  /// anywhere in the app — note that gexByStrike therefore always arrives empty
  /// from this service; add the column back here if a widget ever needs it.
  static const String _columns = '''
    ticker, date, atm_iv, skew, total_gex, max_gex_strike, put_call_ratio,
    underlying_price, iv_rank, iv_percentile, iv_rank_4w, iv_percentile_4w,
    iv_rank_26w, iv_percentile_26w, iv_rating, gamma_regime, gamma_slope,
    iv_gex_signal, zero_gamma_level, spot_to_zero_gamma_pct, delta_gex,
    put_wall_density, vanna_regime, total_vex, total_cex, total_volga,
    max_vex_strike, skew_avg_52w, skew_z_score, vvol_nu
  ''';

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns up to the most recent 252 daily snapshots for [ticker],
  /// sorted ascending by date.
  ///
  /// Fetch descending then reverse: ascending + limit would return the
  /// oldest 252 days once history outgrows the window.
  Future<List<IvSnapshot>> getHistory(String ticker) async {
    final rows = await _db
        .from('iv_snapshots')
        .select(_columns)
        .eq('ticker', ticker)
        .order('date', ascending: false)
        .limit(252);

    return (rows as List).reversed
        .map((r) => IvSnapshot.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Returns the single most-recent snapshot for [ticker], or null.
  Future<IvSnapshot?> getLatest(String ticker) async {
    final rows = await _db
        .from('iv_snapshots')
        .select(_columns)
        .eq('ticker', ticker)
        .order('date', ascending: false)
        .limit(1);

    final list = rows as List;
    if (list.isEmpty) return null;
    return IvSnapshot.fromJson(list.first as Map<String, dynamic>);
  }

  /// Returns latest snapshot for each ticker in [tickers] (for watchlist view).
  /// Fires all per-ticker queries concurrently — each fetches exactly 1 row so
  /// the unbounded inFilter approach (which returns up to 252 rows × N tickers
  /// including large gex_by_strike JSONB blobs) does not blow the response limit.
  Future<Map<String, IvSnapshot>> getLatestBatch(List<String> tickers) async {
    if (tickers.isEmpty) return {};

    final snapshots = await Future.wait(tickers.map(getLatest));
    final result = <String, IvSnapshot>{};
    for (var i = 0; i < tickers.length; i++) {
      final snap = snapshots[i];
      if (snap != null) result[tickers[i]] = snap;
    }
    return result;
  }
}
