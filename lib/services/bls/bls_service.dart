import 'package:supabase_flutter/supabase_flutter.dart';
import 'bls_models.dart';

class BlsService {
  static final BlsService _instance = BlsService._();
  BlsService._();
  factory BlsService() => _instance;

  // ── Core request — batch POST (up to 50 series) ───────────────────────────

  Future<BlsResponse> fetchSeries(
    List<String> seriesIds, {
    int startYear = 2000,
    int? endYear,
  }) async {
    final end = endYear ?? DateTime.now().year;
    final response = await Supabase.instance.client.functions.invoke(
      'get-bls-data',
      body: {
        'seriesid': seriesIds,
        'startyear': startYear.toString(),
        'endyear': end.toString(),
      },
    );
    if (response.status != 200) {
      throw Exception('BLS Edge Function error ${response.status}');
    }
    return BlsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ── Employment Situation (CES) ────────────────────────────────────────────

  Future<BlsResponse> employmentSituation({int startYear = 2000}) =>
      fetchSeries(BlsSeriesIds.employmentSituation, startYear: startYear);

  Future<BlsResponse> nonfarmPayrolls({int startYear = 2000}) =>
      fetchSeries([BlsSeriesIds.totalNonfarmPayrolls], startYear: startYear);

  Future<BlsResponse> avgHourlyEarnings({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.avgHourlyEarningsPrivate,
        BlsSeriesIds.avgHourlyEarningsManufacturing,
      ], startYear: startYear);

  // ── Labor Force (LNS / CPS) ───────────────────────────────────────────────

  Future<BlsResponse> laborForce({int startYear = 2000}) =>
      fetchSeries(BlsSeriesIds.laborForce, startYear: startYear);

  Future<BlsResponse> unemploymentRate({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.unemploymentRateU3,
      ], startYear: startYear);

  Future<BlsResponse> laborForceParticipation({int startYear = 2000}) =>
      fetchSeries([BlsSeriesIds.laborForceParticipationRate], startYear: startYear);

  // ── JOLTS ─────────────────────────────────────────────────────────────────

  Future<BlsResponse> jolts({int startYear = 2000}) =>
      fetchSeries(BlsSeriesIds.jolts, startYear: startYear);

  Future<BlsResponse> jobOpenings({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.jobOpenings,
        BlsSeriesIds.jobOpeningsRate,
      ], startYear: startYear);

  Future<BlsResponse> quits({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.quits,
        BlsSeriesIds.quitsRate,
      ], startYear: startYear);

  // ── Consumer Price Index ──────────────────────────────────────────────────

  Future<BlsResponse> cpi({int startYear = 2000}) =>
      fetchSeries(BlsSeriesIds.cpi, startYear: startYear);

  Future<BlsResponse> cpiHeadlineAndCore({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.cpiAllItemsSA,
        BlsSeriesIds.cpiCore,
      ], startYear: startYear);

  Future<BlsResponse> cpiComponents({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.cpiFood,
        BlsSeriesIds.cpiEnergy,
        BlsSeriesIds.cpiShelter,
        BlsSeriesIds.cpiMedical,
        BlsSeriesIds.cpiTransportation,
      ], startYear: startYear);

  // ── Producer Price Index ──────────────────────────────────────────────────

  Future<BlsResponse> ppi({int startYear = 2000}) =>
      fetchSeries(BlsSeriesIds.ppi, startYear: startYear);

  Future<BlsResponse> ppiHeadlineAndCore({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.ppiFinalDemand,
        BlsSeriesIds.ppiFinalDemandLessFoodEnergy,
      ], startYear: startYear);

  // ── Import / Export Prices ────────────────────────────────────────────────

  Future<BlsResponse> importExportPrices({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.importPriceAllCommodities,
        BlsSeriesIds.exportPriceAllCommodities,
        BlsSeriesIds.importPriceFuels,
        BlsSeriesIds.importPriceNonFuel,
      ], startYear: startYear);

  // ── Productivity ──────────────────────────────────────────────────────────

  Future<BlsResponse> productivity({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.nonfarmLaborProductivity,
        BlsSeriesIds.nonfarmUnitLaborCosts,
        BlsSeriesIds.manufacturingLaborProductivity,
        BlsSeriesIds.manufacturingUnitLaborCosts,
      ], startYear: startYear);

  // ── Employment Cost Index ─────────────────────────────────────────────────

  Future<BlsResponse> employmentCostIndex({int startYear = 2000}) =>
      fetchSeries([
        BlsSeriesIds.eciTotalCompensation,
        BlsSeriesIds.eciWagesSalaries,
        BlsSeriesIds.eciBenefits,
      ], startYear: startYear);

  // ── Full snapshot — all series in one call ────────────────────────────────
  // BLS v2 allows up to 50 series per request; split into two batches.

  Future<List<BlsResponse>> allSeries({int startYear = 2000}) async {
    final all = [
      ...BlsSeriesIds.employmentSituation,
      ...BlsSeriesIds.laborForce,
      ...BlsSeriesIds.jolts,
      ...BlsSeriesIds.cpi,
      ...BlsSeriesIds.ppi,
      BlsSeriesIds.importPriceAllCommodities,
      BlsSeriesIds.exportPriceAllCommodities,
      BlsSeriesIds.importPriceFuels,
      BlsSeriesIds.importPriceNonFuel,
      BlsSeriesIds.nonfarmLaborProductivity,
      BlsSeriesIds.nonfarmUnitLaborCosts,
      BlsSeriesIds.manufacturingLaborProductivity,
      BlsSeriesIds.manufacturingUnitLaborCosts,
      BlsSeriesIds.eciTotalCompensation,
      BlsSeriesIds.eciWagesSalaries,
      BlsSeriesIds.eciBenefits,
    ];
    // Batch into chunks of 50
    final batches = <List<String>>[];
    for (var i = 0; i < all.length; i += 50) {
      batches.add(all.sublist(i, i + 50 > all.length ? all.length : i + 50));
    }
    final results = await Future.wait(
      batches.map((b) => fetchSeries(b, startYear: startYear)),
    );
    return results;
  }

}
