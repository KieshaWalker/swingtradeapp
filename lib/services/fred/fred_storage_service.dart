// =============================================================================
// services/fred/fred_storage_service.dart
// =============================================================================
// Persists FRED series to existing Supabase tables — no new migrations needed.
//
// Routing:
//   Price-like series (VIX, Gold, Silver) → economy_quote_snapshots
//     columns: symbol (= FRED series ID), date, price, change_percent = 0
//
//   Spread / rate series → economy_indicator_snapshots
//     columns: identifier (= FredStorageIds.*), date, value
//
// All writes are upserts — re-running on the same day is idempotent.
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fred_models.dart';

class FredStorageService {
  final SupabaseClient _db;
  const FredStorageService(this._db);

  // ── Quote-like series: VIX, Gold, Silver ─────────────────────────────────

  Future<void> saveQuoteSeries(FredSeries series) async {
    if (series.observations.isEmpty) return;
    try {
      await _db.from('economy_quote_snapshots').upsert(
        series.observations.map((o) => {
          'symbol': series.seriesId,
          'date': _fmt(o.date),
          'price': o.value,
          'change_percent': 0.0,
        }).toList(),
        onConflict: 'symbol,date',
      );
    } catch (_) {}
  }

  // ── Indicator series: OAS spreads, T10Y2Y, DFF ───────────────────────────

  Future<void> saveIndicatorSeries(FredSeries series, String identifier) async {
    if (series.observations.isEmpty) return;
    try {
      await _db.from('economy_indicator_snapshots').upsert(
        series.observations.map((o) => {
          'identifier': identifier,
          'date': _fmt(o.date),
          'value': o.value,
        }).toList(),
        onConflict: 'identifier,date',
      );
    } catch (_) {}
  }

  // ── Read back helpers (used by macro score service) ───────────────────────

  Future<List<Map<String, dynamic>>> getQuoteHistory(
    String symbol, {
    int limit = 252,
  }) =>
      _db
          .from('economy_quote_snapshots')
          .select('date, price')
          .eq('symbol', symbol)
          .order('date', ascending: false)
          .limit(limit);

  Future<List<Map<String, dynamic>>> getIndicatorHistory(
    String identifier, {
    int limit = 500,
  }) =>
      _db
          .from('economy_indicator_snapshots')
          .select('date, value')
          .eq('identifier', identifier)
          .order('date', ascending: false)
          .limit(limit);

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
