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

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns up to 252 daily snapshots for [ticker], sorted ascending by date.
  Future<List<IvSnapshot>> getHistory(String ticker) async {
    final rows = await _db
        .from('iv_snapshots')
        .select()
        .eq('ticker', ticker)
        .order('date', ascending: true)
        .limit(252);

    return (rows as List)
        .map((r) => IvSnapshot.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Returns the single most-recent snapshot for [ticker], or null.
  Future<IvSnapshot?> getLatest(String ticker) async {
    final rows = await _db
        .from('iv_snapshots')
        .select()
        .eq('ticker', ticker)
        .order('date', ascending: false)
        .limit(1);

    final list = rows as List;
    if (list.isEmpty) return null;
    return IvSnapshot.fromJson(list.first as Map<String, dynamic>);
  }

  /// Returns latest snapshot for each ticker in [tickers] (for watchlist view).
  Future<Map<String, IvSnapshot>> getLatestBatch(List<String> tickers) async {
    if (tickers.isEmpty) return {};

    final snapshots = await Future.wait(tickers.map(getLatest));
    return {
      for (var i = 0; i < tickers.length; i++)
        if (snapshots[i] != null) tickers[i]: snapshots[i]!,
    };
  }
}
