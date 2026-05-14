// =============================================================================
// lib/services/python_api/python_api_client.dart
// =============================================================================
// HTTP client for the Python math backend (FastAPI on Cloud Run).
//
// This file maps Dart feature calls to backend route names and payload shapes.
// When a backend schema changes, update the matching method here and any
// callers that build request bodies or consume response objects.
//
// Backend route mappings:
//   /bs/price                -> api/routers/black_scholes.py
//   /bs/greeks               -> api/routers/black_scholes.py
//   /sabr/iv                 -> api/routers/sabr.py
//   /sabr/calibrate          -> api/routers/sabr.py
//   /heston/price            -> api/routers/heston.py
//   /fair-value/compute      -> api/routers/fair_value.py
//   /iv/analytics            -> api/routers/iv_analytics.py
//   /iv/snapshot             -> api/routers/iv_analytics.py
//   /realized-vol/compute    -> api/routers/realized_vol.py
//   /arb/check               -> api/routers/arb.py
//   /scoring/score           -> api/routers/scoring.py
//   /scoring/rank            -> api/routers/scoring.py
//   /decision/analyze        -> api/routers/decision.py
//   /decision/rank-all       -> api/routers/decision.py
//   /regime/ml-analyze       -> api/routers/regime.py
//   /regime/train            -> api/routers/regime.py
//   /macro/score             -> api/routers/macro.py
//   /greek-grid/interpret-grid  -> api/routers/greek_grid.py
//   /greek-grid/interpret-chart -> api/routers/greek_grid.py
//
// If a new Python backend feature is added, expose a Dart method here and
// update the calling widget/provider to use the new response shape.
// =============================================================================
// Configure the base URL at build time:
//   flutter run --dart-define=PYTHON_API_URL=https://swing-options-api-xxx.run.app
//
// Falls back to http://localhost:8000 for local dev.
// On connection error, callers should catch PythonApiException and fall back
// to local Dart math during the transition period.
// =============================================================================

import 'dart:async';
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
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw PythonApiException('Request timed out', statusCode: 408),
        );

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
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw PythonApiException('Request timed out', statusCode: 408),
        );

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

  static Future<Map<String, dynamic>> _get(String path) async {
    final uri = Uri.parse('$_base$path');
    final response = await _http
        .get(uri)
        .timeout(const Duration(seconds: 10),
            onTimeout: () =>
                throw PythonApiException('Request timed out', statusCode: 408));
    if (response.statusCode != 200) {
      throw PythonApiException(response.body, statusCode: response.statusCode);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Rates ──────────────────────────────────────────────────────────────────

  /// Returns the live 30-day SOFR average from the backend cache (decimal → pct).
  static Future<double> getSofr() async {
    final data = await _get('/jobs/sofr');
    final rates = data['rates'] as Map<String, dynamic>;
    final sofr = rates['30-day SOFR avg'] as Map<String, dynamic>;
    return (sofr['rate_pct'] as num).toDouble();
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
        'spot':           s,
        'strike':         k,
        'days_to_expiry': (t * 365).round().clamp(1, 9999),
        'implied_vol':    sigma,
        'r':              r,
        'is_call':        optionType == 'call',
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
        'spot': s,
        'strike': k,
        'days_to_expiry': (t * 365).round().clamp(1, 9999),
        'implied_vol': sigma,
        'r': r,
        'is_call': optionType == 'call',
      });

  /// Returns {implied_vol, implied_vol_pct, price_check, forward, delta, gamma,
  ///          theta, vega, rho, vanna, charm, vomma}
  /// Throws PythonApiException(422) when the price violates no-arbitrage bounds.
  static Future<Map<String, dynamic>> bsImpliedVol({
    required double marketPrice,
    required double s,
    required double k,
    required int dte,
    required double r,
    required String optionType,
    double initialGuess = 0.25,
  }) =>
      _post('/bs/iv', {
        'market_price':   marketPrice,
        'spot':           s,
        'strike':         k,
        'days_to_expiry': dte.clamp(1, 9999),
        'r':              r,
        'is_call':        optionType == 'call',
        'initial_guess':  initialGuess,
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
        'F': f,        // Pydantic field name is uppercase F
        'strike': k,   // Pydantic field name is 'strike', not 'k'
        'T': t,        // Pydantic field name is uppercase T
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

  // ── Heston ────────────────────────────────────────────────────────────────

  /// Returns {price, forward, initial_vol, long_run_vol, feller_satisfied}
  static Future<Map<String, dynamic>> hestonPrice({
    required double spot,
    required double strike,
    required int daysToExpiry,
    required double r,
    required bool isCall,
    required double kappa,
    required double theta,
    required double xi,
    required double rho,
    required double v0,
  }) =>
      _post('/heston/price', {
        'spot': spot,
        'strike': strike,
        'days_to_expiry': daysToExpiry,
        'r': r,
        'is_call': isCall,
        'kappa': kappa,
        'theta': theta,
        'xi': xi,
        'rho': rho,
        'v0': v0,
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
    String? ticker,               // when provided, Heston params are fetched from DB
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
        'ticker': ?ticker,
      });

  // ── IV Analytics ───────────────────────────────────────────────────────────

  /// Returns full analytics dict: gex_by_strike, total_gex, zero_gamma, etc.
  /// spot_price is read from chain['underlyingPrice'] by the API — not a separate param.
  static Future<Map<String, dynamic>> ivAnalytics({
    required Map<String, dynamic> chain,
    List<Map<String, dynamic>>? history,
  }) =>
      _post('/iv/analytics', {
        'chain': chain,
        'history': ?history,
      });

  /// Same as ivAnalytics but also persists to Supabase iv_snapshots table.
  static Future<Map<String, dynamic>> ivSnapshot({
    required Map<String, dynamic> chain,
    required String ticker,
    List<Map<String, dynamic>>? history,
    String? obsDate,
  }) =>
      _post('/iv/snapshot', {
        'chain': chain,
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
    int daysToTarget = 0,
    Map<String, dynamic>? ivAnalysis,
    int topN = 5,
  }) =>
      _postList('/decision/rank-all', {
        'chain': chain,
        'direction': direction,
        'price_target': priceTarget,
        'max_budget': maxBudget,
        'contracts': contracts,
        'days_to_target': daysToTarget,
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

  /// Returns {total, regime, has_enough_data, used_z_scores, weights_source, components: [...]}
  static Future<Map<String, dynamic>> macroScore() =>
      _post('/macro/score', {});

  // ── Greek Grid ─────────────────────────────────────────────────────────────

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
