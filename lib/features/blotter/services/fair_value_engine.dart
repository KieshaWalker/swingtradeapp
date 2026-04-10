// =============================================================================
// features/blotter/services/fair_value_engine.dart
// =============================================================================
// Internal pricing engine for the Trade Blotter.
//
// Model hierarchy:
//   1. Black-Scholes (baseline, using market IV)
//   2. SABR (Hagan et al. 2002) — captures the vol smile / skew
//   3. Heston correction — accounts for stochastic vol mean-reversion
//
// The "Edge" is (ModelFairValue - BrokerMid) / BrokerMid × 10,000 bps.
// Positive edge = model prices the contract above the broker mid → BUY signal.
//
// SABR parameters are calibrated to typical US equity vol surface:
//   β = 0.5 (square-root CEV — standard for equity)
//   ρ = −0.7 (negative skew correlation, empirically observed)
//   ν = 0.40 (vol-of-vol, typical for liquid equity options)
//
// Heston parameters (simplified expansion, not full characteristic function):
//   κ = 2.0  (mean-reversion speed)
//   ξ = 0.5  (vol-of-vol)
//   ρ_H = −0.7 (stochastic-vol / spot correlation)
//
// Expected Shortfall (ES₉₅) for a position:
//   ES₉₅ = |Δ| × S × σ × √T × φ(z₉₅)/(1−0.95)
//         + ½ |Γ| × S² × σ² × T × 1.5   (convexity correction)
//   where φ(1.645)/0.05 ≈ 2.063 is the ES₉₅ multiplier.
// =============================================================================

import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/blotter_models.dart';

class FairValueEngine {
  static const double _defaultR = 0.0433; // ~4.33% SOFR

  // SABR calibration
  static const double _sabrBeta = 0.5;
  static const double _sabrRho = -0.7;
  static const double _sabrNu = 0.40;

  // Heston calibration
  static const double _hestonKappa = 2.0;
  static const double _hestonXi = 0.50;
  static const double _hestonRho = -0.70;

  // Portfolio risk limits
  static const double deltaThreshold =
      500.0; // max |portfolio delta| in $-delta
  static const double _es95Mult = 2.063; // φ(1.645)/0.05

  // ── Public entry point ────────────────────────────────────────────────────

  static FairValueResult compute({
    required double spot,
    required double strike,
    required double impliedVol, // decimal (e.g. 0.21)
    required int daysToExpiry,
    required bool isCall,
    required double brokerMid,
    double r = _defaultR,
  }) {
    if (daysToExpiry <= 0 || impliedVol <= 0) {
      return FairValueResult(
        bsFairValue: brokerMid,
        sabrFairValue: brokerMid,
        modelFairValue: brokerMid,
        brokerMid: brokerMid,
        edgeBps: 0,
        sabrVol: impliedVol,
        impliedVol: impliedVol,
      );
    }

    final T = daysToExpiry / 365.0;
    final F = spot * math.exp(r * T); // forward price

    // 1. Black-Scholes baseline
    final bsPrice = _bsPrice(F, strike, T, r, impliedVol, isCall);

    // 2. SABR smile-adjusted vol and price
    final alpha = _sabrAlpha(impliedVol, F, _sabrBeta);
    final sabrVol = _sabrIv(
      F: F,
      K: strike,
      T: T,
      alpha: alpha,
      beta: _sabrBeta,
      rho: _sabrRho,
      nu: _sabrNu,
    );
    final sabrVol_ = sabrVol.clamp(0.01, 5.0); // guard
    final sabrPrice = _bsPrice(F, strike, T, r, sabrVol_, isCall);

    // 3. Heston correction (first-order stochastic vol expansion)
    final vanna = _bsVanna(F, strike, T, sabrVol_, isCall);
    final vomma = _bsVomma(F, strike, T, r, sabrVol_, isCall);
    final charm = _bsCharm(F, strike, T, r, sabrVol_, isCall);
    final hestonDelta = _hestonCorrection(T, vanna, vomma);
    final modelPrice = (sabrPrice + hestonDelta).clamp(0.0, double.infinity);

    final edgeBps = brokerMid > 0.001
        ? (modelPrice - brokerMid) / brokerMid * 10000
        : 0.0;

    return FairValueResult(
      bsFairValue: bsPrice,
      sabrFairValue: sabrPrice,
      modelFairValue: modelPrice,
      brokerMid: brokerMid,
      edgeBps: edgeBps,
      sabrVol: sabrVol_,
      impliedVol: impliedVol,
      vanna: vanna,
      charm: charm,
      volga: vomma,
    );
  }

