// =============================================================================
// services/iv/iv_storage_service.dart
// =============================================================================
// Supabase I/O for iv_snapshots table.
//
//  saveSnapshot()   — upsert today's snapshot (called on every chain load)
//  getHistory()     — last 252 trading days for a ticker (for IVR/IVP)
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';
import 'iv_models.dart';

class IvStorageService {
  static final IvStorageService _i = IvStorageService._();
  IvStorageService._();
  factory IvStorageService() => _i;

  SupabaseClient get _db => Supabase.instance.client;

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Upsert today's snapshot. Safe to call multiple times — keyed on (ticker, date).
  Future<void> saveSnapshot(IvSnapshot snap) async {
    await _db
        .from('iv_snapshots')
        .upsert(snap.toJson(), onConflict: 'ticker,date');
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns up to 252 daily snapshots for [ticker], sorted ascending by date.
  /// Used by IvAnalyticsService to compute IVR, IVP, and skew Z-score.
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

    // Fetch all and keep only the newest per ticker
    final rows = await _db
        .from('iv_snapshots')
        .select()
        .inFilter('ticker', tickers)
        .order('date', ascending: false);

    final result = <String, IvSnapshot>{};
    for (final r in (rows as List)) {
      final snap = IvSnapshot.fromJson(r as Map<String, dynamic>);
      result.putIfAbsent(snap.ticker, () => snap);
    }
    return result;
  }
}
