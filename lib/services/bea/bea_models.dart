// =============================================================================
// services/bea/bea_models.dart
// =============================================================================
// Endpoint: https://apps.bea.gov/api/data  (GET)
//   via Supabase Edge Function: get-bea-data
// Auth: UserID= query param via BEA_API_KEY secret
// Response shape: { BEAAPI: { Results: { Statistic, Dimensions, Data: [ {...} ], Notes } } }
//   Data fields: TableName, SeriesCode, LineNumber, LineDescription,
//                TimePeriod, CL_UNIT, UNIT_MULT, DataValue (string with commas), NoteRef
//
// BeaObservation / BeaResponse
//   → BeaService  (GDP%, real GDP, core PCE, personal income, corporate profits, net exports, PCE)
//   → beaGdpProvider, beaRealGdpProvider, beaCorePceProvider, beaPersonalIncomeProvider,
//     beaCorporateProfitsProvider, beaNetExportsProvider, beaPceProvider
//   → BeaTab (economy/widgets/bea_tab.dart)
//   → EconomyStorageService.saveBeaResponse() → economy_indicator_snapshots (Supabase)

class BeaObservation {
  final String tableId;
  final String lineDescription;
  final String timePeriod;
  final String clUnit;
  final String multFactor;
  final String dataValue;

  const BeaObservation({
    required this.tableId,
    required this.lineDescription,
    required this.timePeriod,
    required this.clUnit,
    required this.multFactor,
    required this.dataValue,
  });

  factory BeaObservation.fromJson(Map<String, dynamic> j) => BeaObservation(
        tableId: j['TableID']?.toString() ?? '',
        lineDescription: j['LineDescription']?.toString() ?? '',
        timePeriod: j['TimePeriod']?.toString() ?? '',
        clUnit: j['CL_UNIT']?.toString() ?? '',
        multFactor: j['MULT_FACTOR']?.toString() ?? '',
        dataValue: j['DataValue']?.toString() ?? '',
      );

  double? get value {
    final clean = dataValue.replaceAll(',', '');
    return double.tryParse(clean);
  }
}

class BeaResponse {
  final String requestParam;
  final List<BeaObservation> data;

  const BeaResponse({required this.requestParam, required this.data});

  factory BeaResponse.fromJson(Map<String, dynamic> json) {
    final result = json['BEAAPI']?['Results'] ?? {};
    final rawData = result['Data'] as List? ?? [];
    return BeaResponse(
      requestParam: result['Statistic']?.toString() ?? '',
      data: rawData.map((e) => BeaObservation.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

// Series IDs by category for reference
class BeaNipaSeries {
  // GDP & Components (Table T10101 — percent change)
  static const gdpPctChange = ('T10101', '1');
  static const pce = ('T10101', '2');
  static const pceGoods = ('T10101', '3');
  static const pceServices = ('T10101', '6');
  static const grossPrivateInvestment = ('T10101', '7');
  static const fixedInvestmentNonresidential = ('T10101', '8');
  static const fixedInvestmentResidential = ('T10101', '12');
  static const changeInInventories = ('T10101', '13');
  static const netExports = ('T10101', '14');
  static const governmentSpending = ('T10101', '17');
  static const federalSpending = ('T10101', '18');
  static const stateLocalSpending = ('T10101', '21');

  // GDP Levels (Table T10105)
  static const gdpCurrentDollars = ('T10105', '1');
  static const gnp = ('T10105', '26');
  static const grossNationalIncome = ('T10105', '27');

  // Real GDP (Table T10106)
  static const realGdp = ('T10106', '1');

  // Personal Income (Table T20100)
  static const personalIncome = ('T20100', '1');
  static const disposablePersonalIncome = ('T20100', '27');
  static const personalSaving = ('T20100', '34');

  // Corporate Profits (Table T10901)
  static const corporateProfitsPreTax = ('T10901', '1');
  static const corporateProfitsAfterTax = ('T10901', '11');

  // PCE Price Index (Table T20804)
  static const pcePriceIndex = ('T20804', '1');
  static const corePcePriceIndex = ('T20804', '24');

  // GDP Deflator (Table T10109)
  static const gdpDeflator = ('T10109', '1');
}
