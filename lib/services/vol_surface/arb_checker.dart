// =============================================================================
// services/vol_surface/arb_checker.dart
// =============================================================================
// Detects two classes of static arbitrage in a volatility surface:
//
//   1. Calendar spread arbitrage
//      Total variance w²(K,T) = σ²(K,T) × T must be non-decreasing in T
//      for every fixed strike K.  A violation means a long calendar spread
//      at that strike generates a riskless profit.
//
//   2. Butterfly arbitrage
//      Call prices C(K) must be convex in K at every fixed T.
//      Discrete check: C(Kᵢ₋₁) − 2·C(Kᵢ) + C(Kᵢ₊₁) ≥ −ε
//      A violation implies a butterfly spread (long wings, short body) costs
//      negative premium — a riskless receipt of cash.
//
// Both checks use a small tolerance (1e-4) to absorb floating-point noise
// and bid-ask spread rounding in raw Schwab data.
//
// Usage:
//   final result = ArbChecker.check(snapshot);
//   if (!result.isArbitrageFree) {
//     // show violations in phase 4 signals
//   }
// =============================================================================

import 'dart:math' as math;
import '../../features/vol_surface/models/vol_surface_models.dart';

// ── Result types ──────────────────────────────────────────────────────────────

class CalendarViolation {
  /// The strike at which the violation occurs.
  final double strike;

  /// Near-term DTE slice.
  final int nearDte;

  /// Far-term DTE slice.
  final int farDte;

  /// Near total variance w²(K, nearT).
  final double nearTotalVar;

  /// Far total variance w²(K, farT).  Should be ≥ nearTotalVar.
  final double farTotalVar;

  /// How much the constraint is violated (nearTotalVar − farTotalVar > 0).
  final double violation;

  const CalendarViolation({
    required this.strike,
    required this.nearDte,
    required this.farDte,
    required this.nearTotalVar,
    required this.farTotalVar,
    required this.violation,
  });

  @override
  String toString() =>
      'Calendar arb: K=\$${strike.toStringAsFixed(1)} '
      '${nearDte}d vs ${farDte}d — '
      'w²=${nearTotalVar.toStringAsFixed(4)} > ${farTotalVar.toStringAsFixed(4)} '
      '(violation: ${violation.toStringAsFixed(4)})';
}

class ButterflyViolation {
  /// DTE of the slice.
  final int dte;

  /// Body strike of the butterfly (the short).
  final double strike;

  /// C(K-h) − 2C(K) + C(K+h) — negative means violation.
  final double convexityValue;

  const ButterflyViolation({
    required this.dte,
    required this.strike,
    required this.convexityValue,
  });

  @override
  String toString() =>
      'Butterfly arb: ${dte}d K=\$${strike.toStringAsFixed(1)} '
      'convexity=${convexityValue.toStringAsFixed(4)} < 0';
}

class ArbCheckResult {
  final List<CalendarViolation>  calendarViolations;
  final List<ButterflyViolation> butterflyViolations;

  const ArbCheckResult({
    required this.calendarViolations,
    required this.butterflyViolations,
  });

  bool get isArbitrageFree =>
      calendarViolations.isEmpty && butterflyViolations.isEmpty;

  int get totalViolations =>
      calendarViolations.length + butterflyViolations.length;

  /// Summary string for use in phase 4 signals.
  String get summary {
    if (isArbitrageFree) return 'Surface is arbitrage-free ✓';
    final parts = <String>[];
    if (calendarViolations.isNotEmpty) {
      parts.add('${calendarViolations.length} calendar arb '
          '${calendarViolations.length == 1 ? 'violation' : 'violations'}');
    }
    if (butterflyViolations.isNotEmpty) {
      parts.add('${butterflyViolations.length} butterfly arb '
          '${butterflyViolations.length == 1 ? 'violation' : 'violations'}');
    }
    return 'Surface arb detected: ${parts.join(', ')}';
  }

  /// Worst calendar violation magnitude (0 if none).
  double get worstCalendarViolation => calendarViolations.isEmpty
      ? 0
      : calendarViolations
            .map((v) => v.violation)
            .reduce(math.max);

  /// Worst butterfly convexity breach (most negative value; 0 if none).
  double get worstButterflyViolation => butterflyViolations.isEmpty
      ? 0
      : butterflyViolations
            .map((v) => v.convexityValue.abs())
            .reduce(math.max);
}

// ── Checker ───────────────────────────────────────────────────────────────────

class ArbChecker {
  ArbChecker._();

  /// Numerical tolerance — absorbs bid-ask noise in raw market data.
  static const double _epsilon = 1e-4;

  /// Risk-free rate used for Black-Scholes call pricing.
  static const double _r = 0.0433;

