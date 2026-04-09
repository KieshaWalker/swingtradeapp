// =============================================================================
// features/trades/services/live_greeks_service.dart
// =============================================================================
// Recomputes a full set of option Greeks in real-time using Black-Scholes,
// given a trade's current spot price and implied volatility.
//
// Why recompute instead of using Schwab's Greeks?
//   Schwab's Greeks are snapshot values from the last chain refresh. For open
//   trades, the underlying spot, IV, and DTE all shift continuously. This
//   service recomputes from first principles so the displayed Greeks always
//   reflect the current market state.
//
// Standard Greeks (closed-form BS):
//   Delta  = N(d1)              for calls
//          = N(d1) − 1          for puts
//   Gamma  = N'(d1) / (S·σ·√T)
//   Theta  = [−S·N'(d1)·σ / (2√T) − r·K·e^{−rT}·N(d2)]  / 365  for calls
//            [−S·N'(d1)·σ / (2√T) + r·K·e^{−rT}·N(−d2)] / 365  for puts
//   Vega   = S·√T·N'(d1) / 100          (per 1% IV move)
//
// Second-order Greeks (from IvAnalyticsService formulas):
//   Vanna  = −Gamma·S·√T·d2
//   Charm  =  Gamma·S·(r·d1/σ − d2/(2T)) / 365
//   Volga  =  Vega·d1·d2 / σ   (×100 to un-scale Vega back)
//
// Dividend adjustment (Task 10):
//   When dividendYield q > 0, the forward price used in d1/d2 becomes:
//     F = S·e^{(r−q)T}
//   Which modifies d1 = (ln(S/K) + (r − q + 0.5σ²)T) / (σ√T)
//   Delta calls: e^{−qT}·N(d1)   Delta puts: e^{−qT}·(N(d1)−1)
//
// Usage:
//   final g = LiveGreeksService.compute(
//     trade: trade,
//     spot: 185.40,
//     currentIv: 0.28,         // as decimal (28%)
//     riskFreeRate: 0.0433,
//     dividendYield: 0.0125,   // optional; defaults to 0
//   );
// =============================================================================

import 'dart:math' as math;
import '../models/trade.dart';

// ── Result type ───────────────────────────────────────────────────────────────

class LiveGreeks {
  final double delta;
  final double gamma;
  final double theta;   // daily (per calendar day)
  final double vega;    // per 1% IV move
  final double vanna;
  final double charm;
  final double volga;
  final double impliedVol;  // the IV used (decimal)
  final double dteRemaining;

  const LiveGreeks({
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.vanna,
    required this.charm,
    required this.volga,
    required this.impliedVol,
    required this.dteRemaining,
  });

  bool get isCall => delta > 0;
}

// ── Service ───────────────────────────────────────────────────────────────────

class LiveGreeksService {
  static const double _minT = 1 / (365 * 24 * 60); // 1-minute floor

  /// Compute live Greeks for [trade] given current market conditions.
  /// [currentIv] is in decimal form (e.g. 0.28 for 28%).
  /// [dividendYield] is continuous annual yield (e.g. 0.015 for 1.5%).
  static LiveGreeks compute({
    required Trade trade,
    required double spot,
    required double currentIv,
    double riskFreeRate = 0.0433,
    double dividendYield = 0.0,
  }) {
    final isCall = trade.optionType == OptionType.call;
    final K = trade.strike;
    final S = spot;
    final sigma = currentIv.clamp(0.001, 5.0);
    final r = riskFreeRate;
    final q = dividendYield;

    // Time to expiration in fractional years (minute precision).
    final now = DateTime.now();
    final minutesLeft =
        trade.expiration.difference(now).inMinutes.toDouble();
    final T = math.max(_minT, minutesLeft / (365 * 24 * 60));
    final sqrtT = math.sqrt(T);

    // d1, d2 with dividend adjustment.
    final d1 = (math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) /
        (sigma * sqrtT);
    final d2 = d1 - sigma * sqrtT;

    // Standard normal helpers.
    final nd1  = _cdf(d1);
    final nd2  = _cdf(d2);
    final npd1 = _pdf(d1);  // N'(d1)
    final eqT  = math.exp(-q * T);
    final erT  = math.exp(-r * T);

    // Delta (dividend-adjusted).
    final delta = isCall ? eqT * nd1 : eqT * (nd1 - 1.0);

    // Gamma (same for calls and puts).
    final gamma = eqT * npd1 / (S * sigma * sqrtT);

    // Theta (per calendar day).
    final thetaBase = -S * eqT * npd1 * sigma / (2 * sqrtT);
    final theta = isCall
        ? (thetaBase - r * K * erT * nd2 + q * S * eqT * nd1) / 365
        : (thetaBase + r * K * erT * _cdf(-d2) - q * S * eqT * _cdf(-d1)) /
            365;

    // Vega (per 1% IV move).
    final vega = S * eqT * sqrtT * npd1 / 100.0;

    // Second-order Greeks.
    final vanna = -gamma * S * sqrtT * d2;
    final charm = gamma * S * ((r - q) * d1 / sigma - d2 / (2 * T)) / 365;
    final volga = vega * 100 * d1 * d2 / sigma; // vega back to full scale

    return LiveGreeks(
      delta: delta,
      gamma: gamma,
      theta: theta,
      vega: vega,
      vanna: vanna,
      charm: charm,
      volga: volga,
      impliedVol: currentIv,
      dteRemaining: T * 365,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Standard normal CDF via Abramowitz & Stegun approximation (error < 7.5e-8).
  static double _cdf(double x) {
    if (x < -8) return 0;
    if (x > 8) return 1;
    const p = 0.2316419;
    const b1 = 0.319381530;
    const b2 = -0.356563782;
    const b3 = 1.781477937;
    const b4 = -1.821255978;
    const b5 = 1.330274429;
    final t = 1.0 / (1.0 + p * x.abs());
    final poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))));
    final cdf = 1.0 - _pdf(x) * poly;
    return x >= 0 ? cdf : 1.0 - cdf;
  }

  /// Standard normal PDF.
  static double _pdf(double x) =>
      math.exp(-0.5 * x * x) / math.sqrt(2 * math.pi);
}
