// =============================================================================
// features/economy/providers/api_data_providers.dart
// =============================================================================
// Riverpod FutureProviders for BLS, BEA, EIA, and Census services.
// Each provider fetches only the most recent data needed for the dashboard.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/bls/bls_models.dart';
import '../../../services/bls/bls_serivce.dart';
import '../../../services/bea/bea_models.dart';
import '../../../services/bea/bea_service.dart';
import '../../../services/eia/eia_models.dart';
import '../../../services/eia/eia_service.dart';
import '../../../services/census/census_models.dart';
import '../../../services/census/census_service.dart';

// ── BLS ───────────────────────────────────────────────────────────────────────

final blsEmploymentProvider = FutureProvider<BlsResponse>((ref) async {
  return BlsService().fetchSeries(
    [
      BlsSeriesIds.totalNonfarmPayrolls,
      BlsSeriesIds.unemploymentRateU3,
      BlsSeriesIds.laborForceParticipationRate,
      BlsSeriesIds.avgHourlyEarningsPrivate,
      BlsSeriesIds.avgWeeklyHoursPrivate,
    ],
    startYear: DateTime.now().year - 1,
  );
});

final blsCpiProvider = FutureProvider<BlsResponse>((ref) async {
  return BlsService().fetchSeries(
    [
      BlsSeriesIds.cpiAllItemsSA,
      BlsSeriesIds.cpiCore,
      BlsSeriesIds.cpiShelter,
      BlsSeriesIds.cpiFood,
      BlsSeriesIds.cpiEnergy,
    ],
    startYear: DateTime.now().year - 1,
  );
});

final blsPpiProvider = FutureProvider<BlsResponse>((ref) async {
  return BlsService().fetchSeries(
    [
      BlsSeriesIds.ppiFinalDemand,
      BlsSeriesIds.ppiFinalDemandLessFoodEnergy,
      BlsSeriesIds.ppiFinalDemandGoods,
      BlsSeriesIds.ppiFinalDemandServices,
    ],
    startYear: DateTime.now().year - 1,
  );
});

final blsJoltsProvider = FutureProvider<BlsResponse>((ref) async {
  return BlsService().fetchSeries(
    [
      BlsSeriesIds.jobOpenings,
      BlsSeriesIds.hires,
      BlsSeriesIds.quits,
      BlsSeriesIds.layoffsDischarges,
      BlsSeriesIds.jobOpeningsRate,
      BlsSeriesIds.quitsRate,
    ],
    startYear: DateTime.now().year - 1,
  );
});

// ── BEA ───────────────────────────────────────────────────────────────────────

final beaGdpProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().gdpPercentChange(years: 3);
});

final beaRealGdpProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().realGdp(years: 3);
});

final beaPceProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().personalConsumptionExpenditures(years: 2);
});

final beaCorePceProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().corePcePriceIndex(years: 2);
});

final beaPersonalIncomeProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().personalIncome(years: 2);
});

final beaCorporateProfitsProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().corporateProfitsAfterTax(years: 3);
});

final beaNetExportsProvider = FutureProvider<BeaResponse>((ref) async {
  return BeaService().netExports(years: 3);
});

// ── EIA ───────────────────────────────────────────────────────────────────────

final eiaGasolinePricesProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().retailGasolinePricesWeekly();
});

/// Full gasoline price history 1990–present (up to 5 000 weekly points).
final eiaGasolinePriceHistoryProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().gasolinePriceFullHistory();
});

final eiaCrudeStocksProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().crudeOilStocksCommercialWeekly();
});

final eiaCrudeProdProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().crudeOilProductionWeekly();
});

final eiaNatGasStorageProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().natGasStorageWeekly();
});

final eiaRefineryUtilProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().refineryUtilizationWeekly();
});

final eiaSprProvider = FutureProvider<EiaResponse>((ref) async {
  return EiaService().strategicPetroleumReserveWeekly();
});

// ── Census ────────────────────────────────────────────────────────────────────

final censusRetailSalesProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().advanceRetailSales(from: _yearMonth(13));
});

final censusMotorVehiclesProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().retailSalesMotorVehicles(from: _yearMonth(13));
});

final censusNonStoreProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().retailSalesNonStore(from: _yearMonth(13));
});

final censusConstructionSpendingProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().constructionSpending(fromYear: _yearForEits(2));
});

final censusManufacturingOrdersProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().manufacturersNewOrders(fromYear: _yearForEits(2));
});

final censusWholesaleSalesProvider = FutureProvider<CensusResponse>((ref) async {
  return CensusService().wholesaleTradeSales(fromYear: _yearForEits(2));
});

// Returns year N years ago (for EITS endpoints that accept a year predicate)
int _yearForEits(int yearsAgo) => DateTime.now().year - yearsAgo;

// Returns "YYYY-MM" for n months ago
String _yearMonth(int monthsAgo) {
  final d = DateTime.now();
  var year = d.year;
  var month = d.month - monthsAgo;
  while (month <= 0) {
    month += 12;
    year -= 1;
  }
  return '$year-${month.toString().padLeft(2, '0')}';
}
