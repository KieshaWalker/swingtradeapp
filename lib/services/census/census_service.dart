import 'package:supabase_flutter/supabase_flutter.dart';
import 'census_models.dart';

class CensusService {
  static final CensusService _instance = CensusService._();
  CensusService._();
  factory CensusService() => _instance;

  // ── Core request ──────────────────────────────────────────────────────────

  Future<CensusResponse> _get(
    String endpoint,
    Map<String, String> params, {
    bool requiresKey = true,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'get-census-data',
      body: {
        'endpoint': endpoint,
        'params': params,
        'requiresKey': requiresKey,
      },
    );
    if (response.status != 200) {
      throw Exception('Census Edge Function error ${response.status}');
    }
    final body = response.data;
    if (body is List) return CensusResponse.fromJson(body);
    throw Exception('Unexpected Census response format');
  }

  // ── Retail Trade (MARTS) ──────────────────────────────────────────────────

  /// Total retail & food services sales (seasonally adjusted)
  Future<CensusResponse> advanceRetailSales({String from = '2020-01'}) => _get(
        CensusSurveys.marts,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,seasonally_adj,geo_level_code',
          'for': 'us:*',
          'time': 'from+$from',
          'category_code': CensusSurveys.retailTotal,
          'data_type_code': 'SM',   // sales in millions
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  /// Retail sales by specific kind of business
  Future<CensusResponse> retailSalesByCategory(
    String categoryCode, {
    String from = '2020-01',
    bool seasonallyAdjusted = true,
  }) =>
      _get(
        CensusSurveys.marts,
        {
          'get': 'cell_value,error_data,category_code,data_type_code',
          'for': 'us:*',
          'time': 'from+$from',
          'category_code': categoryCode,
          'data_type_code': 'SM',
          'seasonally_adj': seasonallyAdjusted ? 'yes' : 'no',
        },
        requiresKey: false,
      );

  Future<CensusResponse> retailSalesMotorVehicles({String from = '2020-01'}) =>
      retailSalesByCategory(CensusSurveys.motorVehicles, from: from);

  Future<CensusResponse> retailSalesFoodServices({String from = '2020-01'}) =>
      retailSalesByCategory(CensusSurveys.foodServices, from: from);

  Future<CensusResponse> retailSalesNonStore({String from = '2020-01'}) =>
      retailSalesByCategory(CensusSurveys.nonStore, from: from);

  // ── Housing & Construction ────────────────────────────────────────────────

  /// New residential construction (housing starts, permits, completions)
  /// EITS endpoints require time as a year and time_slot_id in the get fields.
  Future<CensusResponse> newResidentialConstruction({int fromYear = 2020}) => _get(
        CensusSurveys.newResidentialConstruction,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  /// New residential sales (new home sales level and median price)
  Future<CensusResponse> newResidentialSales({int fromYear = 2020}) => _get(
        CensusSurveys.newResidentialSales,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  /// Value of construction put in place
  Future<CensusResponse> constructionSpending({int fromYear = 2020}) => _get(
        CensusSurveys.constructionSpending,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  // ── Manufacturing (M3 Survey) ─────────────────────────────────────────────

  Future<CensusResponse> manufacturersNewOrders({int fromYear = 2020}) => _get(
        CensusSurveys.manufacturersSurveyM3,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'data_type_code': 'NO',  // new orders
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  Future<CensusResponse> manufacturersShipments({int fromYear = 2020}) => _get(
        CensusSurveys.manufacturersSurveyM3,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'data_type_code': 'NS',  // net shipments
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  Future<CensusResponse> manufacturersInventories({int fromYear = 2020}) => _get(
        CensusSurveys.manufacturersSurveyM3,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'data_type_code': 'EI',  // end-of-period inventories
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  // ── Wholesale Trade ───────────────────────────────────────────────────────

  Future<CensusResponse> wholesaleTradeSales({int fromYear = 2020}) => _get(
        CensusSurveys.wholesaleTrade,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'data_type_code': 'SM',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  Future<CensusResponse> wholesaleTradeInventories({int fromYear = 2020}) => _get(
        CensusSurveys.wholesaleTrade,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'data_type_code': 'EI',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  // ── International Trade in Goods (FT-900) ─────────────────────────────────

  Future<CensusResponse> goodsTradeBalance({int fromYear = 2020}) => _get(
        CensusSurveys.internationalTradeGoods,
        {
          'get': 'cell_value,error_data,category_code,data_type_code,time_slot_id,seasonally_adj',
          'for': 'us:*',
          'time': '$fromYear',
          'seasonally_adj': 'yes',
        },
        requiresKey: false,
      );

  // ── Demographics ──────────────────────────────────────────────────────────

  /// National population estimate (PEP)
  Future<CensusResponse> populationEstimatesNational({int year = 2023}) => _get(
        '$year/pep/population',
        {'get': 'POP_SMSA,NAME', 'for': 'us:*'},
      );

  /// ACS 1-Year: median household income by state
  Future<CensusResponse> acsMedianHouseholdIncome({int year = 2023}) => _get(
        '$year/acs/acs1',
        {'get': 'B19013_001E,NAME', 'for': 'state:*'},
      );

  /// ACS 1-Year: poverty rate by state
  Future<CensusResponse> acsPovertyRate({int year = 2023}) => _get(
        '$year/acs/acs1',
        {'get': 'B17001_002E,B17001_001E,NAME', 'for': 'state:*'},
      );

  /// County Business Patterns
  Future<CensusResponse> countyBusinessPatterns({int year = 2021}) => _get(
        '$year/cbp',
        {
          'get': 'ESTAB,EMP,PAYANN,NAICS2017,NAME',
          'for': 'us:*',
          'NAICS2017': '00',
        },
      );

}
