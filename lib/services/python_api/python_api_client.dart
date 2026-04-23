// =============================================================================
// lib/services/python_api/python_api_client.dart
// =============================================================================
// HTTP client for the Python math backend (FastAPI on Cloud Run).
//
// Configure the base URL at build time:
//   flutter run --dart-define=PYTHON_API_URL=https://swing-options-api-xxx.run.app
//
// Falls back to http://localhost:8000 for local dev.
// On connection error, callers should catch PythonApiException and fall back
// to local Dart math during the transition period.
// =============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;

class PythonApiException implements Exception {
  final String message;
  final int? statusCode;
  const PythonApiException(this.message, {this.statusCode});

  @override
  String toString() => 'PythonApiException($statusCode): $message';
}

class PythonApiClient {
  static const String _base = String.fromEnvironment(
    'PYTHON_API_URL',
    defaultValue: 'http://localhost:8000',
  );

  static final http.Client _http = http.Client();

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_base$path');
    final response = await _http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw PythonApiException(
        response.body,
        statusCode: response.statusCode,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> _postList(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_base$path');
    final response = await _http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw PythonApiException(
        response.body,
        statusCode: response.statusCode,
      );
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  // ── Health ─────────────────────────────────────────────────────────────────

  static Future<bool> isReachable() async {
    try {
      final uri = Uri.parse('$_base/health');
      final response =
          await _http.get(uri).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Black-Scholes ──────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> bsPrice({
    required double s,
    required double k,
    required double t,
    required double sigma,
    required double r,
    required String optionType, // 'call' or 'put'
  }) =>
      _post('/bs/price', {
        's': s,
        'k': k,
        't': t,
        'sigma': sigma,
        'r': r,
        'option_type': optionType,
      });

  static Future<Map<String, dynamic>> bsGreeks({
    required double s,
    required double k,
    required double t,
    required double sigma,
    required double r,
    required String optionType,
  }) =>
      _post('/bs/greeks', {
        's': s,
        'k': k,
        't': t,
        'sigma': sigma,
        'r': r,
        'option_type': optionType,
      });

  // ── SABR ───────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> sabrIv({
    required double alpha,
    required double beta,
    required double rho,
    required double nu,
    required double f,
    required double k,
    required double t,
  }) =>
      _post('/sabr/iv', {
        'alpha': alpha,
        'beta': beta,
        'rho': rho,
        'nu': nu,
        'f': f,
        'k': k,
        't': t,
      });

  /// Returns {slices: [...], error: null}
  /// Each slice: {dte, alpha, beta, rho, nu, rmse}
  static Future<Map<String, dynamic>> sabrCalibrate({
    required List<Map<String, dynamic>> points,
    required double spotPrice,
    double? r,
    String? ticker,
    String? obsDate,
  }) =>
      _post('/sabr/calibrate', {
        'points': points,
        'spot_price': spotPrice,
        'r': ?r,
        'ticker': ?ticker,
        'obs_date': ?obsDate,
      });

  // ── Fair Value ─────────────────────────────────────────────────────────────

  /// Returns {bs_fair_value, sabr_fair_value, model_fair_value, edge_bps,
  ///          sabr_vol, implied_vol, vanna, charm, volga}
  static Future<Map<String, dynamic>> fairValueCompute({
    required double spot,
    required double strike,
    required double impliedVol,   // decimal, e.g. 0.21
    required int    daysToExpiry,
    required bool   isCall,
    required double brokerMid,
    double? r,
    double? calibratedRho,
    double? calibratedNu,
  }) =>
      _post('/fair-value/compute', {
        'spot':            spot,
        'strike':          strike,
        'implied_vol':     impliedVol,
        'days_to_expiry':  daysToExpiry,
        'is_call':         isCall,
        'broker_mid':      brokerMid,
        'r': ?r,
        'calibrated_rho': ?calibratedRho,
        'calibrated_nu':  ?calibratedNu,
      });

  // ── IV Analytics ───────────────────────────────────────────────────────────

  /// Returns full analytics dict: gex_by_strike, total_gex, zero_gamma, etc.
  static Future<Map<String, dynamic>> ivAnalytics({
    required Map<String, dynamic> chain,
    required double spotPrice,
    List<Map<String, dynamic>>? history,
  }) =>
      _post('/iv/analytics', {
        'chain': chain,
        'spot_price': spotPrice,
        'history': ?history,
      });

  /// Same as ivAnalytics but also persists to Supabase iv_snapshots table.
  static Future<Map<String, dynamic>> ivSnapshot({
    required Map<String, dynamic> chain,
    required double spotPrice,
    required String ticker,
    List<Map<String, dynamic>>? history,
    String? obsDate,
  }) =>
      _post('/iv/snapshot', {
        'chain': chain,
        'spot_price': spotPrice,
        'ticker': ticker,
        'history': ?history,
        'obs_date': ?obsDate,
      });

  // ── Realized Vol ───────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> realizedVolCompute({
    required List<double> closes,
    List<double>? historyRv20d,
    List<double>? historyRv60d,
  }) =>
      _post('/realized-vol/compute', {
        'closes': closes,
        'history_rv20d': historyRv20d ?? [],
        'history_rv60d': historyRv60d ?? [],
      });

