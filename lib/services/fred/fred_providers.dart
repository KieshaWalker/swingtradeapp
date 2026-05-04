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
// The providers are grouped by usage:
//   • charts + macro score
//   • snapshot history storage
//   • economic indicator snapshots
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fred_models.dart';
import 'fred_service.dart';
import 'fred_storage_service.dart';
import '../economy/economy_snapshot_models.dart';

final _fredService = FredService();

FredStorageService get _storage =>
    FredStorageService(Supabase.instance.client);

// ── Generic family provider ───────────────────────────────────────────────────

/// Fetch a FRED series (500 observations) — for charts and macro score.
final fredSeriesProvider =
    FutureProvider.family<FredSeries, String>((ref, seriesId) async {
  return _fredService.getSeries(seriesId, limit: 500);
});

/// Fetch a small FRED series slice (15 observations) — for snapshot latest value.
final fredSnapshotProvider =
    FutureProvider.family<FredSeries, String>((ref, seriesId) async {
  return _fredService.getSeries(seriesId, limit: 15);
});

// ── Existing chart / macro-score providers (limit 500) ───────────────────────

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

// ── New snapshot providers (limit 500 so history is stored to Supabase) ──────

// Interest rates
final fredMortgageRateProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.mortgageRate30y, limit: 500));

final fredTreasury1yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury1y, limit: 500));

final fredTreasury2yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury2y, limit: 500));

final fredTreasury5yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury5y, limit: 500));

final fredTreasury10yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury10y, limit: 500));

final fredTreasury20yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury20y, limit: 500));

final fredTreasury30yProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.treasury30y, limit: 500));

// Commodities
final fredCrudeOilProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.crudeOilWti, limit: 500));

final fredNatGasProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.natGasHenryHub, limit: 500));

// Labor market
final fredUnemploymentRateProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.unemploymentRate, limit: 500));

final fredNonfarmPayrollsProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.nonfarmPayrolls, limit: 500));

final fredInitialClaimsProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.initialClaims, limit: 500));

final fredConsumerSentimentProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.consumerSentiment, limit: 500));

// Economy
final fredCpiProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.cpiAllItems, limit: 500));

final fredRealGdpProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.realGdp, limit: 500));

final fredRetailSalesProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.retailSales, limit: 500));

final fredRecessionProbProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.recessionProb, limit: 500));

// Housing
final fredHousingStartsProvider = FutureProvider<FredSeries>(
    (ref) => _fredService.getSeries(FredSeriesIds.housingStarts, limit: 500));

// ── Save helpers ──────────────────────────────────────────────────────────────

// Existing
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

// New
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
