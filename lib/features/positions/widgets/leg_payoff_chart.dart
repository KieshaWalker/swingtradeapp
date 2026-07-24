// =============================================================================
// features/positions/widgets/leg_payoff_chart.dart
// =============================================================================
// New — nothing like this exists elsewhere in the app. Two overlaid curves
// across a spot-price range (±30% of current spot) for one ticker's legs,
// summed for multi-leg (same-ticker) support:
//
//   AT EXPIRATION (kinked)  — pure intrinsic value minus what was paid.
//   TODAY (smooth)          — theoretical value right now, priced with a
//                             local Black-Scholes at each leg's latest known
//                             IV and current DTE. This is the "projection":
//                             what the position is worth today across spot
//                             scenarios, not just at expiry.
//
// Breakeven(s) are exact zero-crossings of the (piecewise-linear) at-
// expiration curve, found by scanning + linearly interpolating between the
// two bracketing sample points -- no iterative solver needed.
//
// The Black-Scholes pricer here is a small local implementation (standard
// closed-form + Abramowitz-Stegun erf approximation), not a call to
// PythonApiClient.bsPrice -- an 80-point curve across N legs would mean
// 80*N network round trips per render, which isn't viable for an
// interactive chart. Mirrors the same formula api/services/black_scholes.py
// already implements server-side.
// =============================================================================

import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/chart/chart_card.dart';
import '../../../core/widgets/chart/pannable_chart.dart';
import '../models/position_models.dart';

/// One leg's inputs for the payoff/projection curve. Kept separate from
/// EnrichedLeg because the "today" curve needs implied vol, which isn't
/// stored on EnrichedLeg (only the already-computed theo prices are) --
/// callers pass the leg's latest known LegSnapshot.impliedVol instead.
class PayoffLegInput {
  final LegType type;
  final int quantity;
  final double? strike;
  final double? entryPrice;
  final int? dte;
  final double? impliedVol; // decimal, e.g. 0.42

  const PayoffLegInput({
    required this.type,
    required this.quantity,
    this.strike,
    this.entryPrice,
    this.dte,
    this.impliedVol,
  });
}

// ── Local Black-Scholes (see file header for why this isn't an API call) ────

double _erf(double x) {
  // Abramowitz & Stegun 7.1.26, max error 1.5e-7.
  const p = 0.3275911;
  const a1 = 0.254829592, a2 = -0.284496736, a3 = 1.421413741;
  const a4 = -1.453152027, a5 = 1.061405429;
  final sign = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  final t = 1.0 / (1.0 + p * ax);
  final y = 1.0 -
      (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-ax * ax);
  return sign * y;
}

double _normCdf(double x) => 0.5 * (1.0 + _erf(x / math.sqrt2));

/// Standard closed-form Black-Scholes. Returns 0 for degenerate inputs
/// (expired/zero vol) rather than throwing -- the payoff curve should still
/// render (falling back to intrinsic value) even for a leg on expiry day.
double _bsPrice({
  required double spot,
  required double strike,
  required int dte,
  required double iv,
  required bool isCall,
  double r = 0.0433,
}) {
  if (dte <= 0 || iv <= 0 || spot <= 0 || strike <= 0) {
    final intrinsic = isCall ? (spot - strike) : (strike - spot);
    return intrinsic > 0 ? intrinsic : 0.0;
  }
  final t = dte / 365.0;
  final sqrtT = math.sqrt(t);
  final d1 = (math.log(spot / strike) + (r + iv * iv / 2) * t) / (iv * sqrtT);
  final d2 = d1 - iv * sqrtT;
  final discK = strike * math.exp(-r * t);
  return isCall
      ? spot * _normCdf(d1) - discK * _normCdf(d2)
      : discK * _normCdf(-d2) - spot * _normCdf(-d1);
}

// ── Curve computation ────────────────────────────────────────────────────────

class _PayoffCurves {
  final List<double> spots;
  final List<double> atExpiration;
  final List<double> today;
  final List<double> breakevens;
  const _PayoffCurves(this.spots, this.atExpiration, this.today, this.breakevens);
}

_PayoffCurves _computeCurves(double spot, List<PayoffLegInput> legs, {int points = 81}) {
  final lo = spot * 0.7;
  final hi = spot * 1.3;
  final step = (hi - lo) / (points - 1);
  final spots = List.generate(points, (i) => lo + step * i);

  final atExp = List.filled(points, 0.0);
  final today = List.filled(points, 0.0);

  for (final leg in legs) {
    final entry = leg.entryPrice ?? 0.0;
    for (var i = 0; i < points; i++) {
      final s = spots[i];
      double expiryValue;
      if (leg.type == LegType.underlying) {
        expiryValue = s;
      } else if (leg.strike == null) {
        continue;
      } else {
        final intrinsic =
            leg.type == LegType.call ? (s - leg.strike!) : (leg.strike! - s);
        expiryValue = intrinsic > 0 ? intrinsic : 0.0;
      }
      atExp[i] += leg.quantity * (expiryValue - (leg.type == LegType.underlying ? entry : entry));

      double todayValue;
      if (leg.type == LegType.underlying) {
        todayValue = s;
      } else if (leg.strike == null || leg.dte == null || leg.impliedVol == null) {
        // Missing IV/DTE — fall back to intrinsic so the curve still renders,
        // it just won't show extrinsic (time) value for this leg.
        final intrinsic =
            leg.type == LegType.call ? (s - leg.strike!) : (leg.strike! - s);
        todayValue = intrinsic > 0 ? intrinsic : 0.0;
      } else {
        todayValue = _bsPrice(
          spot: s,
          strike: leg.strike!,
          dte: leg.dte!,
          iv: leg.impliedVol!,
          isCall: leg.type == LegType.call,
        );
      }
      today[i] += leg.quantity * (todayValue - entry);
    }
  }

  // Zero-crossings of the piecewise-linear at-expiration curve.
  final breakevens = <double>[];
  for (var i = 1; i < points; i++) {
    final y0 = atExp[i - 1], y1 = atExp[i];
    if (y0 == 0) {
      breakevens.add(spots[i - 1]);
    } else if ((y0 < 0) != (y1 < 0)) {
      final frac = -y0 / (y1 - y0);
      breakevens.add(spots[i - 1] + frac * step);
    }
  }

  return _PayoffCurves(spots, atExp, today, breakevens);
}

