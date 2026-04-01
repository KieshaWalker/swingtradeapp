// =============================================================================
// services/macro/macro_score_service.dart
// =============================================================================
// Reads Supabase tables and computes the 8-component macro score.
//
// Data source priority (FRED preferred over FMP where available):
//   VIX       → VIXCLS (FRED) › VIXY (FMP)
//   2s10s     → fred_t10y2y (FRED direct) › economy_treasury_snapshots calc
//   Fed Funds → fred_dff (FRED daily) › federalFunds (FMP monthly)
//   HY OAS    → fred_bamlh0a0hym2 (FRED bps, inverted)
//   IG OAS    → fred_bamlc0a0cm (FRED bps, inverted)
//   SPY Trend → SPY (FMP — no FRED alternative)
//   Dollar    → UUP (FMP — no FRED alternative)
//   Gold/Cu   → GOLDAMGBD228NLBM (FRED gold) + COPX (FMP copper)
//
// Z-score normalization (per component):
//   Z = (current − μ) / σ  over rolling history (up to 252 obs)
//   pct = (clamp(Z, −3, 3) + 3) / 6  → [0, 1] → × maxScore
//   Inverted for metrics where high = bad (VIX, spreads, DXY).
//   Falls back to threshold scoring when < 10 observations exist.
//
// Score weights (total = 100 pts):
//   VIX       20   Yield Curve  15   Fed Trajectory  15
//   SPY Trend 15   Dollar       10   HY OAS          10
//   IG OAS     5   Gold/Copper  10
// =============================================================================

import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../fred/fred_models.dart';
import 'macro_score_model.dart';

class MacroScoreService {
  final SupabaseClient _db;
  MacroScoreService(this._db);

  Future<MacroScore> computeScore() async {
    final results = await Future.wait([
      _vixComponent(),
      _yieldCurveComponent(),
      _fedTrajectoryComponent(),
      _spyTrendComponent(),
      _dollarComponent(),
      _hyOasComponent(),
      _igOasComponent(),
      _goldCopperComponent(),
    ]);

    final components = results.whereType<MacroSubScore>().toList();
    final hasEnough = components.length == 8;
    final total = components.fold<double>(0, (s, c) => s + c.score);
    final zScoredCount = components.where((c) => c.zScored).length;

    return MacroScore(
      total: total,
      regime: MacroScore.regimeFor(total),
      components: components,
      computedAt: DateTime.now(),
      hasEnoughData: hasEnough,
      usedZScores: zScoredCount >= 5,
    );
  }

  // ─── Z-score helpers ──────────────────────────────────────────────────────

  static const int _minHistory = 10;
  static const int _maxHistory = 252;

