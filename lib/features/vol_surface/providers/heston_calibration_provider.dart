// =============================================================================
// vol_surface/providers/heston_calibration_provider.dart
// =============================================================================
// Reads the latest Heston calibration for a ticker from heston_calibrations.
// Heston is calibrated server-side (heston_pull.py) — Flutter only reads.
// =============================================================================

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class HestonCalibration {
  final String ticker;
  final String obsDate;
  final double kappa;   // mean-reversion speed (κ)
  final double theta;   // long-run variance     (θ)
  final double xi;      // vol-of-vol            (ξ)
  final double rho;     // spot-vol correlation  (ρ)
  final double v0;      // initial variance      (V₀)
  final double? rmseIv;
  final int?    nPoints;
  final bool?   converged;

  const HestonCalibration({
    required this.ticker,
    required this.obsDate,
    required this.kappa,
    required this.theta,
    required this.xi,
    required this.rho,
    required this.v0,
    this.rmseIv,
    this.nPoints,
    this.converged,
  });

  factory HestonCalibration.fromJson(Map<String, dynamic> j) =>
      HestonCalibration(
        ticker:    j['ticker']    as String,
        obsDate:   j['obs_date']  as String,
        kappa:     (j['kappa']  as num).toDouble(),
        theta:     (j['theta']  as num).toDouble(),
        xi:        (j['xi']     as num).toDouble(),
        rho:       (j['rho']    as num).toDouble(),
        v0:        (j['v0']     as num).toDouble(),
        rmseIv:    (j['rmse_iv']  as num?)?.toDouble(),
        nPoints:   j['n_points']  as int?,
        converged: j['converged'] as bool?,
      );

  // Expressed as implied vol levels (decimal), matching how traders think.
  double get longRunVol  => math.sqrt(theta);
  double get currentVol  => math.sqrt(v0);

  bool get isReliable => (nPoints ?? 0) >= 8 && (rmseIv ?? 1.0) < 0.05;
}

// ── Provider ──────────────────────────────────────────────────────────────────

/// Returns the most recent Heston calibration row for [ticker], or null if
/// the backend hasn't produced one yet.
final hestonCalibrationProvider =
    FutureProvider.family<HestonCalibration?, String>((ref, ticker) async {
  final db     = Supabase.instance.client;
  final userId = db.auth.currentUser?.id;
  if (userId == null) return null;

  final row = await db
      .from('heston_calibrations')
      .select()
      .eq('user_id', userId)
      .eq('ticker', ticker.toUpperCase())
      .order('obs_date', ascending: false)
      .limit(1)
      .maybeSingle();

  if (row == null) return null;
  return HestonCalibration.fromJson(row);
});
