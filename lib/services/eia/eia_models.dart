// =============================================================================
// services/eia/eia_models.dart
// =============================================================================
// Endpoint: https://api.eia.gov/v2/{route}/data/  (GET)
//   via Supabase Edge Function: get-eia-data
// Auth: api_key= query param via EIA_API_KEY secret
// Response shape: { response: { total, frequency, data: [ { period, value, unit } ] } }
//
// EiaDataPoint / EiaResponse
//   → EiaService (crude oil, gasoline, nat gas, refinery, electricity, coal, SPR, etc.)
//   → eiaGasolinePricesProvider, eiaCrudeStocksProvider, eiaCrudeProdProvider,
//     eiaNatGasStorageProvider, eiaRefineryUtilProvider, eiaSprProvider
//   → EiaTab (economy/widgets/eia_tab.dart)
//   → EconomyStorageService.saveEiaResponse() → economy_indicator_snapshots (Supabase)
//   → GasolinePriceHistoryChart, NatGasImportChart (stored history charts)

class EiaDataPoint {
  final String period;
  final double? value;
  final String unit;

  const EiaDataPoint({required this.period, this.value, required this.unit});

  factory EiaDataPoint.fromJson(Map<String, dynamic> j) => EiaDataPoint(
        period: j['period']?.toString() ?? '',
        value: j['value'] != null ? double.tryParse(j['value'].toString()) : null,
        unit: j['unit']?.toString() ?? '',
      );
}

class EiaResponse {
  final int total;
  final String frequency;
  final List<EiaDataPoint> data;

  const EiaResponse({required this.total, required this.frequency, required this.data});

  factory EiaResponse.fromJson(Map<String, dynamic> json) {
    final resp = json['response'] as Map<String, dynamic>? ?? {};
    final rawData = resp['data'] as List? ?? [];
    return EiaResponse(
      total: int.tryParse(resp['total']?.toString() ?? '0') ?? 0,
      frequency: resp['frequency']?.toString() ?? '',
      data: rawData.map((e) => EiaDataPoint.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  EiaDataPoint? get latest => data.isEmpty ? null : data.first;
}

// EIA v2 route constants from the PDF
class EiaRoutes {
  // Petroleum
  static const crudeProdWeekly = 'petroleum/sum/sndw';
  static const crudeStocksWeekly = 'petroleum/stoc/wstk';
  static const crudeImportsWeekly = 'petroleum/move/wkly';
  static const gasolineStocksWeekly = 'petroleum/stoc/wstk';
  static const distillateStocksWeekly = 'petroleum/stoc/wstk';
  static const refineryUtilizationWeekly = 'petroleum/pnp/wiup';
  static const gasolinePricesWeekly = 'petroleum/pri/gnd';
  static const crudeProdMonthly = 'petroleum/crd/crpdn';
  static const petroleumConsumptionMonthly = 'petroleum/cons';
  static const crudeImportsByCountry = 'crude-oil-imports';
  static const strategicPetroleumReserve = 'petroleum/stoc/wstk';

  // Natural Gas
  static const natGasStorageWeekly = 'natural-gas/stor/wkly';
  static const natGasProdMonthly = 'natural-gas/prod/sum';
  static const natGasConsMonthly = 'natural-gas/cons/sum';
  static const natGasPrices = 'natural-gas/pri/sum';
  static const natGasMovement = 'natural-gas/move';

  // Electricity
  static const electricityGridDemandHourly = 'electricity/rto/fuel-type-data';
  static const electricityGenerationMonthly = 'electricity/electric-power-operational-data';
  static const electricityRetailSales = 'electricity/retail-sales';
  static const electricityGeneratorCapacity = 'electricity/operating-generator-capacity';

  // Coal
  static const coalProduction = 'coal/production';
  static const coalConsumption = 'coal/consumption';
  static const coalPrices = 'coal/market-sales-price';

  // Total Energy & Outlook
  static const totalEnergyProduction = 'total-energy';
  static const shortTermEnergyOutlook = 'steo';
  static const co2Emissions = 'co2-emissions';

  // International
  static const internationalPetroleum = 'international';
}
