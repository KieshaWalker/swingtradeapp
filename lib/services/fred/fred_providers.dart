// =============================================================================
// services/fred/fred_providers.dart
// =============================================================================
// Riverpod providers for FRED data fetch + storage.
//
// Pattern (same as EIA gasoline chart):
//   1. fredSeriesProvider(id) — fetches from FRED API (runs once, cached)
//   2. Widget listens via ref.listen → on data: saveToSupabase → invalidate
//      macroScoreProvider so the score recomputes with fresh data.
//
// Bootstrap: first fetch pulls limit=500 (~2 years of daily data) to
// immediately seed the Z-score history used by the macro scoring engine.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fred_models.dart';
import 'fred_service.dart';
import 'fred_storage_service.dart';

final _fredService = FredService();

FredStorageService get _storage =>
    FredStorageService(Supabase.instance.client);

// ── Individual series providers ───────────────────────────────────────────────

/// Fetch a FRED series. [limit] defaults to 500 for initial history bootstrap.
final fredSeriesProvider =
    FutureProvider.family<FredSeries, String>((ref, seriesId) async {
      print('Fetching FRED series $seriesId');
  return _fredService.getSeries(seriesId, limit: 500);
});

// Convenience typed providers so widgets don't need to pass raw series IDs.

final fredVixProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.vix, limit: 500));

final fredGoldProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.gold, limit: 500));

final fredSilverProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.silver, limit: 500));

final fredHyOasProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.hyOas, limit: 500));

final fredIgOasProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.igOas, limit: 500));

final fredSpreadProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.spread2s10s, limit: 500));

final fredFedFundsProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.fedFunds, limit: 500));

// ── Save helpers (called from ref.listen side-effects) ────────────────────────

Future<void> saveFredVix(FredSeries s) =>
    _storage.saveQuoteSeries(s);       // stored as symbol='VIXCLS'

Future<void> saveFredGold(FredSeries s) =>
    _storage.saveQuoteSeries(s);       // stored as symbol='GOLDAMGBD228NLBM'

Future<void> saveFredSilver(FredSeries s) =>
    _storage.saveQuoteSeries(s);       // stored as symbol='SLVPRUSD'

Future<void> saveFredHyOas(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.hyOas);

Future<void> saveFredIgOas(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.igOas);

Future<void> saveFredSpread(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.spread2s10s);

Future<void> saveFredFedFunds(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.fedFunds);
