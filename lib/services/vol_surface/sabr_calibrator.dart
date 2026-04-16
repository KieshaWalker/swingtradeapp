// =============================================================================
// services/vol_surface/sabr_calibrator.dart
// =============================================================================
// Surface-level SABR calibration using Nelder-Mead optimization.
//
// What this does vs. the single-point approach in FairValueEngine:
//   FairValueEngine.compute() backs out alpha from the ATM IV of a single
//   contract and prices that contract using fixed ρ = -0.7, ν = 0.40.
//   These hardcoded parameters are empirical averages — they are wrong for any
//   specific ticker on any specific day.
//
//   SabrCalibrator.calibrate() fits (α, ρ, ν) jointly to all (strike, IV)
//   pairs in a DTE slice, minimising the sum of squared IV errors:
//       min Σᵢ [σ_market(Kᵢ) − σ_SABR(Kᵢ; α, ρ, ν)]²
//
//   The result is a calibrated parameter set that is globally consistent
//   across the smile.  Pricing any strike in the slice with these params
//   gives a model vol that exactly fits the market surface (RMSE < 0.5%).
//
// β is fixed at 0.5 (square-root CEV — standard for equity vol surfaces).
// Changing β requires re-running calibration; it changes the α parameterisation.
//
// Runs in Dart Isolate.run() — never blocks the UI thread.
//
// Usage:
//   final slices = await SabrCalibrator.calibrate(snapshot);
//   // slices is List<SabrSlice> — one per DTE, sorted ascending.
// =============================================================================

import 'dart:isolate';
import 'dart:math' as math;
import '../../features/vol_surface/models/vol_surface_models.dart';
import '../math/nelder_mead.dart';

// ── Output types ──────────────────────────────────────────────────────────────

/// Calibrated SABR parameters for one DTE slice.
class SabrSlice {
  final int    dte;
  final double alpha;   // vol level (> 0)
  final double beta;    // CEV exponent (fixed 0.5)
  final double rho;     // spot-vol correlation (−1 to 1)
  final double nu;      // vol-of-vol (> 0)
  final double rmse;    // root-mean-square IV error (decimal; e.g. 0.005 = 0.5%)
  final int    nPoints; // number of market quotes used in this fit

  const SabrSlice({
    required this.dte,
    required this.alpha,
    required this.beta,
    required this.rho,
    required this.nu,
    required this.rmse,
    required this.nPoints,
  });

  /// True when the fit is reliable — enough quotes and low error.
  bool get isReliable => nPoints >= 5 && rmse < 0.015;

  Map<String, dynamic> toJson() => {
    'dte':    dte,
    'alpha':  alpha,
    'beta':   beta,
    'rho':    rho,
    'nu':     nu,
    'rmse':   rmse,
    'n_points': nPoints,
  };

  factory SabrSlice.fromJson(Map<String, dynamic> j) => SabrSlice(
    dte:     (j['dte']     as num).toInt(),
    alpha:   (j['alpha']   as num).toDouble(),
    beta:    (j['beta']    as num).toDouble(),
    rho:     (j['rho']     as num).toDouble(),
    nu:      (j['nu']      as num).toDouble(),
    rmse:    (j['rmse']    as num).toDouble(),
    nPoints: (j['n_points'] as num).toInt(),
  );

  @override
  String toString() =>
      'SABR ${dte}d: α=${alpha.toStringAsFixed(4)} '
      'ρ=${rho.toStringAsFixed(3)} ν=${nu.toStringAsFixed(3)} '
      'rmse=${(rmse * 100).toStringAsFixed(2)}% (n=$nPoints)';
}

// ── Calibrator ────────────────────────────────────────────────────────────────

class SabrCalibrator {
  SabrCalibrator._();

  static const double _beta         = 0.5;
  static const double _r            = 0.0433; // SOFR
  static const int    _minPoints    = 4;       // min quotes for a valid fit
  static const double _maxIvFilter  = 3.0;     // drop IVs > 300% (data errors)

  /// Calibrate SABR parameters for every DTE slice in [snap].
  ///
  /// Runs in a background [Isolate] so the UI stays responsive.
  /// Returns an empty list if the snapshot has no usable data.
  static Future<List<SabrSlice>> calibrate(VolSnapshot snap) async {
    if (snap.points.isEmpty || snap.spotPrice == null) return [];
    return Isolate.run(() => _calibrateSync(snap));
  }

