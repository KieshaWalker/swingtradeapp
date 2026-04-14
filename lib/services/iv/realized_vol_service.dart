// =============================================================================
// services/iv/realized_vol_service.dart
// =============================================================================
// Pure math service: no I/O, no Supabase.
// Computes Realized Volatility (historical vol of daily log returns) from
// price history and ranks it against 52-week history.
//
// Formula:
//   RV_n = √(Σ(ln(P_i / P_{i-1}))² / (n-1))
//
// where:
//   P_i = close price on day i
//   n = number of days in window
//   (n-1) = sample variance Bessel correction
//
// Typical usage:
//   service.compute(currentPrice, dailyCloses, history)
//   → RealizedVolResult with rv20d, rv60d, percentiles, rating
// =============================================================================

import 'dart:math' as math;
import '../economy/economy_snapshot_models.dart' show QuoteSnapshot;
import 'realized_vol_models.dart';

class RealizedVolService {
  /// Default windows for rolling vol computation
  static const int window20d = 20;
  static const int window60d = 60;

  /// Minimum history required for confident percentile ranking
  static const int minHistoryForPercentile = 10;

  /// Compute RV from a list of daily close prices (sorted ascending by date).
  ///
  /// [closes] should be sorted ascending (oldest first).
  /// Returns RealizedVolResult with rv20d, rv60d, percentiles, rating.
  static RealizedVolResult compute(
    List<double> closes, {
    List<RealizedVolSnapshot>? history,
  }) {
    if (closes.length < 2) {
      return _emptyResult('< 2 price points');
    }

    // Compute 20-day and 60-day RV from current closes
    final rv20d = closes.length >= window20d
        ? _computeRv(closes.sublist(closes.length - window20d))
        : _computeRv(closes);

    final rv60d = closes.length >= window60d
        ? _computeRv(closes.sublist(closes.length - window60d))
        : _computeRv(closes);

    // Extract historical RV values to rank against (if provided)
    final historicalRv20d = <double>[];
    final historicalRv60d = <double>[];

    if (history != null && history.isNotEmpty) {
      for (final snap in history) {
        historicalRv20d.add(snap.rv20d);
        historicalRv60d.add(snap.rv60d);
      }
    }

    // Compute percentile ranks
    final rv20dPct = historicalRv20d.length >= minHistoryForPercentile
        ? _computePercentile(rv20d, historicalRv20d)
        : null;

    final rv60dPct = historicalRv60d.length >= minHistoryForPercentile
        ? _computePercentile(rv60d, historicalRv60d)
        : null;

    // Rate the current RV
    final rating = _rateRealizedVol(rv20dPct ?? 50); // use 50th if no history

    // Build history for sparklines (trailing 20/60 values)
    final rv20dHistory = historicalRv20d.isNotEmpty
        ? historicalRv20d.sublist(math.max(0, historicalRv20d.length - 20))
        : [rv20d]; // fallback to current
    final rv60dHistory = historicalRv60d.isNotEmpty
        ? historicalRv60d.sublist(math.max(0, historicalRv60d.length - 60))
        : [rv60d];

    return RealizedVolResult(
      rv20d: rv20d,
      rv60d: rv60d,
      rv20dPercentile: rv20dPct,
      rv60dPercentile: rv60dPct,
      rating: rating,
      rv20dHistory: rv20dHistory,
      rv60dHistory: rv60dHistory,
      computedAt: DateTime.now().toUtc(),
    );
  }

  /// Compute RV from QuoteSnapshots (sorted ascending by date)
  static RealizedVolResult computeFromQuotes(
    List<QuoteSnapshot> quotes, {
    List<RealizedVolSnapshot>? history,
  }) {
    final closes = quotes.map((q) => q.price).toList();
    return compute(closes, history: history);
  }

  /// Pure math: compute n-day realized volatility
  /// [prices] should have ≥ 2 elements, sorted oldest first
  static double _computeRv(List<double> prices) {
    if (prices.length < 2) return 0.0;

    double sumSquaredReturns = 0.0;
    for (int i = 1; i < prices.length; i++) {
      final logReturn = math.log(prices[i] / prices[i - 1]);
      sumSquaredReturns += logReturn * logReturn;
    }

    // Sample variance: divide by (n-1) for Bessel correction
    final variance = sumSquaredReturns / (prices.length - 1);
    final annualizedRv = math.sqrt(variance * 252); // 252 trading days/year
    return annualizedRv;
  }

  /// Compute percentile rank: "what % of historical values are ≤ current?"
  /// Example: if 75 out of 100 historical RVs are ≤ current, return 75.0
  static double _computePercentile(double current, List<double> history) {
    if (history.isEmpty) return 50.0;

    int countBelow = 0;
    for (final val in history) {
      if (val <= current) countBelow++;
    }
    return (countBelow / history.length) * 100.0;
  }

  /// Rate RV level based on percentile
  static RealizedVolRating _rateRealizedVol(double percentile) {
    if (percentile > 80) return RealizedVolRating.extreme;
    if (percentile > 60) return RealizedVolRating.elevated;
    if (percentile > 40) return RealizedVolRating.normal;
    if (percentile > 15) return RealizedVolRating.suppressed;
    return RealizedVolRating.extremeLow;
  }

  static RealizedVolResult _emptyResult(String reason) {
    return RealizedVolResult(
      rv20d: 0.0,
      rv60d: 0.0,
      rv20dPercentile: null,
      rv60dPercentile: null,
      rating: RealizedVolRating.noData,
      rv20dHistory: [],
      rv60dHistory: [],
      computedAt: DateTime.now().toUtc(),
    );
  }
}