  // ── Portfolio what-if ─────────────────────────────────────────────────────

  static WhatIfResult computeWhatIf({
    required PortfolioState current,
    required double delta, // per-contract delta from Schwab
    required double gamma,
    required double vega,
    required double spot,
    required int quantity,
    required double impliedVol,
    required int daysToExpiry,
  }) {
    final T = daysToExpiry / 365.0;
    final sigma = impliedVol; // already decimal

    // Position-level Greeks (contract size = 100 shares)
    final posDelta = delta * quantity * 100;
    final posGamma = gamma * quantity * 100;
    final posVega = vega * quantity * 100;

    final es95Impact = _es95(
      delta: posDelta,
      gamma: posGamma,
      spot: spot,
      sigma: sigma,
      T: T,
    );

    final newDelta = current.totalDelta + posDelta;
    final newVega = current.totalVega + posVega;
    final newEs95 = current.totalEs95 + es95Impact;

    return WhatIfResult(
      deltaImpact: posDelta,
      vegaImpact: posVega,
      es95Impact: es95Impact,
      newDelta: newDelta,
      newVega: newVega,
      newEs95: newEs95,
      exceedsDeltaThreshold: newDelta.abs() > deltaThreshold,
      deltaThreshold: deltaThreshold,
    );
  }

  static Future<PortfolioState> loadPortfolioState() async {
    try {
      final rows = await Supabase.instance.client
          .from('blotter_trades')
          .select('delta,vega,quantity,es95_after,status')
          .inFilter('status', ['committed', 'sent']);

      double totalDelta = 0;
      double totalVega = 0;
      double latestEs = 0;

      for (final r in rows) {
        final qty = (r['quantity'] as int? ?? 0);
        final d = (r['delta'] as num? ?? 0).toDouble();
        final v = (r['vega'] as num? ?? 0).toDouble();
        totalDelta += d * qty * 100;
        totalVega += v * qty * 100;
        final es = (r['es95_after'] as num? ?? 0).toDouble();
        if (es > latestEs) latestEs = es; // use highest snapshot
      }

      return PortfolioState(
        totalDelta: totalDelta,
        totalVega: totalVega,
        totalEs95: latestEs,
        openPositions: rows.length,
      );
    } catch (_) {
      return PortfolioState.empty;
    }
  }

  // ── Black-Scholes ─────────────────────────────────────────────────────────

