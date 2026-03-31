import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/kalshi_config.dart';
import 'eia_models.dart';

class EiaService {
  static final EiaService _instance = EiaService._();
  EiaService._();
  factory EiaService() => _instance;

  final _client = http.Client();

  // ── Core request ──────────────────────────────────────────────────────────

  Future<EiaResponse> _get(
    String route, {
    String frequency = 'weekly',
    List<String> data = const ['value'],
    String? start,
    String? end,
    int length = 52,
    Map<String, String>? facets,
  }) async {
    final params = <String, String>{
      'api_key': EiaConfig.apiKey,
      'frequency': frequency,
      'length': length.toString(),
      'sort[0][column]': 'period',
      'sort[0][direction]': 'desc',
      'offset': '0',
    };
    for (final d in data) {
      params['data[]'] = d;
    }
    if (start != null) params['start'] = start;
    if (end != null) params['end'] = end;
    if (facets != null) {
      facets.forEach((k, v) => params['facets[$k][]'] = v);
    }

    final uri = Uri.parse('${EiaConfig.baseUrl}/$route/data/').replace(queryParameters: params);
    final response = await _client.get(uri);
    _checkStatus(response);
    return EiaResponse.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ── Petroleum ─────────────────────────────────────────────────────────────

  Future<EiaResponse> crudeOilProductionWeekly() => _get(
        EiaRoutes.crudeProdWeekly,
        frequency: 'weekly',
        facets: {'series': 'WCRFPUS2'},
      );

  Future<EiaResponse> crudeOilStocksCommercialWeekly() => _get(
        EiaRoutes.crudeStocksWeekly,
        frequency: 'weekly',
        facets: {'series': 'WCRSTUS1'},
      );

  Future<EiaResponse> crudeOilImportsWeekly() => _get(
        EiaRoutes.crudeImportsWeekly,
        frequency: 'weekly',
        facets: {'series': 'WCRIMUS2'},
      );

  Future<EiaResponse> motorGasolineStocksWeekly() => _get(
        EiaRoutes.gasolineStocksWeekly,
        frequency: 'weekly',
        facets: {'series': 'WGTSTUS1'},
      );

  Future<EiaResponse> distillateStocksWeekly() => _get(
        EiaRoutes.distillateStocksWeekly,
        frequency: 'weekly',
        facets: {'series': 'WDISTUS1'},
      );

  Future<EiaResponse> refineryUtilizationWeekly() => _get(
        EiaRoutes.refineryUtilizationWeekly,
        frequency: 'weekly',
        facets: {'series': 'WPULEUS3'},
      );

  Future<EiaResponse> retailGasolinePricesWeekly() => _get(
        EiaRoutes.gasolinePricesWeekly,
        frequency: 'weekly',
        facets: {'series': 'EMM_EPM0_PTE_NUS_DPG'},
      );

  /// Full weekly gasoline price history from 1990-08-20 to present.
  /// Series EMM_EPM0_PTE_NUS_DPG = US average, all grades, $/gallon.
  /// Route: /v2/petroleum/pri/gnd/data/
  Future<EiaResponse> gasolinePriceFullHistory() => _get(
        EiaRoutes.gasolinePricesWeekly,
        frequency: 'weekly',
        start: '1990-08-20',
        length: 5000,
        facets: {'series': 'EMM_EPM0_PTE_NUS_DPG'},
      );

  Future<EiaResponse> crudeOilProductionMonthly() => _get(
        EiaRoutes.crudeProdMonthly,
        frequency: 'monthly',
        length: 5000,
      );
      

  Future<EiaResponse> petroleumConsumptionMonthly() => _get(
        EiaRoutes.petroleumConsumptionMonthly,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> crudeOilImportsByCountry() => _get(
        EiaRoutes.crudeImportsByCountry,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> strategicPetroleumReserveWeekly() => _get(
        EiaRoutes.strategicPetroleumReserve,
        frequency: 'weekly',
        facets: {'series': 'WCSSTUS1'},
      );

  // ── Natural Gas ───────────────────────────────────────────────────────────

  Future<EiaResponse> natGasStorageWeekly() => _get(
        EiaRoutes.natGasStorageWeekly,
        frequency: 'weekly',
        facets: {'series': 'NW2_EPG0_SWO_R48_BCF'},
      );

  Future<EiaResponse> natGasProductionMonthly() => _get(
        EiaRoutes.natGasProdMonthly,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> natGasConsumptionMonthly() => _get(
        EiaRoutes.natGasConsMonthly,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> natGasPrices() => _get(
        EiaRoutes.natGasPrices,
        frequency: 'monthly',
        length: 24,
        facets: {'series': 'N3300US3'},
      );

  Future<EiaResponse> natGasImportsExports() => _get(
        EiaRoutes.natGasMovement,
        frequency: 'monthly',
        length: 24,
      );

  // ── Electricity ───────────────────────────────────────────────────────────

  Future<EiaResponse> electricityGridDemandHourly() => _get(
        EiaRoutes.electricityGridDemandHourly,
        frequency: 'hourly',
        length: 168, // one week of hourly data
      );

  Future<EiaResponse> electricityGenerationByFuelMonthly() => _get(
        EiaRoutes.electricityGenerationMonthly,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> electricityRetailSalesMonthly() => _get(
        EiaRoutes.electricityRetailSales,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> electricityRetailPricesMonthly() => _get(
        EiaRoutes.electricityRetailSales,
        frequency: 'monthly',
        length: 24,
        data: ['price'],
      );

  Future<EiaResponse> operatingGeneratorCapacity() => _get(
        EiaRoutes.electricityGeneratorCapacity,
        frequency: 'annual',
        length: 5,
      );

  // ── Coal ──────────────────────────────────────────────────────────────────

  Future<EiaResponse> coalProductionByState() => _get(
        EiaRoutes.coalProduction,
        frequency: 'quarterly',
        length: 12,
      );

  Future<EiaResponse> coalConsumptionBySector() => _get(
        EiaRoutes.coalConsumption,
        frequency: 'quarterly',
        length: 12,
      );

  Future<EiaResponse> coalPrices() => _get(
        EiaRoutes.coalPrices,
        frequency: 'quarterly',
        length: 12,
      );

  // ── Total Energy & Outlook ────────────────────────────────────────────────

  Future<EiaResponse> totalEnergyProductionBySource() => _get(
        EiaRoutes.totalEnergyProduction,
        frequency: 'monthly',
        length: 24,
      );

  Future<EiaResponse> shortTermEnergyOutlook() => _get(
        EiaRoutes.shortTermEnergyOutlook,
        frequency: 'monthly',
        length: 12,
      );

  Future<EiaResponse> co2EmissionsByState() => _get(
        EiaRoutes.co2Emissions,
        frequency: 'annual',
        length: 5,
      );

  // ── International ─────────────────────────────────────────────────────────

  Future<EiaResponse> opecCrudeOilProduction() => _get(
        EiaRoutes.internationalPetroleum,
        frequency: 'monthly',
        length: 24,
        facets: {'productId': '57', 'activityId': '1'},
      );

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _checkStatus(http.Response r) {
    if (r.statusCode != 200) {
      throw Exception('EIA API error ${r.statusCode}: ${r.body}');
    }
  }
}
