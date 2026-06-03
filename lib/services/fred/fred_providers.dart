// =============================================================================
// services/fred/fred_providers.dart
// =============================================================================
// This file exposes Riverpod providers for fetching FRED series data.
// When FRED series IDs or storage requirements change, update the following:
//   lib/services/fred/fred_models.dart    -> series ID constants and storage IDs
//   lib/services/fred/fred_service.dart   -> HTTP fetch and parsing logic
//   lib/services/fred/fred_storage_service.dart -> how series are saved to Supabase
//   economy/widgets/fred_tab.dart         -> chart consumers
//   lib/services/macro/macro_score_provider.dart -> macro score consumers
//
// Architecture:
//   fredBulkProvider  — single edge-function call fetching all 22 series at once,
//                       cached 4 hours. Eliminates the burst of 22 concurrent requests
//                       that previously caused FRED rate-limit 502s.
//   Named providers   — extract their series from the cached bulk map; no HTTP calls.
//   Family providers  — still make individual calls (dynamic series IDs).
// =============================================================================
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fred_models.dart';
import 'fred_service.dart';
import 'fred_storage_service.dart';
import '../economy/economy_snapshot_models.dart';

final _fredService = FredService();

FredStorageService get _storage =>
    FredStorageService(Supabase.instance.client);

// All named series fetched in a single bulk call
const _bulkSeriesIds = [
  FredSeriesIds.vix,
  FredSeriesIds.gold,
  FredSeriesIds.silver,
  FredSeriesIds.hyOas,
  FredSeriesIds.igOas,
  FredSeriesIds.spread2s10s,
  FredSeriesIds.fedFunds,
  FredSeriesIds.mortgageRate30y,
  FredSeriesIds.treasury1y,
  FredSeriesIds.treasury2y,
  FredSeriesIds.treasury5y,
  FredSeriesIds.treasury10y,
  FredSeriesIds.treasury20y,
  FredSeriesIds.treasury30y,
  FredSeriesIds.crudeOilWti,
  FredSeriesIds.natGasHenryHub,
  FredSeriesIds.unemploymentRate,
  FredSeriesIds.nonfarmPayrolls,
  FredSeriesIds.initialClaims,
  FredSeriesIds.consumerSentiment,
  FredSeriesIds.cpiAllItems,
  FredSeriesIds.realGdp,
  FredSeriesIds.retailSales,
  FredSeriesIds.recessionProb,
  FredSeriesIds.housingStarts,
];

// ── Single bulk provider — one HTTP call, cached 4 hours ─────────────────────

final fredBulkProvider = FutureProvider<Map<String, FredSeries>>((ref) async {
  final link  = ref.keepAlive();
  final timer = Timer(const Duration(hours: 4), link.close);
  ref.onDispose(timer.cancel);
  return _fredService.getSeriesBulk(_bulkSeriesIds, limit: 500);
});

// Helper: extract one series from the bulk map (empty FredSeries on miss)
FredSeries _extract(Map<String, FredSeries> bulk, String id) =>
    bulk[id] ?? FredSeries(seriesId: id, observations: []);

// ── Generic family provider — for dynamic/ad-hoc series (not in bulk) ────────

/// Fetch a FRED series (500 observations) — for charts and macro score.
final fredSeriesProvider =
    FutureProvider.family<FredSeries, String>((ref, seriesId) async {
  final link  = ref.keepAlive();
  final timer = Timer(const Duration(hours: 4), link.close);
  ref.onDispose(timer.cancel);
  return _fredService.getSeries(seriesId, limit: 500);
});

/// Fetch a small FRED series slice (15 observations) — for snapshot latest value.
final fredSnapshotProvider =
    FutureProvider.family<FredSeries, String>((ref, seriesId) async {
  final link  = ref.keepAlive();
  final timer = Timer(const Duration(hours: 4), link.close);
  ref.onDispose(timer.cancel);
  return _fredService.getSeries(seriesId, limit: 15);
});

// ── Named providers — all read from fredBulkProvider (no extra HTTP calls) ───

final fredVixProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.vix));

final fredGoldProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.gold));

final fredSilverProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.silver));

final fredHyOasProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.hyOas));

final fredIgOasProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.igOas));

final fredSpreadProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.spread2s10s));

final fredFedFundsProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.fedFunds));

final fredMortgageRateProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.mortgageRate30y));

final fredTreasury1yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury1y));

final fredTreasury2yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury2y));

final fredTreasury5yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury5y));

final fredTreasury10yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury10y));

final fredTreasury20yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury20y));

final fredTreasury30yProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.treasury30y));

final fredCrudeOilProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.crudeOilWti));

final fredNatGasProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.natGasHenryHub));

final fredUnemploymentRateProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.unemploymentRate));

final fredNonfarmPayrollsProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.nonfarmPayrolls));

final fredInitialClaimsProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.initialClaims));

final fredConsumerSentimentProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.consumerSentiment));

final fredCpiProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.cpiAllItems));

final fredRealGdpProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.realGdp));

final fredRetailSalesProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.retailSales));

final fredRecessionProbProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.recessionProb));

final fredHousingStartsProvider = FutureProvider<FredSeries>((ref) async =>
    _extract(await ref.watch(fredBulkProvider.future), FredSeriesIds.housingStarts));

// ── Save helpers ──────────────────────────────────────────────────────────────

Future<void> saveFredVix(FredSeries s) => _storage.saveQuoteSeries(s);
Future<void> saveFredGold(FredSeries s) => _storage.saveQuoteSeries(s);
Future<void> saveFredSilver(FredSeries s) => _storage.saveQuoteSeries(s);
Future<void> saveFredHyOas(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.hyOas);
Future<void> saveFredIgOas(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.igOas);
Future<void> saveFredSpread(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.spread2s10s);
Future<void> saveFredFedFunds(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.fedFunds);
Future<void> saveFredMortgageRate(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.mortgageRate30y);
Future<void> saveFredTreasury1y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury1y);
Future<void> saveFredTreasury2y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury2y);
Future<void> saveFredTreasury5y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury5y);
Future<void> saveFredTreasury10y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury10y);
Future<void> saveFredTreasury20y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury20y);
Future<void> saveFredTreasury30y(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.treasury30y);
Future<void> saveFredCrudeOil(FredSeries s) =>
    _storage.saveQuoteSeries(s);
Future<void> saveFredNatGas(FredSeries s) =>
    _storage.saveQuoteSeries(s);
Future<void> saveFredUnemploymentRate(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.unemploymentRate);
Future<void> saveFredNonfarmPayrolls(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.nonfarmPayrolls);
Future<void> saveFredInitialClaims(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.initialClaims);
Future<void> saveFredConsumerSentiment(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.consumerSentiment);
Future<void> saveFredCpi(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.cpiAllItems);
Future<void> saveFredRealGdp(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.realGdp);
Future<void> saveFredRetailSales(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.retailSales);
Future<void> saveFredRecessionProb(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.recessionProb);
Future<void> saveFredHousingStarts(FredSeries s) =>
    _storage.saveIndicatorSeries(s, FredStorageIds.housingStarts);

// ── Combined treasury yield curve ─────────────────────────────────────────────
// Builds a TreasuryRates from the 6 individual treasury series.
// Returns null while any are still loading; uses the 10Y observation date as
// the row anchor so the DB date matches when FRED last updated.

final fredTreasuryRatesProvider = Provider<TreasuryRates?>((ref) {
  FredObservation? first(FutureProvider<FredSeries> p) =>
      ref.watch(p).whenOrNull(
        data: (s) => s.observations.isEmpty ? null : s.observations.first,
      );

  final obs10y = first(fredTreasury10yProvider);
  if (obs10y == null) return null;

  double? val(FutureProvider<FredSeries> p) => first(p)?.value;

  return TreasuryRates(
    date:   obs10y.date,
    year1:  val(fredTreasury1yProvider),
    year2:  val(fredTreasury2yProvider),
    year5:  val(fredTreasury5yProvider),
    year10: obs10y.value,
    year20: val(fredTreasury20yProvider),
    year30: val(fredTreasury30yProvider),
  );
});
