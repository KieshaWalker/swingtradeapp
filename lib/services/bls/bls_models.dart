// =============================================================================
// services/bls/bls_models.dart
// =============================================================================
// Endpoint: https://api.bls.gov/publicAPI/v2/timeseries/data/  (POST)
//   via Supabase Edge Function: get-bls-data
// Auth: registrationkey in POST body via BLS_API_KEY secret
// Response shape: { Results: { series: [ { seriesID, data: [ {year,period,periodName,value} ] } ] } }
//
// BlsSeries / BlsDataPoint / BlsResponse
//   → BlsService.fetchSeries(seriesIds)
//   → blsEmploymentProvider, blsCpiProvider, blsPpiProvider, blsJoltsProvider
//   → BlsTab (economy/widgets/bls_tab.dart)
//   → EconomyStorageService.saveBlsResponse() → economy_indicator_snapshots (Supabase)
//   → economy_charts_tab.dart (historical charts)

class BlsDataPoint {
  final String year;
  final String period;     // e.g. "M01" or "Q01"
  final String periodName;
  final double value;

  const BlsDataPoint({
    required this.year,
    required this.period,
    required this.periodName,
    required this.value,
  });

  factory BlsDataPoint.fromJson(Map<String, dynamic> j) => BlsDataPoint(
        year: j['year']?.toString() ?? '',
        period: j['period']?.toString() ?? '',
        periodName: j['periodName']?.toString() ?? '',
        value: double.tryParse(j['value']?.toString() ?? '') ?? 0.0,
      );
}

class BlsSeries {
  final String seriesId;
  final List<BlsDataPoint> data;

  const BlsSeries({required this.seriesId, required this.data});

  factory BlsSeries.fromJson(Map<String, dynamic> j) => BlsSeries(
        seriesId: j['seriesID']?.toString() ?? '',
        data: (j['data'] as List? ?? [])
            .map((e) => BlsDataPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  BlsDataPoint? get latest => data.isEmpty ? null : data.first;
}

class BlsResponse {
  final String status;
  final List<BlsSeries> series;

  const BlsResponse({required this.status, required this.series});

  factory BlsResponse.fromJson(Map<String, dynamic> json) => BlsResponse(
        status: json['status']?.toString() ?? '',
        series: ((json['Results']?['series']) as List? ?? [])
            .map((e) => BlsSeries.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// All series IDs from the PDF, grouped by category
class BlsSeriesIds {
  // Current Employment Statistics (CES)
  static const totalNonfarmPayrolls = 'CES0000000001';
  static const privatePayrolls = 'CES0500000001';
  static const manufacturingEmployment = 'CES3000000001';
  static const avgWeeklyHoursPrivate = 'CES0500000002';
  static const avgWeeklyHoursManufacturing = 'CES3000000002';
  static const avgHourlyEarningsPrivate = 'CES0500000003';
  static const avgHourlyEarningsManufacturing = 'CES3000000003';
  static const avgWeeklyEarningsPrivate = 'CES0500000011';

  // Current Population Survey (LNS)
  static const unemploymentRateU3 = 'LNS14000000';
  static const laborForceParticipationRate = 'LNS11300000';
  static const employmentPopulationRatio = 'LNS12300000';
  static const totalUnemployed = 'LNS13000000';
  static const civilianLaborForce = 'LNS11000000';
  static const notInLaborForce = 'LNS15000000';
  static const partTimeEconomicReasons = 'LNS12032194';
  static const longTermUnemployed = 'LNS13025703';

  // JOLTS
  static const jobOpenings = 'JTS000000000000000JOL';
  static const hires = 'JTS000000000000000HIL';
  static const totalSeparations = 'JTS000000000000000TSL';
  static const quits = 'JTS000000000000000QUL';
  static const layoffsDischarges = 'JTS000000000000000LDL';
  static const jobOpeningsRate = 'JTS000000000000000JOR';
  static const quitsRate = 'JTS000000000000000QUR';

  // CPI-U
  static const cpiAllItemsSA = 'CUSR0000SA0';
  static const cpiAllItemsNSA = 'CUUR0000SA0';
  static const cpiCore = 'CUSR0000SA0L1E';
  static const cpiFood = 'CUSR0000SAF1';
  static const cpiEnergy = 'CUSR0000SA0E';
  static const cpiShelter = 'CUSR0000SAH1';
  static const cpiMedical = 'CUSR0000SAM';
  static const cpiTransportation = 'CUSR0000SAT';
  static const cpiApparel = 'CUSR0000SAA';
  static const cpiNewVehicles = 'CUSR0000SETA01';
  static const cpiUsedVehicles = 'CUSR0000SETA02';
  static const chainedCpi = 'SUUR0000SA0';

  // PPI
  static const ppiFinalDemand = 'WPSFD4';
  static const ppiFinalDemandLessFoodEnergy = 'WPSFD49116';
  static const ppiFinalDemandGoods = 'WPSFD41';
  static const ppiFinalDemandServices = 'WPSFD42';
  static const ppiCrudeMaterials = 'WPUFD3';
  static const ppiIntermediateDemand = 'WPUID6';

  // Import/Export Prices
  static const importPriceAllCommodities = 'EIUIR';
  static const exportPriceAllCommodities = 'EIUIQ';
  static const importPriceFuels = 'EIUIR1';
  static const importPriceNonFuel = 'EIUIR311';

  // Productivity
  static const nonfarmLaborProductivity = 'PRS85006092';
  static const nonfarmUnitLaborCosts = 'PRS85006112';
  static const manufacturingLaborProductivity = 'PRS30006092';
  static const manufacturingUnitLaborCosts = 'PRS30006112';

  // Employment Cost Index
  static const eciTotalCompensation = 'CIS1010000000000I';
  static const eciWagesSalaries = 'CIS2010000000000I';
  static const eciBenefits = 'CIS3010000000000I';

  // Employment groups for batch fetching
  static const List<String> employmentSituation = [
    totalNonfarmPayrolls, privatePayrolls, manufacturingEmployment,
    avgWeeklyHoursPrivate, avgWeeklyHoursManufacturing,
    avgHourlyEarningsPrivate, avgHourlyEarningsManufacturing, avgWeeklyEarningsPrivate,
  ];

  static const List<String> laborForce = [
    unemploymentRateU3, laborForceParticipationRate,
    employmentPopulationRatio, totalUnemployed, civilianLaborForce,
    notInLaborForce, partTimeEconomicReasons, longTermUnemployed,
  ];

  static const List<String> jolts = [
    jobOpenings, hires, totalSeparations, quits,
    layoffsDischarges, jobOpeningsRate, quitsRate,
  ];

  static const List<String> cpi = [
    cpiAllItemsSA, cpiAllItemsNSA, cpiCore, cpiFood, cpiEnergy,
    cpiShelter, cpiMedical, cpiTransportation, cpiApparel,
    cpiNewVehicles, cpiUsedVehicles, chainedCpi,
  ];

  static const List<String> ppi = [
    ppiFinalDemand, ppiFinalDemandLessFoodEnergy, ppiFinalDemandGoods,
    ppiFinalDemandServices, ppiCrudeMaterials, ppiIntermediateDemand,
  ];
}
