// =============================================================================
// features/iv/widgets/rnd_chart.dart
// =============================================================================
// Risk-Neutral Density — the market-implied probability distribution of the
// underlying at expiration, extracted via Breeden-Litzenberger from the
// SABR-calibrated smile (services/rnd.py):  q(K) = e^(rT) · ∂²C/∂K².
//
// What this shows that IV alone cannot:
//   • P(S_T > K) for any strike — true market-implied odds, smile included
//   • Skewness  — negative = crash tail priced in; positive = squeeze tail
//   • Kurtosis  — excess vs lognormal; >0 = fat tails (gap risk priced)
//
// One tab per DTE slice (up to four, spread across the curve).
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';
import '../../../core/widgets/chart/chart_card.dart';

class RndChart extends StatefulWidget {
  final IvAnalysis analysis;
  const RndChart({super.key, required this.analysis});

  @override
  State<RndChart> createState() => _RndChartState();
}

class _RndChartState extends State<RndChart> {
  int _tab = 0;

  /// Up to four slices spread across the curve (nearest to 7/30/60/90 DTE).
  List<RndSlice> get _slices {
    final all = widget.analysis.rnd.where((s) => s.strikes.isNotEmpty).toList();
    if (all.length <= 4) return all;
    final picked = <RndSlice>{};
    for (final target in const [7, 30, 60, 90]) {
      picked.add(all.reduce(
          (a, b) => (a.dte - target).abs() < (b.dte - target).abs() ? a : b));
    }
    final result = picked.toList()..sort((a, b) => a.dte.compareTo(b.dte));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final slices = _slices;

    if (slices.isEmpty) {
      return const AnalyticsCard(
        title: 'RISK-NEUTRAL DENSITY',
        children: [
          SizedBox(height: 24),
          Center(
            child: Text(
              'No RND available — SABR calibration needs ≥4 valid quotes per expiry',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
          ),
          SizedBox(height: 24),
        ],
      );
    }

    final tab   = _tab.clamp(0, slices.length - 1);
    final slice = slices[tab];
    final spot  = widget.analysis.underlyingPrice;

    return AnalyticsCard(
      title: 'RISK-NEUTRAL DENSITY',
      actions: [_FitBadge(slice: slice)],
      children: [
        const SizedBox(height: 4),
        const Text(
          'Market-implied probability distribution at expiration (Breeden-Litzenberger)',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 12),

        if (slices.length > 1) ...[
          ChartSegmentedTabs(
            labels: slices.map((s) => '${s.dte}D').toList(),
            selected: tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 12),
        ],

        _MomentChips(slice: slice, spot: spot),
        const SizedBox(height: 14),

        SizedBox(height: 150, child: _DensityChart(slice: slice, spot: spot)),
        const SizedBox(height: 12),

        _RndInterpretation(slice: slice, spot: spot),
      ],
    );
  }
}

// ── Moment chips ──────────────────────────────────────────────────────────────

class _MomentChips extends StatelessWidget {
  final RndSlice slice;
  final double? spot;
  const _MomentChips({required this.slice, required this.spot});

  @override
  Widget build(BuildContext context) {
    final m = slice.moments;
    final probAbove = _probAboveSpot(slice, spot);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (probAbove != null)
          ChartStatChip(
            label: 'P(close above spot)',
            value: '${(probAbove * 100).toStringAsFixed(0)}%',
            dotColor: probAbove >= 0.5
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
        ChartStatChip(
          label: 'RND vol',
          value: '${(m.impliedVol * 100).toStringAsFixed(1)}%',
        ),
        ChartStatChip(
          label: 'Skewness',
          value: m.skewness.toStringAsFixed(2),
          dotColor:
              m.skewness < -0.3 ? AppTheme.lossColor : AppTheme.profitColor,
        ),
        ChartStatChip(
          label: 'Excess kurtosis',
          value: m.kurtosis.toStringAsFixed(2),
        ),
      ],
    );
  }
}

