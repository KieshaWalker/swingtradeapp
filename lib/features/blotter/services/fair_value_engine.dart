// =============================================================================
// features/blotter/services/fair_value_engine.dart
// =============================================================================
// Portfolio state loader + what-if arithmetic.
// Pricing is handled by the Python /fair-value/compute endpoint.
// =============================================================================

import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/blotter_models.dart';

class FairValueEngine {
  // Portfolio risk limits
  static const double deltaThreshold = 500.0; // max |portfolio delta| in $-delta
  static const double _es95Mult      = 2.063;  // φ(1.645)/0.05

  // ── Portfolio what-if (pure arithmetic) ──────────────────────────────────

  static WhatIfResult computeWhatIf({
    required PortfolioState current,
    required double delta,
    required double gamma,
    required double vega,
    required double spot,
    required int    quantity,
    required double impliedVol,
    required int    daysToExpiry,
  }) {
    final T      = daysToExpiry / 365.0;
    final posDelta = delta * quantity * 100;
    final posGamma = gamma * quantity * 100;
    final posVega  = vega  * quantity * 100;

    final es95Impact = _es95(
      delta: posDelta,
      gamma: posGamma,
      spot:  spot,
      sigma: impliedVol,
      T:     T,
    );

    return WhatIfResult(
      deltaImpact:           posDelta,
      vegaImpact:            posVega,
      es95Impact:            es95Impact,
      newDelta:              current.totalDelta + posDelta,
      newVega:               current.totalVega  + posVega,
      newEs95:               current.totalEs95  + es95Impact,
      exceedsDeltaThreshold: (current.totalDelta + posDelta).abs() > deltaThreshold,
      deltaThreshold:        deltaThreshold,
    );
  }

  // ── Portfolio state (Supabase) ────────────────────────────────────────────

  static Future<PortfolioState> loadPortfolioState() async {
    try {
      final rows = await Supabase.instance.client
          .from('blotter_trades')
          .select('delta,vega,quantity,es95_after,status')
          .inFilter('status', ['committed', 'sent']);

      double totalDelta = 0;
      double totalVega  = 0;
      double latestEs   = 0;

      for (final r in rows) {
        final qty = (r['quantity'] as int? ?? 0);
        totalDelta += (r['delta'] as num? ?? 0).toDouble() * qty * 100;
        totalVega  += (r['vega']  as num? ?? 0).toDouble() * qty * 100;
        final es = (r['es95_after'] as num? ?? 0).toDouble();
        latestEs += es;
      }

      return PortfolioState(
        totalDelta:    totalDelta,
        totalVega:     totalVega,
        totalEs95:     latestEs,
        openPositions: rows.length,
      );
    } catch (_) {
      return PortfolioState.empty;
    }
  }

  // ── ES₉₅ helper ──────────────────────────────────────────────────────────

  static double _es95({
    required double delta,
    required double gamma,
    required double spot,
    required double sigma,
    required double T,
  }) {
    final sqrtT   = math.sqrt(T);
    final deltaEs = delta.abs() * spot * sigma * sqrtT * _es95Mult;
    final gammaEs = 0.5 * gamma.abs() * spot * spot * sigma * sigma * T * 1.5;
    return deltaEs + gammaEs;
  }
}
