// =============================================================================
// services/iv/realized_vol_models.dart
// =============================================================================
// Data models for Realized Volatility (Historical Volatility) Analysis.
//
// Realized Volatility is computed from daily log returns:
//   RV_n = √(Σ(ln(P_i/P_{i-1}))² / (n-1)) over n-day rolling window
//
// Used in Phase 4 (Vol Surface Gate) to detect:
//   • IV < RV → selling premium is risky (market moving more than IV prices in)
//   • IV > RV → buying premium is cheap (good volatility buying opportunity)
//
//  RealizedVolResult   — computed live from price history + IV history
//  RealizedVolSnapshot — one row from realized_vol_snapshots Supabase table
// =============================================================================

/// Computed RV analysis (from RealizedVolService.compute)
class RealizedVolResult {
  // Historical volatility over rolling windows (decimal, e.g., 0.32 = 32%)
  final double rv20d; // 20-day realized vol
  final double rv60d; // 60-day realized vol

  // Percentile ranking within 52-week history (0–100)
  // Example: 75 = today's 20d RV is in the 75th percentile historically
  final double? rv20dPercentile;
  final double? rv60dPercentile;

  // Rating derived from current vs historical range
  final RealizedVolRating rating;

  // Raw history for charting
  final List<double> rv20dHistory; // trailing 20 values for sparkline
  final List<double> rv60dHistory; // trailing 60 values for sparkline

  // Timestamp when computed
  final DateTime computedAt;

  const RealizedVolResult({
    required this.rv20d,
    required this.rv60d,
    this.rv20dPercentile,
    this.rv60dPercentile,
    required this.rating,
    required this.rv20dHistory,
    required this.rv60dHistory,
    required this.computedAt,
  });

  factory RealizedVolResult.fromJson(Map<String, dynamic> j) {
    final ratingStr = j['rating'] as String? ?? 'no_data';
    final rating = switch (ratingStr) {
      'extreme'      => RealizedVolRating.extreme,
      'elevated'     => RealizedVolRating.elevated,
      'normal'       => RealizedVolRating.normal,
      'suppressed'   => RealizedVolRating.suppressed,
      'extreme_low'  => RealizedVolRating.extremeLow,
      _              => RealizedVolRating.noData,
    };
    return RealizedVolResult(
      rv20d:           (j['rv20d'] as num).toDouble(),
      rv60d:           (j['rv60d'] as num).toDouble(),
      rv20dPercentile: (j['rv20d_percentile'] as num?)?.toDouble(),
      rv60dPercentile: (j['rv60d_percentile'] as num?)?.toDouble(),
      rating:          rating,
      rv20dHistory:    (j['rv20d_history'] as List? ?? []).map((v) => (v as num).toDouble()).toList(),
      rv60dHistory:    (j['rv60d_history'] as List? ?? []).map((v) => (v as num).toDouble()).toList(),
      computedAt:      DateTime.now().toUtc(),
    );
  }

  /// Check if we have enough historical data to be confident in the ranking
  bool get hasEnoughData => rv20dPercentile != null && rv60dPercentile != null;

  /// Summary for UI: "RV at 65th percentile" or "RV: 32% (insufficient history)"
  String get summaryText {
    if (!hasEnoughData) {
      return 'RV: ${(rv20d * 100).toStringAsFixed(1)}% (< 52w data)';
    }
    return 'RV: ${(rv20d * 100).toStringAsFixed(1)}% (${rv20dPercentile!.toStringAsFixed(0)}th pct)';
  }
}

/// Cheapness/expensiveness of realized vol relative to history
enum RealizedVolRating {
  extreme, // rv20d > 80th percentile — very high realized moves
  elevated, // rv20d 60–80th percentile
  normal, // rv20d 30–60th percentile
  suppressed, // rv20d 15–30th percentile — market is quiet
  extremeLow, // rv20d < 15th percentile — historically very low vol
  noData,
}

extension RealizedVolRatingX on RealizedVolRating {
  String get label => switch (this) {
    RealizedVolRating.extreme => 'Extreme',
    RealizedVolRating.elevated => 'Elevated',
    RealizedVolRating.normal => 'Normal',
    RealizedVolRating.suppressed => 'Suppressed',
    RealizedVolRating.extremeLow => 'Extremely Low',
    RealizedVolRating.noData => 'No Data',
  };

  String get description => switch (this) {
    RealizedVolRating.extreme =>
      'Realized moves are at historic highs. IV must be expensive to compensate.',
    RealizedVolRating.elevated =>
      'Realized vol elevated. Selling premium is risky; buying may be cheap.',
    RealizedVolRating.normal => 'Realized vol is in normal historical range.',
    RealizedVolRating.suppressed =>
      'Market is quiet. Selling premium is possibly undercompensated.',
    RealizedVolRating.extremeLow =>
      'Realized moves are historically low. IV might be overpriced.',
    RealizedVolRating.noData =>
      'Insufficient history — check back after 60+ trading days.',
  };
}

/// One row from realized_vol_snapshots table (daily batch persisted)
class RealizedVolSnapshot {
  final String symbol;
  final DateTime date; // observation date (UTC, normalized to midnight)
  final double rv20d; // 20-day RV on that date
  final double rv60d; // 60-day RV on that date
  final double? rv20dPercentile; // percentile rank (null if < 10 obs)
  final double? rv60dPercentile;
  final DateTime persistedAt;

  const RealizedVolSnapshot({
    required this.symbol,
    required this.date,
    required this.rv20d,
    required this.rv60d,
    this.rv20dPercentile,
    this.rv60dPercentile,
    required this.persistedAt,
  });

  /// Serialize to Supabase
  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'date': date.toIso8601String(),
    'rv_20d': rv20d,
    'rv_60d': rv60d,
    'rv_20d_percentile': rv20dPercentile,
    'rv_60d_percentile': rv60dPercentile,
    'persisted_at': persistedAt.toIso8601String(),
  };

  /// Deserialize from Supabase
  factory RealizedVolSnapshot.fromJson(Map<String, dynamic> j) =>
      RealizedVolSnapshot(
        symbol: j['symbol'] as String,
        date: DateTime.parse(j['date'] as String),
        rv20d: (j['rv_20d'] as num).toDouble(),
        rv60d: (j['rv_60d'] as num).toDouble(),
        rv20dPercentile: (j['rv_20d_percentile'] as num?)?.toDouble(),
        rv60dPercentile: (j['rv_60d_percentile'] as num?)?.toDouble(),
        persistedAt: DateTime.parse(j['persisted_at'] as String),
      );
}
