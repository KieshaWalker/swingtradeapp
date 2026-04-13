// =============================================================================
// services/census/census_models.dart
// =============================================================================
// Endpoint: https://api.census.gov/data/{dataset}  (GET)
//   via Supabase Edge Function: get-census-data
// Auth: key= query param via CENSUS_API_KEY secret
// Datasets used: MARTS (retail sales), VALCONS (construction), M3 (mfg orders), M3S (wholesale)
// Response shape: array-of-arrays — first row is headers, subsequent rows are data
//   e.g. [["cell_value","time","category_code",...], ["12345","2025-01",...]]
//
// CensusDataPoint / CensusRetailRow / CensusResponse
//   → CensusService (retail sales, construction spending, mfg orders, wholesale trade)
//   → censusRetailSalesProvider, censusMotorVehiclesProvider, censusNonStoreProvider,
//     censusConstructionSpendingProvider, censusManufacturingOrdersProvider, censusWholesaleSalesProvider
//   → CensusTab (economy/widgets/census_tab.dart)
//   → EconomyStorageService.saveCensusResponse() → economy_indicator_snapshots (Supabase)

class CensusDataPoint {
  final String period;
  final String value;
  final String? categoryCode;
  final String? dataTypeCode;

  const CensusDataPoint({
    required this.period,
    required this.value,
    this.categoryCode,
    this.dataTypeCode,
  });

  double? get numericValue => double.tryParse(value);
}

class CensusRetailRow {
  final String period;
  final String cellValue;
  final String? errorData;
  final String categoryCode;
  final String dataTypeCode;

  const CensusRetailRow({
    required this.period,
    required this.cellValue,
    this.errorData,
    required this.categoryCode,
    required this.dataTypeCode,
  });

  factory CensusRetailRow.fromList(List<dynamic> row, List<String> headers) {
    String get(String key) {
      final i = headers.indexOf(key);
      return i >= 0 ? row[i]?.toString() ?? '' : '';
    }
    return CensusRetailRow(
      period: get('time'),
      cellValue: get('cell_value'),
      errorData: get('error_data'),
      categoryCode: get('category_code'),
      dataTypeCode: get('data_type_code'),
    );
  }

  double? get value => double.tryParse(cellValue);
}

class CensusResponse {
  final List<String> headers;
  final List<List<dynamic>> rows;

  const CensusResponse({required this.headers, required this.rows});

  factory CensusResponse.fromJson(List<dynamic> json) {
    if (json.isEmpty) return const CensusResponse(headers: [], rows: []);
    final headers = (json[0] as List).map((e) => e.toString()).toList();
    final rows = json.skip(1).map((e) => e as List<dynamic>).toList();
    return CensusResponse(headers: headers, rows: rows);
  }

  List<CensusRetailRow> toRetailRows() => rows
      .map((r) => CensusRetailRow.fromList(r, headers))
      .toList();
}

// Census survey/program codes from the PDF
class CensusSurveys {
  // Retail Trade (MARTS) — Monthly Retail Trade Survey
  static const String marts = 'timeseries/eits/marts';

  // Housing & Construction
  static const String newResidentialConstruction = 'timeseries/eits/resconst';
  static const String newResidentialSales = 'timeseries/eits/ressales';
  static const String constructionSpending = 'timeseries/eits/vip';
  static const String housingVacancyRate = 'timeseries/eits/hv';   // CPS/HVS

  // Manufacturing (M3 Survey)
  static const String manufacturersSurveyM3 = 'timeseries/eits/m3';

  // Wholesale Trade
  static const String wholesaleTrade = 'timeseries/eits/mwts';

  // International Trade in Goods (FT-900)
  static const String internationalTradeGoods = 'timeseries/eits/ftd';

  // Demographics
  static const String populationEstimates = '2023/pep/population';
  static const String acsOneYear = '2023/acs/acs1';
  static const String countyBusinessPatterns = '2021/cbp';
  static const String quarterlyWorkforce = 'timeseries/qwi/se';

  // MARTS category codes (kind of business)
  static const String retailTotal = '44X72';         // Total retail & food services
  static const String motorVehicles = '441';
  static const String foodServices = '722';
  static const String nonStore = '454';              // E-commerce / non-store
  static const String buildingMaterials = '444';
  static const String foodBeverage = '445';
  static const String healthPersonalCare = '446';
  static const String gasolineStations = '447';
  static const String clothingApparel = '448';
  static const String sportsHobby = '451';
  static const String generalMerchandise = '452';
  static const String miscRetail = '453';
}
