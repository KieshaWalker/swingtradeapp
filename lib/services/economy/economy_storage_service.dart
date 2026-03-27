// =============================================================================
// services/economy/economy_storage_service.dart
// =============================================================================
// Persists EconomyPulseData to Supabase and reads back history for charts.
//
// Tables written:
//   economy_indicator_snapshots  — one row per (identifier, date)
//   economy_treasury_snapshots   — one row per date
//   economy_quote_snapshots      — one row per (symbol, date)
//
// All writes are upserts (on-conflict do update) so repeated fetches on the
// same day are idempotent.
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import '../fmp/fmp_models.dart';
import 'economy_snapshot_models.dart';

class EconomyStorageService {
  final SupabaseClient _db;
  const EconomyStorageService(this._db);

  // ── Write ──────────────────────────────────────────────────────────────────

  Future<void> saveEconomyPulse(EconomyPulseData data) async {
    try {
      await Future.wait([
        _saveIndicators(data),
        _saveTreasury(data.treasury),
        _saveQuotes(data),
      ]);
    } catch (_) {
      // Silently ignore if tables don't exist yet (migration not applied)
    }
  }

  Future<void> _saveIndicators(EconomyPulseData data) async {
    final points = [
      data.fedFunds,
      data.unemployment,
      data.nfp,
      data.initialClaims,
      data.cpi,
      data.gdp,
      data.retailSales,
      data.consumerSentiment,
      data.mortgageRate,
      data.housingStarts,
      data.recessionProb,
    ].whereType<EconomicIndicatorPoint>().toList();

    if (points.isEmpty) return;
    await _db.from('economy_indicator_snapshots').upsert(
      points
          .map((p) => {
                'identifier': p.identifier,
                'date': _fmt(p.date),
                'value': p.value,
              })
          .toList(),
      onConflict: 'identifier,date',
    );
  }

  Future<void> _saveTreasury(TreasuryRates? treasury) async {
    if (treasury == null) return;
    await _db.from('economy_treasury_snapshots').upsert(
      {
        'date': _fmt(treasury.date),
        'year1': treasury.year1,
        'year2': treasury.year2,
        'year5': treasury.year5,
        'year10': treasury.year10,
        'year20': treasury.year20,
        'year30': treasury.year30,
      },
      onConflict: 'date',
    );
  }

  Future<void> _saveQuotes(EconomyPulseData data) async {
    final today = _fmt(data.fetchedAt);
    final quotes = [
      data.sp500,
      data.nasdaq,
      data.vix,
      data.dxy,
      data.gold,
      data.silver,
      data.wtiCrude,
      data.natGas,
    ].whereType<StockQuote>().toList();

    if (quotes.isEmpty) return;
    await _db.from('economy_quote_snapshots').upsert(
      quotes
          .map((q) => {
                'symbol': q.symbol,
                'date': today,
                'price': q.price,
                'change_percent': q.changePercent,
              })
          .toList(),
      onConflict: 'symbol,date',
    );
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  Future<List<EconomicIndicatorPoint>> getIndicatorHistory(
      String identifier) async {
    try {
      final rows = await _db
          .from('economy_indicator_snapshots')
          .select('identifier, date, value')
          .eq('identifier', identifier)
          .order('date');
      return rows
          .map<EconomicIndicatorPoint>((r) => EconomicIndicatorPoint(
                identifier: r['identifier'] as String,
                date: DateTime.parse(r['date'] as String),
                value: (r['value'] as num).toDouble(),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<QuoteSnapshot>> getQuoteHistory(String symbol) async {
    try {
      final rows = await _db
          .from('economy_quote_snapshots')
          .select('symbol, date, price, change_percent')
          .eq('symbol', symbol)
          .order('date');
      return rows.map<QuoteSnapshot>(QuoteSnapshot.fromRow).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<TreasurySnapshot>> getTreasuryHistory() async {
    try {
      final rows =
          await _db.from('economy_treasury_snapshots').select().order('date');
      return rows.map<TreasurySnapshot>(TreasurySnapshot.fromRow).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
