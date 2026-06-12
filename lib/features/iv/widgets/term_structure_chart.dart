// =============================================================================
// features/iv/widgets/term_structure_chart.dart
// =============================================================================
// IV term structure — ATM IV per expiration (DTE on x-axis).
//
// The shape of the curve is one of the most information-dense vol signals:
//   • Contango (upward)      — normal markets; far-dated vol carries term premium
//   • Backwardation (inverted) — stress or imminent event; near-dated vol bid
//   • Kinks                  — single-expiry event premium (earnings, FOMC)
//
// Slope = IV(slice nearest 90 DTE) − IV(front slice ≥ 5 DTE), in vol points.
// Computed in the Python backend (iv_analytics._term_slope).
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';
import '../../../core/widgets/chart/chart_card.dart';

class TermStructureChart extends StatelessWidget {
  final IvAnalysis analysis;
  const TermStructureChart({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final points = analysis.termStructure;

    return AnalyticsCard(
      title: 'IV TERM STRUCTURE',
      actions: [_SlopeBadge(label: analysis.termStructureLabel)],
      children: [
        const SizedBox(height: 4),
        const Text(
          'ATM IV by expiration — curve shape reveals event premium and stress',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 14),

        if (points.length < 2) ...[
          const SizedBox(height: 32),
          const Center(
            child: Text(
              'Need at least 2 expirations for a term structure',
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          ),
          const SizedBox(height: 32),
        ] else ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChartStatChip(
                label: 'Front (${points.first.dte}d)',
                value: '${points.first.atmIv.toStringAsFixed(1)}%',
              ),
              ChartStatChip(
                label: 'Back (${points.last.dte}d)',
                value: '${points.last.atmIv.toStringAsFixed(1)}%',
              ),
              if (analysis.termSlopePp != null)
                ChartStatChip(
                  label: 'Slope',
                  value:
                      '${analysis.termSlopePp! >= 0 ? '+' : ''}${analysis.termSlopePp!.toStringAsFixed(1)}pp',
                  dotColor: analysis.termSlopePp! < -1
                      ? AppTheme.lossColor
                      : AppTheme.profitColor,
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(height: 150, child: _TermLineChart(points: points)),
        ],

        const SizedBox(height: 12),
        _TermInterpretation(analysis: analysis),
      ],
    );
  }
}

// ── Line chart ────────────────────────────────────────────────────────────────

class _TermLineChart extends StatelessWidget {
  final List<TermPoint> points;
  const _TermLineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final spots =
        points.map((p) => FlSpot(p.dte.toDouble(), p.atmIv)).toList();

    final ivs  = points.map((p) => p.atmIv).toList();
    final minY = (ivs.reduce((a, b) => a < b ? a : b) - 2)
        .clamp(0.0, double.infinity);
    final maxY = ivs.reduce((a, b) => a > b ? a : b) + 2;
    final maxX = points.last.dte.toDouble();

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: 0,
        maxX: maxX * 1.05,
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
                  color: AppTheme.neutralColor,
                  fontSize: 9,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: maxX <= 60 ? 15 : (maxX <= 180 ? 30 : 90),
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${v.toStringAsFixed(0)}d',
                  style: const TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.25,
            preventCurveOverShooting: true,
            color: ChartPalette.indigo,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                radius: 3,
                color: ChartPalette.indigo,
                strokeWidth: 0,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              color: ChartPalette.indigo.withValues(alpha: 0.07),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            getTooltipItems: (touched) => touched.map((s) {
              final p = points.reduce((a, b) =>
                  (a.dte - s.x).abs() < (b.dte - s.x).abs() ? a : b);
              final expiry = p.expiry.isNotEmpty ? '\n${p.expiry}' : '';
              return LineTooltipItem(
                '${p.dte} DTE: ${p.atmIv.toStringAsFixed(1)}%$expiry',
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

// ── Slope badge ───────────────────────────────────────────────────────────────

class _SlopeBadge extends StatelessWidget {
  final String label;
  const _SlopeBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (label) {
      'contango'      => (AppTheme.profitColor, 'CONTANGO'),
      'backwardation' => (AppTheme.lossColor, 'BACKWARDATION'),
      'flat'          => (const Color(0xFF60A5FA), 'FLAT'),
      _               => (AppTheme.neutralColor, '—'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
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

class _TermInterpretation extends StatelessWidget {
  final IvAnalysis analysis;
  const _TermInterpretation({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final slope = analysis.termSlopePp;
    String text;
    if (slope == null) {
      text = 'Not enough expirations to classify the term structure.';
    } else if (analysis.termStructureLabel == 'backwardation') {
      text =
          'Inverted curve (${slope.toStringAsFixed(1)}pp): near-dated vol is bid '
          'over far-dated — the market is pricing an imminent catalyst or is under '
          'stress. Front-month premium is rich: calendar spreads (sell front, buy '
          'back) collect that premium and profit as the curve normalises. Avoid '
          'owning naked front-month options through the event — IV crush risk is '
          'highest exactly there.';
    } else if (analysis.termStructureLabel == 'contango') {
      text =
          'Upward-sloping curve (+${slope.toStringAsFixed(1)}pp): normal term '
          'premium — far-dated options carry extra vol. Long calendars are paying '
          'that premium, so they need IV to rise to win. Front-dated premium '
          'selling collects less per day of theta but faces no event inversion. '
          'A kink at a single expiry marks earnings/event premium worth comparing '
          'against your expected move.';
    } else {
      text =
          'Flat curve (${slope.toStringAsFixed(1)}pp): no maturity carries a '
          'meaningful vol premium. Strategy selection should lean on IV Rank and '
          'skew rather than curve positioning.';
    }
    return Text(
      text,
      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
    );
  }
}