double? _probAboveSpot(RndSlice slice, double? spot) {
  if (spot == null || spot <= 0 || slice.strikes.isEmpty) return null;
  final nearest = slice.strikes.reduce(
      (a, b) => (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
  return nearest.probAbove;
}

// ── Density curve ─────────────────────────────────────────────────────────────

class _DensityChart extends StatelessWidget {
  final RndSlice slice;
  final double? spot;
  const _DensityChart({required this.slice, required this.spot});

  @override
  Widget build(BuildContext context) {
    final spots =
        slice.strikes.map((p) => FlSpot(p.strike, p.density)).toList();
    if (spots.length < 3) return const SizedBox.shrink();

    final maxY =
        spots.map((s) => s.y).reduce((a, b) => a > b ? a : b) * 1.1;
    final minX = spots.first.x;
    final maxX = spots.last.x;

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        minX: minX,
        maxX: maxX,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          // Density units are not meaningful to traders — hide the y-axis.
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: ((maxX - minX) / 4).clamp(1, double.infinity),
              getTitlesWidget: (v, meta) {
                if (v == meta.min || v == meta.max) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '\$${v.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 9,
                    ),
                  ),
                );
              },
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        extraLinesData: ExtraLinesData(
          verticalLines: [
            if (spot != null && spot! >= minX && spot! <= maxX)
              VerticalLine(
                x: spot!,
                color: Colors.white.withValues(alpha: 0.35),
                strokeWidth: 1,
                dashArray: [4, 4],
                label: VerticalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  labelResolver: (_) => 'spot',
                  style: const TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 9,
                  ),
                ),
              ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.15,
            preventCurveOverShooting: true,
            color: ChartPalette.indigo,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: ChartPalette.indigo.withValues(alpha: 0.12),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            getTooltipItems: (touched) => touched.map((s) {
              final nearest = slice.strikes.reduce((a, b) =>
                  (a.strike - s.x).abs() < (b.strike - s.x).abs() ? a : b);
              return LineTooltipItem(
                '\$${nearest.strike.toStringAsFixed(0)}\n'
                'P(above): ${(nearest.probAbove * 100).toStringAsFixed(0)}%',
                const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ── SABR fit badge ────────────────────────────────────────────────────────────

class _FitBadge extends StatelessWidget {
  final RndSlice slice;
  const _FitBadge({required this.slice});

  @override
  Widget build(BuildContext context) {
    final color =
        slice.reliable ? AppTheme.profitColor : const Color(0xFFFBBF24);
    final label = slice.reliable ? 'FIT OK' : 'LOW CONFIDENCE';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ── Interpretation ────────────────────────────────────────────────────────────

class _RndInterpretation extends StatelessWidget {
  final RndSlice slice;
  final double? spot;
  const _RndInterpretation({required this.slice, required this.spot});

  @override
  Widget build(BuildContext context) {
    final m = slice.moments;
    final parts = <String>[];

    if (m.skewness < -0.3) {
      parts.add(
          'Left-skewed distribution (${m.skewness.toStringAsFixed(2)}): the market '
          'pays up for crash protection — downside moves are priced as larger but '
          'less likely than upside grinds. OTM put buyers are paying this premium.');
    } else if (m.skewness > 0.3) {
      parts.add(
          'Right-skewed distribution (+${m.skewness.toStringAsFixed(2)}): a squeeze '
          'tail is priced in — the market assigns real odds to an outsized upside '
          'move. OTM calls carry that lottery premium.');
    } else {
      parts.add(
          'Near-symmetric distribution (${m.skewness.toStringAsFixed(2)}): neither '
          'tail carries unusual premium at this expiry.');
    }

    if (m.kurtosis > 0.5) {
      parts.add('Fat tails (excess kurtosis ${m.kurtosis.toStringAsFixed(2)}): '
          'gap risk is priced — the market expects either a small move or a large '
          'one, not a medium one. Defined-risk wings are relatively expensive.');
    }

    if (!slice.reliable) {
      parts.add('SABR fit RMSE ${(slice.sabrRmse * 100).toStringAsFixed(2)}% — '
          'treat these odds as approximate (sparse or noisy quotes).');
    }

    return Text(
      parts.join('\n\n'),
      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
    );
  }
}