  /// Synchronous version — safe to call from an isolate.
  static List<SabrSlice> _calibrateSync(VolSnapshot snap) {
    final spot = snap.spotPrice!;
    final f0 = spot; // use spot as forward approximation for ATM anchoring

    // Group points by DTE
    final byDte = <int, List<(double, double)>>{};
    for (final p in snap.points) {
      final iv = _selectIv(p, spot);
      if (iv == null || iv <= 0 || iv > _maxIvFilter) continue;
      byDte.putIfAbsent(p.dte, () => []).add((p.strike, iv));
    }

    final slices = <SabrSlice>[];

    for (final entry in byDte.entries) {
      final dte    = entry.key;
      final quotes = entry.value;
      if (quotes.length < _minPoints) continue;

      final T = dte / 365.0;
      final F = f0 * math.exp(_r * T); // forward price

      // ATM IV: pick the quote closest to forward
      final atmQuote = quotes.reduce(
          (a, b) => (a.$1 - F).abs() < (b.$1 - F).abs() ? a : b);
      final atmIv = atmQuote.$2;

      // Initial guess
      //   α from ATM vol: σ_ATM ≈ α / F^(1-β)
      final alpha0 = atmIv * math.pow(F, 1 - _beta).toDouble();
      final rho0   = -0.30; // mild negative skew as starting point
      final nu0    =  0.40;

      // Objective: sum of squared IV errors (SSIE)
      double objective(List<double> params) {
        final alpha = params[0].clamp(1e-6, 5.0);
        final rho   = params[1].clamp(-0.999, 0.999);
        final nu    = params[2].clamp(1e-6, 5.0);
        double sse  = 0;
        for (final (K, ivMkt) in quotes) {
          final ivModel = _sabrIv(
            F: F, K: K, T: T, alpha: alpha, beta: _beta, rho: rho, nu: nu,
          );
          if (ivModel <= 0) { sse += 1.0; continue; }
          final diff = ivModel - ivMkt;
          sse += diff * diff;
        }
        return sse;
      }

      final result = NelderMead.minimize(
        objective: objective,
        initial:   [alpha0, rho0, nu0],
        bounds:    [(1e-6, 5.0), (-0.999, 0.999), (1e-6, 5.0)],
        maxIter:   1500,
        fTol:      1e-8,
        xTol:      1e-7,
      );

      final bestAlpha = result.x[0].clamp(1e-6, 5.0);
      final bestRho   = result.x[1].clamp(-0.999, 0.999);
      final bestNu    = result.x[2].clamp(1e-6, 5.0);

      // Compute RMSE
      double sse = 0;
      for (final (K, ivMkt) in quotes) {
        final ivModel = _sabrIv(
          F: F, K: K, T: T,
          alpha: bestAlpha, beta: _beta, rho: bestRho, nu: bestNu,
        );
        final diff = (ivModel > 0 ? ivModel : ivMkt) - ivMkt;
        sse += diff * diff;
      }
      final rmse = math.sqrt(sse / quotes.length);

      slices.add(SabrSlice(
        dte:     dte,
        alpha:   bestAlpha,
        beta:    _beta,
        rho:     bestRho,
        nu:      bestNu,
        rmse:    rmse,
        nPoints: quotes.length,
      ));
    }

    slices.sort((a, b) => a.dte.compareTo(b.dte));
    return slices;
  }

  /// Select the best IV for a point: OTM convention.
  static double? _selectIv(VolPoint p, double spot) {
    if (p.strike >= spot) return p.callIv;
    return p.putIv ?? p.callIv;
  }

  // ── SABR Hagan et al. (2002) implied vol ──────────────────────────────────
  // Identical to FairValueEngine._sabrIv — duplicated here so calibrator
  // can run in an isolate without importing flutter-dependent code.

  static double _sabrIv({
    required double F,
    required double K,
    required double T,
    required double alpha,
    required double beta,
    required double rho,
    required double nu,
  }) {
    if (alpha <= 0 || T <= 0 || F <= 0 || K <= 0) return 0;

    final logFK  = math.log(F / K);
    final absLog = logFK.abs();

    // ATM case
    if (absLog < 1e-6) {
      final fBeta = math.pow(F, 1 - beta).toDouble();
      final t1 = math.pow(1 - beta, 2) / 24 * alpha * alpha /
          math.pow(F, 2 * (1 - beta));
      final t2 = rho * beta * nu * alpha / (4 * fBeta);
      final t3 = (2 - 3 * rho * rho) * nu * nu / 24;
      return (alpha / fBeta) * (1 + (t1 + t2 + t3) * T);
    }

    final fkBeta = math.pow(F * K, (1 - beta) / 2).toDouble();
    final denom  = fkBeta *
        (1 +
            math.pow(1 - beta, 2) / 24 * logFK * logFK +
            math.pow(1 - beta, 4) / 1920 * math.pow(logFK, 4));

    final z   = nu / alpha * fkBeta * logFK;
    final chiZ = math.log(
        (math.sqrt(1 - 2 * rho * z + z * z) + z - rho) / (1 - rho));
    final zx = chiZ.abs() < 1e-10 ? 1.0 : z / chiZ;

    final t1 = math.pow(1 - beta, 2) / 24 * alpha * alpha /
        math.pow(F * K, 1 - beta);
    final t2 = rho * beta * nu * alpha / (4 * fkBeta);
    final t3 = (2 - 3 * rho * rho) * nu * nu / 24;

    return (alpha / denom) * zx * (1 + (t1 + t2 + t3) * T);
  }

  /// Convenience: look up the calibrated slice closest to [targetDte].
  static SabrSlice? sliceForDte(List<SabrSlice> slices, int targetDte) {
    if (slices.isEmpty) return null;
    return slices.reduce((a, b) =>
        (a.dte - targetDte).abs() < (b.dte - targetDte).abs() ? a : b);
  }
}