  double? _z(double current, List<double> history) {
    if (history.length < _minHistory) return null;
    final mean = history.reduce((a, b) => a + b) / history.length;
    final variance = history
            .map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) /
        history.length;
    final std = math.sqrt(variance);
    if (std < 0.0001) return 0;
    return (current - mean) / std;
  }

  double _zToScore(double? z, double maxScore, {bool invert = false}) {
    if (z == null) return maxScore / 2;
    final adjusted = invert ? -z : z;
    final pct = ((adjusted.clamp(-3.0, 3.0) + 3) / 6).clamp(0.0, 1.0);
    return pct * maxScore;
  }

  // ─── Data fetch helpers ───────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _quoteHistory(String symbol) async =>
      _db
          .from('economy_quote_snapshots')
          .select('date, price')
          .eq('symbol', symbol)
          .order('date', ascending: false)
          .limit(_maxHistory);

  Future<List<Map<String, dynamic>>> _indicatorHistory(
          String identifier) async =>
      _db
          .from('economy_indicator_snapshots')
          .select('date, value')
          .eq('identifier', identifier)
          .order('date', ascending: false)
          .limit(_maxHistory);

  // ─── 1. VIX Level — 20 pts ───────────────────────────────────────────────
  // Prefers FRED VIXCLS (actual VIX index) over FMP VIXY (ETF proxy).
  // Higher VIX = more fear = bad for risk → inverted.

  Future<MacroSubScore> _vixComponent() async {
    // FRED VIXCLS stored in quote_snapshots with symbol = 'VIXCLS'
    var rows = await _quoteHistory(FredSeriesIds.vix);
    final source = rows.isNotEmpty ? 'VIX' : 'VIXY';
    if (rows.isEmpty) rows = await _quoteHistory('VIXY');
    if (rows.isEmpty) return _noData('VIX Level', 20);

    final values = rows.map((r) => (r['price'] as num).toDouble()).toList();
    final current = values.first;
    final z = _z(current, values.sublist(1));
    final score = _zToScore(z, 20, invert: true);

    // VIX actual thresholds (VIXCLS is the real index ~10–80)
    // VIXY is roughly VIX/10 — Z-score handles normalization either way
    final isVixScale = source == 'VIX';
    final level = isVixScale
        ? (current < 12
            ? 'Very Low'
            : current < 17
                ? 'Low'
                : current < 22
                    ? 'Elevated'
                    : current < 30
                        ? 'High'
                        : 'Extreme')
        : (current < 10
            ? 'Very Low'
            : current < 14
                ? 'Low'
                : current < 18
                    ? 'Elevated'
                    : current < 24
                        ? 'High'
                        : 'Extreme');

    return MacroSubScore(
      name: 'VIX Level',
      description: 'Fear gauge — lower = more bullish',
      score: score,
      maxScore: 20,
      signal: '$source ${current.toStringAsFixed(2)} — $level Fear'
          '${z != null ? ' · ${values.length}d' : ''}',
      detail: score >= 10
          ? 'Vol subdued — supports risk-taking'
          : 'Elevated vol signals institutional hedging',
      isPositive: score >= 10,
      zScored: z != null,
    );
  }

  // ─── 2. Yield Curve 2s10s — 15 pts ───────────────────────────────────────
  // Prefers FRED T10Y2Y (pre-computed spread %) over treasury snapshot calc.

  Future<MacroSubScore> _yieldCurveComponent() async {
    // Try FRED direct spread first
    var rows = await _indicatorHistory(FredStorageIds.spread2s10s);
    bool fromFred = rows.isNotEmpty;

    List<double> spreads;
    if (fromFred) {
      spreads = rows.map((r) => (r['value'] as num).toDouble()).toList();
    } else {
      // Fall back to computing from treasury snapshots
      final tRows = await _db
          .from('economy_treasury_snapshots')
          .select('date, year2, year10')
          .order('date', ascending: false)
          .limit(_maxHistory);
      spreads = tRows
          .where((r) => r['year2'] != null && r['year10'] != null)
          .map((r) =>
              (r['year10'] as num).toDouble() - (r['year2'] as num).toDouble())
          .toList();
    }

    if (spreads.isEmpty) return _noData('Yield Curve 2s10s', 15);

    final current = spreads.first;
    final z = _z(current, spreads.sublist(1));
    final score = _zToScore(z, 15);

    final shape = current > 1.5
        ? 'Steep (+${current.toStringAsFixed(2)}%)'
        : current > 0.5
            ? 'Positive (+${current.toStringAsFixed(2)}%)'
            : current > 0
                ? 'Flat (+${current.toStringAsFixed(2)}%)'
                : current > -0.5
                    ? 'Inverted (${current.toStringAsFixed(2)}%)'
                    : 'Deeply Inverted (${current.toStringAsFixed(2)}%)';

    return MacroSubScore(
      name: 'Yield Curve 2s10s',
      description: '10Y minus 2Y treasury spread',
      score: score,
      maxScore: 15,
      signal: '10Y−2Y: $shape'
          '${z != null ? ' · ${spreads.length}d' : ''}'
          '${fromFred ? ' · FRED' : ''}',
      detail: current > 0
          ? 'Normal curve — expansion environment'
          : 'Inverted — recession probability elevated',
      isPositive: current > 0,
      zScored: z != null,
    );
  }

  // ─── 3. Fed Trajectory — 15 pts ──────────────────────────────────────────
  // Prefers FRED DFF (daily effective fed funds) over FMP monthly data.

  Future<MacroSubScore> _fedTrajectoryComponent() async {
    var rows = await _indicatorHistory(FredStorageIds.fedFunds);
    bool fromFred = rows.isNotEmpty;
    if (rows.isEmpty) {
      rows = await _indicatorHistory('federalFunds');
    }
    if (rows.length < 2) return _noData('Fed Trajectory', 15);

    final values = rows.map((r) => (r['value'] as num).toDouble()).toList();
    final latest = values.first;

    // 6-month delta; with daily FRED data that's ~126 rows; FMP monthly = 6
    final lookback = fromFred
        ? (values.length >= 126 ? 125 : values.length - 1)
        : (values.length >= 6 ? 5 : values.length - 1);
    final prior = values[lookback];
    final delta = latest - prior;

    // Rolling deltas for Z-score
    final step = fromFred ? 126 : 6;
    final deltas = <double>[];
    for (var i = 0; i + step < values.length; i++) {
      deltas.add(values[i] - values[i + step]);
    }

    final z = _z(delta, deltas);
    final score = _zToScore(z, 15, invert: true);

    final trend = delta < -0.5
        ? 'Easing (−${(-delta).toStringAsFixed(2)}%)'
        : delta < 0
            ? 'Slightly Easing (−${(-delta).toStringAsFixed(2)}%)'
            : delta.abs() < 0.1
                ? 'Holding (${latest.toStringAsFixed(2)}%)'
                : delta < 0.5
                    ? 'Tightening (+${delta.toStringAsFixed(2)}%)'
                    : 'Aggressive Hike (+${delta.toStringAsFixed(2)}%)';

    return MacroSubScore(
      name: 'Fed Trajectory',
      description: 'Fed funds 6-month trend',
      score: score,
      maxScore: 15,
      signal: 'FFR ${latest.toStringAsFixed(2)}% — $trend'
          '${z != null ? ' · ${values.length}d' : ''}'
          '${fromFred ? ' · FRED' : ''}',
      detail: delta < 0
          ? 'Easing cycle supports equity valuations'
          : delta.abs() < 0.1
              ? 'Fed on hold — neutral for markets'
              : 'Tightening cycle pressures risk assets',
      isPositive: delta <= 0.1,
      zScored: z != null,
    );
  }

  // ─── 4. SPY Trend — 15 pts ───────────────────────────────────────────────

  Future<MacroSubScore> _spyTrendComponent() async {
    final rows = await _quoteHistory('SPY');
    if (rows.length < 5) return _noData('SPY Trend', 15);

    final prices = rows.map((r) => (r['price'] as num).toDouble()).toList();
    final latest = prices.first;

    final deviations = <double>[];
    for (var i = 0; i + 30 < prices.length; i++) {
      final window = prices.sublist(i + 1, i + 31);
      final ma = window.reduce((a, b) => a + b) / window.length;
      deviations.add(((prices[i] - ma) / ma) * 100);
    }

    final maLength = prices.length < 31 ? prices.length - 1 : 30;
    final ma30 =
        prices.sublist(1, maLength + 1).reduce((a, b) => a + b) / maLength;
    final currentDev = ((latest - ma30) / ma30) * 100;

    final z = _z(currentDev, deviations.isNotEmpty ? deviations.sublist(1) : []);
    final score = _zToScore(z, 15);

    final trend = currentDev > 3
        ? 'Strong Uptrend (+${currentDev.toStringAsFixed(1)}%)'
        : currentDev > 1
            ? 'Above MA (+${currentDev.toStringAsFixed(1)}%)'
            : currentDev > -1
                ? 'Near MA (${currentDev.toStringAsFixed(1)}%)'
                : currentDev > -3
                    ? 'Below MA (${currentDev.toStringAsFixed(1)}%)'
                    : 'Downtrend (${currentDev.toStringAsFixed(1)}%)';

    return MacroSubScore(
      name: 'SPY Trend',
      description: 'Price vs 30-day moving average',
      score: score,
      maxScore: 15,
      signal: 'SPY \$${latest.toStringAsFixed(2)} — $trend'
          '${z != null ? ' · ${deviations.length}d' : ''}',
      detail: currentDev > 0
          ? 'Above 30d MA — trend intact'
          : 'Below 30d MA — momentum deteriorating',
      isPositive: currentDev > -1,
      zScored: z != null,
    );
  }

  // ─── 5. Dollar (UUP) — 10 pts ────────────────────────────────────────────

  Future<MacroSubScore> _dollarComponent() async {
    final rows = await _quoteHistory('UUP');
    if (rows.length < 5) return _noData('Dollar (DXY)', 10);

    final prices = rows.map((r) => (r['price'] as num).toDouble()).toList();
    final latest = prices.first;

    final changes = <double>[];
    for (var i = 0; i + 30 < prices.length; i++) {
      changes.add(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100);
    }

    final lookback = prices.length < 31 ? prices.length - 1 : 30;
    final currentChange = ((latest - prices[lookback]) / prices[lookback]) * 100;

    final z = _z(currentChange, changes.isNotEmpty ? changes.sublist(1) : []);
    final score = _zToScore(z, 10, invert: true);

    final trend = currentChange < -3
        ? 'Falling (${currentChange.toStringAsFixed(1)}%)'
        : currentChange < -1
            ? 'Weakening (${currentChange.toStringAsFixed(1)}%)'
            : currentChange.abs() <= 1
                ? 'Stable (${currentChange.toStringAsFixed(1)}%)'
                : currentChange < 3
                    ? 'Strengthening (+${currentChange.toStringAsFixed(1)}%)'
                    : 'Strong Rally (+${currentChange.toStringAsFixed(1)}%)';

    return MacroSubScore(
      name: 'Dollar (DXY)',
      description: 'UUP 30-day trend — weak dollar = risk-on',
      score: score,
      maxScore: 10,
      signal: 'UUP \$${latest.toStringAsFixed(2)} — $trend'
          '${z != null ? ' · ${changes.length}d' : ''}',
      detail: currentChange < 0
          ? 'Falling dollar supports global risk assets'
          : currentChange.abs() <= 1
              ? 'Dollar stable — neutral for risk'
              : 'Rising dollar creates headwinds',
      isPositive: currentChange < 1,
      zScored: z != null,
    );
  }

  // ─── 6. HY Credit OAS — 10 pts ───────────────────────────────────────────
  // FRED BAMLH0A0HYM2 — ICE BofA HY Option-Adjusted Spread (bps).
  // Higher spread = wider credit = fear = bad → inverted.
  // Falls back to HYG price trend if FRED data not yet loaded.

  Future<MacroSubScore> _hyOasComponent() async {
    var rows = await _indicatorHistory(FredStorageIds.hyOas);
    bool fromFred = rows.isNotEmpty;

    if (fromFred) {
      final values = rows.map((r) => (r['value'] as num).toDouble()).toList();
      final current = values.first;
      final z = _z(current, values.sublist(1));
      final score = _zToScore(z, 10, invert: true);

      final level = current < 300
          ? 'Tight (<300 bps)'
          : current < 450
              ? 'Normal (${current.toStringAsFixed(0)} bps)'
              : current < 700
                  ? 'Wide (${current.toStringAsFixed(0)} bps)'
                  : 'Stressed (${current.toStringAsFixed(0)} bps)';

      return MacroSubScore(
        name: 'HY Credit OAS',
        description: 'ICE BofA HY spread — tighter = risk-on',
        score: score,
        maxScore: 10,
        signal: 'HY OAS ${current.toStringAsFixed(0)} bps — $level'
            '${z != null ? ' · ${values.length}d · FRED' : ' · FRED'}',
        detail: current < 400
            ? 'Credit market healthy — spreads contained'
            : 'Spreads elevated — credit stress building',
        isPositive: current < 500,
        zScored: z != null,
      );
    }

    // Fallback: HYG price trend
    final hygRows = await _quoteHistory('HYG');
    if (hygRows.length < 5) return _noData('HY Credit OAS', 10);

    final prices = hygRows.map((r) => (r['price'] as num).toDouble()).toList();
    final latest = prices.first;
    final changes = <double>[];
    for (var i = 0; i + 30 < prices.length; i++) {
      changes.add(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100);
    }
    final lb = prices.length < 31 ? prices.length - 1 : 30;
    final currentChange = ((latest - prices[lb]) / prices[lb]) * 100;
    final z = _z(currentChange, changes.isNotEmpty ? changes.sublist(1) : []);
    final score = _zToScore(z, 10);

    return MacroSubScore(
      name: 'HY Credit OAS',
      description: 'HYG price trend (FRED loading…)',
      score: score,
      maxScore: 10,
      signal: 'HYG \$${latest.toStringAsFixed(2)} · ${currentChange >= 0 ? '+' : ''}${currentChange.toStringAsFixed(1)}%',
      detail: currentChange > 0
          ? 'Credit improving — risk appetite expanding'
          : 'Credit weakening — watch for equity lag',
      isPositive: currentChange > -0.5,
      zScored: z != null,
    );
  }

  // ─── 7. IG Credit OAS — 5 pts ────────────────────────────────────────────
  // FRED BAMLC0A0CM — ICE BofA IG Option-Adjusted Spread (bps).
  // Investment grade spreads are tighter but still signal regime shifts.

  Future<MacroSubScore> _igOasComponent() async {
    final rows = await _indicatorHistory(FredStorageIds.igOas);
    if (rows.isEmpty) return _noData('IG Credit OAS', 5);

    final values = rows.map((r) => (r['value'] as num).toDouble()).toList();
    final current = values.first;
    final z = _z(current, values.sublist(1));
    final score = _zToScore(z, 5, invert: true);

    final level = current < 80
        ? 'Tight (<80 bps)'
        : current < 130
            ? 'Normal (${current.toStringAsFixed(0)} bps)'
            : current < 200
                ? 'Wide (${current.toStringAsFixed(0)} bps)'
                : 'Stressed (${current.toStringAsFixed(0)} bps)';

    return MacroSubScore(
      name: 'IG Credit OAS',
      description: 'ICE BofA IG spread — tighter = risk-on',
      score: score,
      maxScore: 5,
      signal: 'IG OAS ${current.toStringAsFixed(0)} bps — $level'
          '${z != null ? ' · ${values.length}d · FRED' : ' · FRED'}',
      detail: current < 130
          ? 'IG spreads benign — investment grade healthy'
          : 'IG spreads elevated — broad credit concern',
      isPositive: current < 150,
      zScored: z != null,
    );
  }

  // ─── 8. Gold/Copper — 10 pts ─────────────────────────────────────────────
  // Copper outperforming gold = growth signal. Uses FRED gold if available.

  Future<MacroSubScore> _goldCopperComponent() async {
    // Prefer FRED gold (GOLDAMGBD228NLBM); fall back to FMP GC=F
    var goldRows = await _quoteHistory(FredSeriesIds.gold);
    final goldSource = goldRows.isNotEmpty ? 'FRED Gold' : 'GC=F';
    if (goldRows.isEmpty) goldRows = await _quoteHistory('GC=F');

    // Copper: COPX from FMP (no daily copper price on FRED)
    final copxRows = await _quoteHistory('COPX');

    if (goldRows.length < 5 || copxRows.length < 5) {
      return _noData('Gold/Copper', 10);
    }

    final goldPrices = goldRows.map((r) => (r['price'] as num).toDouble()).toList();
    final copxPrices = copxRows.map((r) => (r['price'] as num).toDouble()).toList();

    double pctChange(List<double> prices) {
      final lb = prices.length < 31 ? prices.length - 1 : 30;
      return ((prices.first - prices[lb]) / prices[lb]) * 100;
    }

    final goldChange = pctChange(goldPrices);
    final copxChange = pctChange(copxPrices);
    final differential = copxChange - goldChange;

    final minLen = math.min(copxPrices.length, goldPrices.length);
    final diffs = <double>[];
    for (var i = 0; i + 30 < minLen; i++) {
      final c = ((copxPrices[i] - copxPrices[i + 30]) / copxPrices[i + 30]) * 100;
      final g = ((goldPrices[i] - goldPrices[i + 30]) / goldPrices[i + 30]) * 100;
      diffs.add(c - g);
    }

    final z = _z(differential, diffs.isNotEmpty ? diffs.sublist(1) : []);
    final score = _zToScore(z, 10);

    final trend = differential > 5
        ? 'Copper Leading (+${differential.toStringAsFixed(1)}%)'
        : differential > 1
            ? 'Copper Outperforming (+${differential.toStringAsFixed(1)}%)'
            : differential.abs() <= 1
                ? 'Neutral (${differential.toStringAsFixed(1)}%)'
                : differential > -5
                    ? 'Gold Outperforming (${differential.toStringAsFixed(1)}%)'
                    : 'Gold Dominant (${differential.toStringAsFixed(1)}%)';

    return MacroSubScore(
      name: 'Gold/Copper',
      description: 'COPX vs gold — copper outperformance = growth',
      score: score,
      maxScore: 10,
      signal: 'Cu−Au spread: $trend · $goldSource'
          '${z != null ? ' · ${diffs.length}d' : ''}',
      detail: differential > 0
          ? 'Copper leading gold — industrial demand intact'
          : 'Gold leading copper — risk-off / growth concern',
      isPositive: differential > -1,
      zScored: z != null,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  MacroSubScore _noData(String name, double maxScore) => MacroSubScore(
        name: name,
        description: '',
        score: maxScore / 2,
        maxScore: maxScore,
        signal: 'No data — will populate over time',
        detail: 'Insufficient history in Supabase',
        isPositive: true,
        zScored: false,
      );
}
