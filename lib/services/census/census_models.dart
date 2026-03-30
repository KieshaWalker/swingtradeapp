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
  static const String newResidentialConstruction = 'eits/sopr';
  static const String newResidentialSales = 'eits/ressales';
  static const String constructionSpending = 'eits/vip';
  static const String housingVacancyRate = 'eits/hv';   // CPS/HVS

  // Manufacturing (M3 Survey)
  static const String manufacturersSurveyM3 = 'eits/m3';

  // Wholesale Trade
  static const String wholesaleTrade = 'eits/mwts';

  // International Trade in Goods (FT-900)
  static const String internationalTradeGoods = 'eits/ftd';

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
