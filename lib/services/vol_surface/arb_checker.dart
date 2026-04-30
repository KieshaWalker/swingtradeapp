// =============================================================================
// services/vol_surface/arb_checker.dart
// =============================================================================
// Models for arbitrage check results + a Riverpod provider that delegates
// the actual check to the Python API (/arb/check).
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/vol_surface/models/vol_surface_models.dart';
import '../../services/python_api/python_api_client.dart';

// ── Result models ─────────────────────────────────────────────────────────────

class CalendarViolation {
  final double strike;
  final int    nearDte;
  final int    farDte;
  final double nearTotalVar;
  final double farTotalVar;
  final double violation;

  const CalendarViolation({
    required this.strike,
    required this.nearDte,
    required this.farDte,
    required this.nearTotalVar,
    required this.farTotalVar,
    required this.violation,
  });

  factory CalendarViolation.fromJson(Map<String, dynamic> j) =>
      CalendarViolation(
        strike:       (j['strike']        as num).toDouble(),
        nearDte:      (j['near_dte']      as num).toInt(),
        farDte:       (j['far_dte']       as num).toInt(),
        nearTotalVar: (j['near_total_var'] as num).toDouble(),
        farTotalVar:  (j['far_total_var']  as num).toDouble(),
        violation:    (j['violation']     as num).toDouble(),
      );

  @override
  String toString() =>
      'Calendar arb: K=\$${strike.toStringAsFixed(1)} '
      '${nearDte}d vs ${farDte}d — violation: ${violation.toStringAsFixed(4)}';
}

class ButterflyViolation {
  final int    dte;
  final double strike;
  final double convexityValue;

  const ButterflyViolation({
    required this.dte,
    required this.strike,
    required this.convexityValue,
  });

  factory ButterflyViolation.fromJson(Map<String, dynamic> j) =>
      ButterflyViolation(
        dte:            (j['dte']            as num).toInt(),
        strike:         (j['strike']         as num).toDouble(),
        convexityValue: (j['convexity_value'] as num).toDouble(),
      );

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

  static const empty = ArbCheckResult(
    calendarViolations:  [],
    butterflyViolations: [],
  );

  bool get isArbitrageFree =>
      calendarViolations.isEmpty && butterflyViolations.isEmpty;

  int get totalViolations =>
      calendarViolations.length + butterflyViolations.length;

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

  double get worstCalendarViolation => calendarViolations.isEmpty
      ? 0
      : calendarViolations.map((v) => v.violation).reduce(
            (a, b) => a > b ? a : b);

  double get worstButterflyViolation => butterflyViolations.isEmpty
      ? 0
      : butterflyViolations.map((v) => v.convexityValue.abs()).reduce(
            (a, b) => a > b ? a : b);

  factory ArbCheckResult.fromJson(Map<String, dynamic> j) => ArbCheckResult(
    calendarViolations: (j['calendar_violations'] as List? ?? [])
        .map((e) => CalendarViolation.fromJson(e as Map<String, dynamic>))
        .toList(),
    butterflyViolations: (j['butterfly_violations'] as List? ?? [])
        .map((e) => ButterflyViolation.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

// ── Provider ──────────────────────────────────────────────────────────────────
// keyed by (ticker, obsDateStr) — re-runs only when the snap changes.

final arbCheckProvider =
    FutureProvider.family<ArbCheckResult, (String, String)>((ref, key) async {
  // key = (ticker, obsDateStr) — both fields used only as cache discriminators.
  // Actual data is fetched via checkArbForSnap() from the widget.
  return ArbCheckResult.empty;
});

/// Call this with a loaded VolSnapshot to get the arb result from Python.
Future<ArbCheckResult> checkArbForSnap(VolSnapshot snap) async {
  if (snap.points.isEmpty) return ArbCheckResult.empty;
  final points = snap.points.map((p) => p.toJson()).toList();
  final raw = await PythonApiClient.arbCheck(
    points:    points,
    spotPrice: snap.spotPrice ?? 0,
  );
  return ArbCheckResult.fromJson(raw);
}
