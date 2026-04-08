// =============================================================================
// features/iv/widgets/skew_chart.dart
// =============================================================================
// Volatility skew chart — plots implied volatility by strike (smile/skew curve).
// Shows put IV in red, call IV in green, with the spot price marked.
// Also shows a summary skew interpretation below the chart.
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class SkewChart extends StatelessWidget {
  final IvAnalysis analysis;
  const SkewChart({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final points = analysis.skewCurve;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text(
                'VOLATILITY SKEW',
                style: TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              if (analysis.skew != null)
                _SkewBadge(skew: analysis.skew!),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            analysis.skewLabel,
            style: const TextStyle(color: Colors.white, fontSize: 13,
                fontWeight: FontWeight.w600),
          ),

          const SizedBox(height: 16),

          if (points.length < 3) ...[
            const SizedBox(height: 40),
            const Center(
              child: Text('Insufficient strikes for skew chart',
                  style: TextStyle(color: AppTheme.neutralColor)),
            ),
            const SizedBox(height: 40),
          ] else ...[
            SizedBox(
              height: 160,
              child: _SkewLineChart(points: points),
            ),
            const SizedBox(height: 8),
            // Legend
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legend(AppTheme.lossColor,   'Put IV'),
                const SizedBox(width: 20),
                _legend(AppTheme.profitColor, 'Call IV'),
              ],
            ),
          ],

          const SizedBox(height: 12),

          // Skew interpretation
          _SkewInterpretation(analysis: analysis),
        ],
      ),
    );
  }

  Widget _legend(Color color, String label) => Row(
    children: [
      Container(width: 14, height: 3,
          decoration: BoxDecoration(color: color,
              borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(
          color: AppTheme.neutralColor, fontSize: 11)),
    ],
  );
}

// ── Line chart ────────────────────────────────────────────────────────────────

class _SkewLineChart extends StatelessWidget {
  final List<SkewPoint> points;
  const _SkewLineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    // Build separate spot lists for puts and calls, keyed by moneyness
    final putSpots  = <FlSpot>[];
    final callSpots = <FlSpot>[];

    for (final p in points) {
      if (p.putIv  != null) putSpots.add(FlSpot(p.moneyness, p.putIv!));
      if (p.callIv != null) callSpots.add(FlSpot(p.moneyness, p.callIv!));
    }

    final allIvs = [
      ...putSpots.map((s)  => s.y),
      ...callSpots.map((s) => s.y),
    ];
    if (allIvs.isEmpty) return const SizedBox.shrink();

    final minY = (allIvs.reduce((a, b) => a < b ? a : b) - 5).clamp(0.0, double.infinity);
    final maxY =  allIvs.reduce((a, b) => a > b ? a : b) + 5;

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: AppTheme.borderColor.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                '${v.toStringAsFixed(0)}%',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, _) {
                final label = v == 0 ? 'ATM'
                    : v > 0 ? '+${v.toStringAsFixed(0)}%'
                    : '${v.toStringAsFixed(0)}%';
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(label,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 9)),
                );
              },
              interval: 5,
            ),
          ),
          rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        // Vertical line at ATM (moneyness = 0)
        extraLinesData: ExtraLinesData(
          verticalLines: [
            VerticalLine(
              x:          0,
              color:      Colors.white.withValues(alpha: 0.25),
              strokeWidth: 1,
              dashArray:  [4, 4],
              label: VerticalLineLabel(
                show:      true,
                alignment: Alignment.topRight,
                labelResolver: (_) => 'spot',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9),
              ),
            ),
          ],
        ),
        lineBarsData: [
          if (putSpots.isNotEmpty)
            LineChartBarData(
              spots:         putSpots,
              isCurved:      true,
              color:         AppTheme.lossColor,
              barWidth:      2,
              dotData:       const FlDotData(show: false),
              belowBarData:  BarAreaData(
                show: true,
                color: AppTheme.lossColor.withValues(alpha: 0.07),
              ),
            ),
          if (callSpots.isNotEmpty)
            LineChartBarData(
              spots:         callSpots,
              isCurved:      true,
              color:         AppTheme.profitColor,
              barWidth:      2,
              dotData:       const FlDotData(show: false),
              belowBarData:  BarAreaData(
                show: true,
                color: AppTheme.profitColor.withValues(alpha: 0.07),
              ),
            ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            getTooltipItems: (spots) => spots.map((s) {
              final isCall = s.bar.color == AppTheme.profitColor;
              return LineTooltipItem(
                '${isCall ? 'Call' : 'Put'} IV: ${s.y.toStringAsFixed(1)}%',
                TextStyle(
                  color:      s.bar.color,
                  fontSize:   11,
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

// ── Skew badge ────────────────────────────────────────────────────────────────

class _SkewBadge extends StatelessWidget {
  final double skew;
  const _SkewBadge({required this.skew});

  @override
  Widget build(BuildContext context) {
    final steep   = skew > 10;
    final elevated = skew > 5;
    final color = steep    ? AppTheme.lossColor
        : elevated ? const Color(0xFFFBBF24)
        : AppTheme.profitColor;
    final label = steep ? 'STEEP' : elevated ? 'ELEVATED' : 'NORMAL';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

// ── Interpretation block ──────────────────────────────────────────────────────

class _SkewInterpretation extends StatelessWidget {
  final IvAnalysis analysis;
  const _SkewInterpretation({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final skew = analysis.skew;
    final z    = analysis.skewZScore;

    String text;
    if (skew == null) {
      text = 'Skew data unavailable — load options chain with more strikes.';
    } else if (skew > 10) {
      text = 'Steep put skew (${skew.toStringAsFixed(1)}pp) — market pricing significant downside risk. '
          'Put spreads are expensive; consider call spreads or cash-secured puts for premium collection.';
    } else if (skew > 5) {
      text = 'Elevated put skew (${skew.toStringAsFixed(1)}pp) — typical in bearish or uncertain regimes. '
          'Directional put trades carry extra IV premium.';
    } else if (skew >= 0) {
      text = 'Normal put skew (${skew.toStringAsFixed(1)}pp) — healthy market conditions. '
          'Options priced near fair value across the curve.';
    } else {
      text = 'Flat or inverted skew (${skew.toStringAsFixed(1)}pp) — calls may be bid up. '
          'Watch for short-squeeze or FOMO-driven upside moves.';
    }

    if (z != null && z.abs() >= 1.5) {
      final dir = z > 0 ? 'steeper' : 'flatter';
      text += '\n\nSkew is historically $dir than average '
          '(Z=${z.toStringAsFixed(1)}) — potential precursor to a major move.';
    }

    return Text(text,
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12));
  }
}
