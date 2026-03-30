import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/kalshi_config.dart';
import 'bea_models.dart';

class BeaService {
  static final BeaService _instance = BeaService._();
  BeaService._();
  factory BeaService() => _instance;

  final _client = http.Client();

  // ── Core request ──────────────────────────────────────────────────────────

  // BEA requires explicit year list e.g. "2021,2022,2023,2024,2025"
  static String _yearRange(int years) {
    final now = DateTime.now().year;
    return List.generate(years, (i) => now - (years - 1) + i).join(',');
  }

  Future<BeaResponse> _getNipa({
    required String tableName,
    required String lineNumber,
    String frequency = 'Q',
    required String year,
  }) async {
    final uri = Uri.parse(BeaConfig.baseUrl).replace(queryParameters: {
      'UserID': BeaConfig.apiKey,
      'method': 'GetData',
      'DataSetName': 'NIPA',
      'TableName': tableName,
      'LineNumber': lineNumber,
      'Frequency': frequency,
      'Year': year,
      'ResultFormat': 'JSON',
    });
    final response = await _client.get(uri);
    _checkStatus(response);
    return BeaResponse.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<BeaResponse> _getRegional({
    required String tableName,
    String geoFips = 'STATE',
    required String year,
  }) async {
    final uri = Uri.parse(BeaConfig.baseUrl).replace(queryParameters: {
      'UserID': BeaConfig.apiKey,
      'method': 'GetData',
      'DataSetName': 'Regional',
      'TableName': tableName,
      'GeoFips': geoFips,
      'Year': year,
      'ResultFormat': 'JSON',
    });
    final response = await _client.get(uri);
    _checkStatus(response);
    return BeaResponse.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<BeaResponse> _getDataset({
    required String datasetName,
    required Map<String, String> extraParams,
  }) async {
    final uri = Uri.parse(BeaConfig.baseUrl).replace(queryParameters: {
      'UserID': BeaConfig.apiKey,
      'method': 'GetData',
      'DataSetName': datasetName,
      'ResultFormat': 'JSON',
      ...extraParams,
    });
    final response = await _client.get(uri);
    _checkStatus(response);
    return BeaResponse.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ── GDP & Components (NIPA T10101 — % change) ────────────────────────────

  Future<BeaResponse> gdpPercentChange({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '1', year: _yearRange(years));

  Future<BeaResponse> personalConsumptionExpenditures({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '2', year: _yearRange(years));

  Future<BeaResponse> pceGoods({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '3', year: _yearRange(years));

  Future<BeaResponse> pceServices({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '6', year: _yearRange(years));

  Future<BeaResponse> grossPrivateInvestment({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '7', year: _yearRange(years));

  Future<BeaResponse> fixedInvestmentNonresidential({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '8', year: _yearRange(years));

  Future<BeaResponse> fixedInvestmentResidential({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '12', year: _yearRange(years));

  Future<BeaResponse> changeInInventories({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '13', year: _yearRange(years));

  Future<BeaResponse> netExports({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '14', year: _yearRange(years));

  Future<BeaResponse> governmentSpending({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '17', year: _yearRange(years));

  Future<BeaResponse> federalSpending({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '18', year: _yearRange(years));

  Future<BeaResponse> stateLocalSpending({int years = 5}) =>
      _getNipa(tableName: 'T10101', lineNumber: '21', year: _yearRange(years));

  // ── GDP Levels (T10105) ───────────────────────────────────────────────────

  Future<BeaResponse> gdpCurrentDollars({int years = 5}) =>
      _getNipa(tableName: 'T10105', lineNumber: '1', year: _yearRange(years));

  Future<BeaResponse> gnp({int years = 5}) =>
      _getNipa(tableName: 'T10105', lineNumber: '26', year: _yearRange(years));

  Future<BeaResponse> grossNationalIncome({int years = 5}) =>
      _getNipa(tableName: 'T10105', lineNumber: '27', year: _yearRange(years));

  // ── Real GDP (T10106) ─────────────────────────────────────────────────────

  Future<BeaResponse> realGdp({int years = 5}) =>
      _getNipa(tableName: 'T10106', lineNumber: '1', year: _yearRange(years));

  // ── GDP Deflator (T10109) ─────────────────────────────────────────────────

  Future<BeaResponse> gdpDeflator({int years = 5}) =>
      _getNipa(tableName: 'T10109', lineNumber: '1', year: _yearRange(years));

  // ── Personal Income (T20100) ──────────────────────────────────────────────

  Future<BeaResponse> personalIncome({String frequency = 'M', int years = 3}) =>
      _getNipa(tableName: 'T20100', lineNumber: '1', frequency: frequency, year: _yearRange(years));

  Future<BeaResponse> disposablePersonalIncome({String frequency = 'M', int years = 3}) =>
      _getNipa(tableName: 'T20100', lineNumber: '27', frequency: frequency, year: _yearRange(years));

  Future<BeaResponse> personalSaving({String frequency = 'M', int years = 3}) =>
      _getNipa(tableName: 'T20100', lineNumber: '34', frequency: frequency, year: _yearRange(years));

  // ── Corporate Profits (T10901) ────────────────────────────────────────────

  Future<BeaResponse> corporateProfitsPreTax({int years = 5}) =>
      _getNipa(tableName: 'T10901', lineNumber: '1', year: _yearRange(years));

  Future<BeaResponse> corporateProfitsAfterTax({int years = 5}) =>
      _getNipa(tableName: 'T10901', lineNumber: '11', year: _yearRange(years));

  // ── PCE Price Index (T20804) ──────────────────────────────────────────────

  Future<BeaResponse> pcePriceIndex({String frequency = 'M', int years = 3}) =>
      _getNipa(tableName: 'T20804', lineNumber: '1', frequency: frequency, year: _yearRange(years));

  Future<BeaResponse> corePcePriceIndex({String frequency = 'M', int years = 3}) =>
      _getNipa(tableName: 'T20804', lineNumber: '24', frequency: frequency, year: _yearRange(years));

  // ── Regional Data ─────────────────────────────────────────────────────────

  Future<BeaResponse> personalIncomeByState({int years = 3}) =>
      _getRegional(tableName: 'SAINC1', year: _yearRange(years));

  Future<BeaResponse> gdpByState({int years = 3}) =>
      _getRegional(tableName: 'SAGDP1', year: _yearRange(years));

  Future<BeaResponse> personalIncomeByCounty({int years = 3}) =>
      _getRegional(tableName: 'CAINC1', geoFips: 'COUNTY', year: _yearRange(years));

  Future<BeaResponse> perCapitaIncomeByCounty({int years = 3}) =>
      _getRegional(tableName: 'CAINC4', geoFips: 'COUNTY', year: _yearRange(years));

  Future<BeaResponse> gdpByCountyMetro({int years = 3}) =>
      _getRegional(tableName: 'CAGDP1', geoFips: 'COUNTY', year: _yearRange(years));

  // ── International Transactions (ITA) ─────────────────────────────────────

  Future<BeaResponse> internationalTransactions({int years = 5}) =>
      _getDataset(datasetName: 'ITA', extraParams: {
        'Indicator': 'CurrentAccount',
        'AreaOrCountry': 'AllCountries',
        'Frequency': 'Q',
        'Year': _yearRange(years),
      });

  // ── International Investment Position (IIP) ───────────────────────────────

  Future<BeaResponse> internationalInvestmentPosition({int years = 5}) =>
      _getDataset(datasetName: 'IIP', extraParams: {
        'TypeOfInvestment': 'FinancialAccount',
        'Component': 'All',
        'Frequency': 'Q',
        'Year': _yearRange(years),
      });

  // ── Fixed Assets ──────────────────────────────────────────────────────────

  Future<BeaResponse> fixedAssetsAndConsumerDurables({int years = 5}) =>
      _getDataset(datasetName: 'FixedAssets', extraParams: {
        'TableName': 'FAAt101',
        'Year': _yearRange(years),
      });

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _checkStatus(http.Response r) {
    if (r.statusCode != 200) {
      throw Exception('BEA API error ${r.statusCode}: ${r.body}');
    }
  }
}