  /// Run both arb checks on [snap] and return the combined result.
  static ArbCheckResult check(VolSnapshot snap) {
    final points = snap.points;
    final spot   = snap.spotPrice;

    if (points.isEmpty || spot == null || spot <= 0) {
      return const ArbCheckResult(
        calendarViolations:  [],
        butterflyViolations: [],
      );
    }

    return ArbCheckResult(
      calendarViolations:  _checkCalendar(points),
      butterflyViolations: _checkButterfly(points, spot),
    );
  }

  // ── 1. Calendar spread arb ──────────────────────────────────────────────────
  // For each strike, collect (DTE, IV) pairs. Sort by DTE.
  // Check w²(T₁) ≤ w²(T₂) for all consecutive (T₁ < T₂).

  static List<CalendarViolation> _checkCalendar(List<VolPoint> points) {
    // Build map: strike → List<(dte, iv)>
    final byStrike = <double, List<(int, double)>>{};
    for (final p in points) {
      final iv = _otmIv(p);
      if (iv == null || iv <= 0) continue;
      byStrike.putIfAbsent(p.strike, () => []).add((p.dte, iv));
    }

    final violations = <CalendarViolation>[];

    for (final entry in byStrike.entries) {
      final strike = entry.key;
      final slices = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      if (slices.length < 2) continue;

      for (var i = 0; i < slices.length - 1; i++) {
        final (nearDte, nearIv) = slices[i];
        final (farDte,  farIv)  = slices[i + 1];
        final nearT       = nearDte / 365.0;
        final farT        = farDte  / 365.0;
        final nearTotalVar = nearIv * nearIv * nearT;
        final farTotalVar  = farIv  * farIv  * farT;

        // Violation: near total variance > far total variance + tolerance
        final diff = nearTotalVar - farTotalVar;
        if (diff > _epsilon) {
          violations.add(CalendarViolation(
            strike:       strike,
            nearDte:      nearDte,
            farDte:       farDte,
            nearTotalVar: nearTotalVar,
            farTotalVar:  farTotalVar,
            violation:    diff,
          ));
        }
      }
    }

    return violations;
  }

  // ── 2. Butterfly arb ─────────────────────────────────────────────────────────
  // For each DTE slice, sort points by strike.
  // Compute BS call price for each (strike, IV) pair.
  // For each triple of adjacent strikes (K₋, K₀, K₊):
  //   check C(K₋) − 2·C(K₀) + C(K₊) ≥ −ε

  static List<ButterflyViolation> _checkButterfly(
    List<VolPoint> points,
    double         spot,
  ) {
    // Build map: dte → List<(strike, iv)> sorted by strike
    final byDte = <int, List<(double, double)>>{};
    for (final p in points) {
      final iv = _otmIv(p);
      if (iv == null || iv <= 0) continue;
      byDte.putIfAbsent(p.dte, () => []).add((p.strike, iv));
    }

    final violations = <ButterflyViolation>[];

    for (final entry in byDte.entries) {
      final dte    = entry.key;
      final slice  = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      if (slice.length < 3) continue;

      final T = dte / 365.0;
      final F = spot * math.exp(_r * T);

      // Pre-compute call prices for all strikes in this slice
      final callPrices = slice
          .map((s) => _bsCall(F: F, K: s.$1, T: T, sigma: s.$2))
          .toList();

      for (var i = 1; i < slice.length - 1; i++) {
        final convexity = callPrices[i - 1] - 2 * callPrices[i] + callPrices[i + 1];
        if (convexity < -_epsilon) {
          violations.add(ButterflyViolation(
            dte:             dte,
            strike:          slice[i].$1,
            convexityValue:  convexity,
          ));
        }
      }
    }

    return violations;
  }

  // ── Black-Scholes call price (undiscounted forward price) ─────────────────

  static double _bsCall({
    required double F,     // forward price
    required double K,     // strike
    required double T,     // time in years
    required double sigma, // decimal IV
  }) {
    final sqrtT  = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-8) return math.max(F - K, 0) * math.exp(-_r * T);
    final d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sigSqT;
    final d2 = d1 - sigSqT;
    final df = math.exp(-_r * T);
    return df * (F * _cdf(d1) - K * _cdf(d2));
  }

  /// OTM IV: use call IV for strikes ≥ midpoint of [VolPoint.callIv, putIv],
  /// put IV for strikes below. Falls back to whichever is available.
  static double? _otmIv(VolPoint p) =>
      p.callIv ?? p.putIv;

  static double _cdf(double x) => 0.5 * (1 + _erf(x / math.sqrt2));

  static double _erf(double x) {
    const a1 =  0.254829592;
    const a2 = -0.284496736;
    const a3 =  1.421413741;
    const a4 = -1.453152027;
    const a5 =  1.061405429;
    const p  =  0.3275911;
    final s  = x >= 0 ? 1.0 : -1.0;
    final t  = 1.0 / (1.0 + p * x.abs());
    final y  = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t *
        math.exp(-x * x);
    return s * y;
  }
}