  // ── Arbitrage Check ────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> arbCheck({
    required List<Map<String, dynamic>> points,
    required double spotPrice,
    double? r,
  }) =>
      _post('/arb/check', {
        'points': points,
        'spot_price': spotPrice,
        'r': ?r,
      });

  // ── Scoring ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> scoringScore({
    required Map<String, dynamic> contract,
    required double underlyingPrice,
    Map<String, dynamic>? ivAnalysis,
  }) =>
      _post('/scoring/score', {
        'contract': contract,
        'underlying_price': underlyingPrice,
        'iv_analysis': ?ivAnalysis,
      });

  static Future<List<dynamic>> scoringRank({
    required Map<String, dynamic> chain,
    required double underlyingPrice,
    Map<String, dynamic>? ivAnalysis,
    int topN = 10,
  }) =>
      _postList('/scoring/rank', {
        'chain': chain,
        'underlying_price': underlyingPrice,
        'iv_analysis': ?ivAnalysis,
        'top_n': topN,
      });

  // ── Decision ───────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> decisionAnalyze({
    required Map<String, dynamic> contract,
    required double underlyingPrice,
    required String direction, // 'bullish' | 'bearish' | 'neutral'
    required double priceTarget,
    required double maxBudget,
    int contracts = 1,
    Map<String, dynamic>? ivAnalysis,
  }) =>
      _post('/decision/analyze', {
        'contract': contract,
        'underlying_price': underlyingPrice,
        'direction': direction,
        'price_target': priceTarget,
        'max_budget': maxBudget,
        'contracts': contracts,
        'iv_analysis': ?ivAnalysis,
      });

  static Future<List<dynamic>> decisionRankAll({
    required Map<String, dynamic> chain,
    required String direction,
    required double priceTarget,
    required double maxBudget,
    int contracts = 1,
    Map<String, dynamic>? ivAnalysis,
    int topN = 5,
  }) =>
      _postList('/decision/rank-all', {
        'chain': chain,
        'direction': direction,
        'price_target': priceTarget,
        'max_budget': maxBudget,
        'contracts': contracts,
        'iv_analysis': ?ivAnalysis,
        'top_n': topN,
      });

  // ── Regime ML ──────────────────────────────────────────────────────────────

  /// POST /regime/ml-analyze
  /// Reads historical regime_snapshots from Supabase, computes ML transition
  /// features, and returns 4-bucket categorised results for all tracked tickers.
  static Future<Map<String, dynamic>> regimeMlAnalyze() =>
      _post('/regime/ml-analyze', {});

  /// POST /regime/train
  /// Triggers supervised model training from Supabase history.
  /// [modelType]: "logistic" | "xgboost"
  static Future<Map<String, dynamic>> regimeMlTrain({
    String modelType = 'logistic',
    int historyDays = 180,
  }) =>
      _post('/regime/train', {
        'model_type':   modelType,
        'history_days': historyDays,
      });

  // ── Macro Score ────────────────────────────────────────────────────────────

  /// Returns {total, regime, has_enough_data, used_z_scores, components: [...]}
  static Future<Map<String, dynamic>> macroScore() =>
      _post('/macro/score', {});

  // ── Greek Grid ─────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> greekGridIngest({
    required Map<String, dynamic> chain,
    String? obsDate,
    String? ticker,
  }) =>
      _post('/greek-grid/ingest', {
        'chain': chain,
        'obs_date': ?obsDate,
        'ticker': ?ticker,
      });

  /// Returns InterpretationResult dict: headline, headline_signal, today, period, period_obs
  static Future<Map<String, dynamic>> greekGridInterpretGrid({
    required List<Map<String, dynamic>> gridCells,
  }) =>
      _post('/greek-grid/interpret-grid', {'grid_cells': gridCells});

  /// Returns InterpretationResult dict: headline, headline_signal, today, period, period_obs
  static Future<Map<String, dynamic>> greekGridInterpretChart({
    required List<Map<String, dynamic>> chartHistory,
    required int dteBucket,
  }) =>
      _post('/greek-grid/interpret-chart', {
        'chart_history': chartHistory,
        'dte_bucket': dteBucket,
      });
}