  static double _bsPrice(
    double F,
    double K,
    double T,
    double r,
    double sigma,
    bool isCall,
  ) {
    final sqrtT = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-8) {
      final pv = isCall
          ? math.max(F - K, 0) * math.exp(-r * T)
          : math.max(K - F, 0) * math.exp(-r * T);
      return pv;
    }
    final d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sigSqT;
    final d2 = d1 - sigSqT;
    final df = math.exp(-r * T);
    return isCall
        ? df * (F * _cdf(d1) - K * _cdf(d2))
        : df * (K * _cdf(-d2) - F * _cdf(-d1));
  }

  // BS Vanna: ∂²V/∂S∂σ — needed for Heston correction
  static double _bsVanna(
    double F,
    double K,
    double T,
    double sigma,
    bool isCall,
  ) {
    final sqrtT = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-8 || T < 1e-8) return 0;
    final d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sigSqT;
    final d2 = d1 - sigSqT;
    return -_phi(d1) * d2 / sigma; // Vanna = -φ(d₁)·d₂/σ
  }

  // BS Charm: ∂Δ/∂T — uses forward price F for d1/d2, consistent with the rest of the model.
  static double _bsCharm(
    double F, // forward price Se^{rT}
    double K,
    double T,
    double r,
    double sigma,
    bool isCall,
  ) {
    final sqrtT = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-8 || T < 1e-8) return 0;
    final d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sigSqT;
    final d2 = d1 - sigSqT;
    final df = math.exp(-r * T);
    return -df *
        _phi(d1) *
        (2 * r * T - d2 * sigma * sqrtT) /
        (2 * sigma * sqrtT);
  }

  // BS Vomma (Volga): ∂²V/∂σ² — needed for Heston correction
  static double _bsVomma(
    double F,
    double K,
    double T,
    double r,
    double sigma,
    bool isCall,
  ) {
    final sqrtT = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-8 || T < 1e-8) return 0;
    final d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sigSqT;
    final d2 = d1 - sigSqT;
    final vega = F * math.exp(-r * T) * _phi(d1) * sqrtT;
    return vega * d1 * d2 / sigma;
  }

  // ── SABR Model ────────────────────────────────────────────────────────────
  // Hagan et al. (2002) lognormal SABR implied-vol approximation.

  static double _sabrAlpha(double atmIv, double f, double beta) {
    // Back out alpha from ATM vol:  σ_ATM ≈ α / F^(1-β)
    return atmIv * math.pow(f, 1 - beta).toDouble();
  }

  static double _sabrIv({
    required double F,
    required double K,
    required double T,
    required double alpha,
    required double beta,
    required double rho,
    required double nu,
  }) {
    if (alpha <= 0 || T <= 0) return 0;

    final logFK = math.log(F / K);
    final absLog = logFK.abs();

    // ATM case
    if (absLog < 1e-6) {
      final fBeta = math.pow(F, 1 - beta).toDouble();
      final t1 =
          math.pow(1 - beta, 2) /
          24 *
          alpha *
          alpha /
          math.pow(F, 2 * (1 - beta));
      final t2 = rho * beta * nu * alpha / (4 * fBeta);
      final t3 = (2 - 3 * rho * rho) * nu * nu / 24;
      return (alpha / fBeta) * (1 + (t1 + t2 + t3) * T);
    }

    final fkBeta = math.pow(F * K, (1 - beta) / 2).toDouble();
    final denom =
        fkBeta *
        (1 +
            math.pow(1 - beta, 2) / 24 * logFK * logFK +
            math.pow(1 - beta, 4) / 1920 * math.pow(logFK, 4));

    final z = nu / alpha * fkBeta * logFK;
    final chiZ = math.log(
      (math.sqrt(1 - 2 * rho * z + z * z) + z - rho) / (1 - rho),
    );
    final zx = chiZ.abs() < 1e-10 ? 1.0 : z / chiZ;

    final t1 =
        math.pow(1 - beta, 2) / 24 * alpha * alpha / math.pow(F * K, 1 - beta);
    final t2 = rho * beta * nu * alpha / (4 * fkBeta);
    final t3 = (2 - 3 * rho * rho) * nu * nu / 24;

    return (alpha / denom) * zx * (1 + (t1 + t2 + t3) * T);
  }

  // ── Heston Correction ─────────────────────────────────────────────────────
  // First-order expansion of the Heston price around BS (Hull & White 1987
  // style). Accounts for mean-reverting stochastic volatility.
  //
  //  ΔV_Heston ≈ ρ_H × ξ × V_vanna × (1 − e^{−κT}) / κ
  //             + (ξ²/2) × V_vomma × (1 − e^{−2κT}) / (2κ)
  //
  static double _hestonCorrection(double T, double vanna, double vomma) {
    final k = _hestonKappa;
    final xi = _hestonXi;
    final rh = _hestonRho;

    final a = rh * xi * vanna * (1 - math.exp(-k * T)) / k;
    final b = (xi * xi / 2) * vomma * (1 - math.exp(-2 * k * T)) / (2 * k);
    return a + b;
  }

  // ── Expected Shortfall (ES₉₅) ────────────────────────────────────────────

  static double _es95({
    required double delta,
    required double gamma,
    required double spot,
    required double sigma,
    required double T,
  }) {
    final sqrtT = math.sqrt(T);
    // Linear (delta) component
    final deltaEs = delta.abs() * spot * sigma * sqrtT * _es95Mult;
    // Convexity (gamma) component — second-order tail risk
    final gammaEs = 0.5 * gamma.abs() * spot * spot * sigma * sigma * T * 1.5;
    return deltaEs + gammaEs;
  }

  // ── Standard normal helpers ───────────────────────────────────────────────

  static double _cdf(double x) => 0.5 * (1 + _erf(x / math.sqrt2));

  static double _phi(double x) =>
      math.exp(-0.5 * x * x) / math.sqrt(2 * math.pi);

  static double _erf(double x) {
    // Abramowitz & Stegun 7.1.26 — max error < 1.5e-7
    const a1 = 0.254829592;
    const a2 = -0.284496736;
    const a3 = 1.421413741;
    const a4 = -1.453152027;
    const a5 = 1.061405429;
    const p = 0.3275911;
    final s = x >= 0 ? 1.0 : -1.0;
    final t = 1.0 / (1.0 + p * x.abs());
    final y =
        1.0 -
        (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-x * x);
    return s * y;
  }
}