// ── Widget ──────────────────────────────────────────────────────────────────

class LegPayoffChart extends StatelessWidget {
  final String ticker;
  final double spot;
  final List<PayoffLegInput> legs;

  const LegPayoffChart({
    super.key,
    required this.ticker,
    required this.spot,
    required this.legs,
  });

  @override
  Widget build(BuildContext context) {
    if (spot <= 0 || legs.isEmpty) {
      return const ChartCard(
        title: 'PAYOFF / PROJECTION',
        height: 220,
        child: ChartEmptyState(
          icon: Icons.timeline_rounded,
          title: 'No payoff data',
          message: 'Needs a live spot price and at least one option or underlying leg.',
        ),
      );
    }

    final curves = _computeCurves(spot, legs);
    final beText = curves.breakevens.isEmpty
        ? '—'
        : curves.breakevens.map((b) => '\$${b.toStringAsFixed(2)}').join(', ');

    return ChartCard(
      title: 'PAYOFF / PROJECTION — $ticker',
      height: 220,
      stats: Wrap(spacing: 8, runSpacing: 8, children: [
        ChartStatChip(label: 'Spot', value: '\$${spot.toStringAsFixed(2)}'),
        ChartStatChip(
            label: 'Breakeven', value: beText, dotColor: AppTheme.neutralColor),
      ]),
      legend: const [
        ChartLegendItem(ChartPalette.indigo, 'Today'),
        ChartLegendItem(ChartPalette.white, 'At expiration', dashed: true),
      ],
      child: _PayoffPlot(curves: curves, spot: spot),
    );
  }
}

class _PayoffPlot extends StatelessWidget {
  final _PayoffCurves curves;
  final double spot;
  const _PayoffPlot({required this.curves, required this.spot});

  @override
  Widget build(BuildContext context) {
    final n = curves.spots.length;
    final atExpSpots =
        List.generate(n, (i) => FlSpot(i.toDouble(), curves.atExpiration[i]));
    final todaySpots =
        List.generate(n, (i) => FlSpot(i.toDouble(), curves.today[i]));

    final allY = [...curves.atExpiration, ...curves.today];
    var minY = allY.reduce((a, b) => a < b ? a : b);
    var maxY = allY.reduce((a, b) => a > b ? a : b);
    minY = minY < 0 ? minY * 1.15 : minY * 0.85;
    maxY = maxY > 0 ? maxY * 1.15 : maxY * 0.85;
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    // Index of the sample closest to current spot, for the reference line.
    var spotIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final d = (curves.spots[i] - spot).abs();
      if (d < bestDist) {
        bestDist = d;
        spotIdx = i;
      }
    }

    return PannableChart(
      count: n,
      defaultWindow: n.toDouble(),
      minWindow: 10,
      builder: (ctx, minX, maxX) => LineChart(LineChartData(
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: v == 0
                ? AppTheme.neutralColor.withValues(alpha: 0.5)
                : AppTheme.borderColor.withValues(alpha: 0.3),
            strokeWidth: v == 0 ? 1.5 : 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(verticalLines: [
          VerticalLine(
            x: spotIdx.toDouble(),
            color: AppTheme.neutralColor.withValues(alpha: 0.6),
            strokeWidth: 1,
            dashArray: [4, 4],
            label: VerticalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9),
              labelResolver: (_) => 'spot',
            ),
          ),
        ]),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0),
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: ((maxX - minX) / 4).ceilToDouble().clamp(1.0, double.infinity),
              getTitlesWidget: (v, _) {
                final i = v.round();
                if (i < 0 || i >= n) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('\$${curves.spots[i].toStringAsFixed(0)}',
                      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: atExpSpots,
            isCurved: false,
            color: ChartPalette.white.withValues(alpha: 0.6),
            barWidth: 1.5,
            dashArray: [5, 4],
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
          LineChartBarData(
            spots: todaySpots,
            isCurved: true,
            color: ChartPalette.indigo,
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData:
                BarAreaData(show: true, color: ChartPalette.indigo.withValues(alpha: 0.08)),
          ),
        ],
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) => spots.map((ts) {
              final i = ts.x.toInt().clamp(0, n - 1);
              final label = ts.barIndex == 0 ? 'Expiry' : 'Today';
              return LineTooltipItem(
                '\$${curves.spots[i].toStringAsFixed(2)}\n'
                '$label  ${ts.y >= 0 ? '+' : ''}${ts.y.toStringAsFixed(2)}',
                const TextStyle(color: Colors.white, fontSize: 10, height: 1.5),
              );
            }).toList(),
          ),
        ),
      )),
    );
  }
}
