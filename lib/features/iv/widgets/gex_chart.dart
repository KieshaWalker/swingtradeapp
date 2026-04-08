// =============================================================================
// features/iv/widgets/gex_chart.dart
// =============================================================================
// Gamma Exposure (GEX) bar chart per strike.
//
// Green bars = positive dealer GEX (market-makers long gamma → price stabilising)
// Red bars   = negative dealer GEX (market-makers short gamma → price amplifying)
//
// The strike with the highest absolute GEX is the "gamma wall" — a key
// support (positive) or resistance (negative) level to watch.
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class GexChart extends StatelessWidget {
  final IvAnalysis analysis;
  const GexChart({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final strikes = analysis.gexStrikes;

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
          // Header row
          Row(
            children: [
              const Text(
                'GAMMA EXPOSURE (GEX)',
                style: TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              if (analysis.totalGex != null)
                _GexBadge(gex: analysis.totalGex!),
            ],
          ),
          const SizedBox(height: 4),

          // Key stats row
          Row(
            children: [
              _chip('Net GEX', analysis.gexLabel),
              const SizedBox(width: 8),
              _chip('Gamma Wall', analysis.maxGexStrike != null
                  ? '\$${analysis.maxGexStrike!.toStringAsFixed(0)}'
                  : '—'),
              const SizedBox(width: 8),
              _chip('P/C OI Ratio', analysis.putCallRatio != null
                  ? analysis.putCallRatio!.toStringAsFixed(2)
                  : '—'),
            ],
          ),

          const SizedBox(height: 16),

          if (strikes.isEmpty) ...[
            const SizedBox(height: 40),
            const Center(
              child: Text('No GEX data — open an options chain first',
                  style: TextStyle(color: AppTheme.neutralColor)),
            ),
            const SizedBox(height: 40),
          ] else ...[
            SizedBox(
              height: 180,
              child: _GexBarChart(
                strikes:         strikes,
                underlyingPrice: analysis.currentIv, // used for formatting only
                maxGexStrike:    analysis.maxGexStrike,
              ),
            ),
          ],

          const SizedBox(height: 12),
          _GexInterpretation(analysis: analysis),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12,
                  fontWeight: FontWeight.w700)),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10)),
        ],
      ),
    ),
  );
}

// ── GEX bar chart ─────────────────────────────────────────────────────────────

class _GexBarChart extends StatelessWidget {
  final List<GexStrike> strikes;
  final double underlyingPrice;
  final double? maxGexStrike;

  const _GexBarChart({
    required this.strikes,
    required this.underlyingPrice,
    required this.maxGexStrike,
  });

  @override
  Widget build(BuildContext context) {
    // Use a fixed underlying price of 1.0 for the chart since we're displaying
    // relative GEX values. The actual $ million values need the real spot.
    // We'll compute dealer GEX with a proxy — take ratio from OI × gamma.
    // For display, just use the raw callOi*callGamma - putOi*putGamma proportion.
    final gexValues = strikes.map((s) {
      final raw = s.callOi * s.callGamma - s.putOi * s.putGamma;
      return raw;
    }).toList();

    if (gexValues.isEmpty) return const SizedBox.shrink();

    final absMax = gexValues.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
    if (absMax == 0) return const SizedBox.shrink();

    // Only display top N strikes by absolute GEX to keep chart readable
    final indexed = List.generate(strikes.length, (i) => (i, gexValues[i]))
      ..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
    final topN   = indexed.take(20).map((e) => e.$1).toSet();
    final display = strikes.asMap().entries
        .where((e) => topN.contains(e.key))
        .toList()
        ..sort((a, b) => a.value.strike.compareTo(b.value.strike));

    final maxY = absMax * 1.15;

    return BarChart(
      BarChartData(
        alignment:    BarChartAlignment.spaceAround,
        maxY:         maxY,
        minY:         -maxY,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            getTooltipItem: (group, _, rod, _) {
              final strike = display[group.x].value.strike;
              final gex = rod.toY;
              final fmt = gex.abs() >= 1 ? '${gex.toStringAsFixed(1)}M'
                  : '${(gex * 1000).toStringAsFixed(0)}K';
              return BarTooltipItem(
                '\$${strike.toStringAsFixed(0)}\n${gex >= 0 ? '+' : ''}$fmt GEX',
                const TextStyle(color: Colors.white, fontSize: 11),
              );
            },
          ),
        ),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          checkToShowHorizontalLine: (v) => v == 0,
          getDrawingHorizontalLine: (_) => FlLine(
            color:       Colors.white.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles:   true,
              reservedSize: 28,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= display.length) return const SizedBox.shrink();
                final strike = display[i].value.strike;
                final isWall = maxGexStrike != null &&
                    (strike - maxGexStrike!).abs() < 0.5;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '\$${strike.toStringAsFixed(0)}',
                    style: TextStyle(
                      color:      isWall ? Colors.white : AppTheme.neutralColor,
                      fontSize:   8,
                      fontWeight: isWall ? FontWeight.w800 : FontWeight.normal,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: List.generate(display.length, (i) {
          final strike = display[i].value;
          final gv     = gexValues[display[i].key];
          final isWall = maxGexStrike != null &&
              (strike.strike - maxGexStrike!).abs() < 0.5;
          final color  = gv >= 0
              ? (isWall
                  ? AppTheme.profitColor
                  : AppTheme.profitColor.withValues(alpha: 0.65))
              : (isWall
                  ? AppTheme.lossColor
                  : AppTheme.lossColor.withValues(alpha: 0.65));

          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY:          gv,
                fromY:        0,
                color:        color,
                width:        isWall ? 10 : 7,
                borderRadius: gv >= 0
                    ? const BorderRadius.vertical(top: Radius.circular(3))
                    : const BorderRadius.vertical(bottom: Radius.circular(3)),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ── GEX badge ─────────────────────────────────────────────────────────────────

class _GexBadge extends StatelessWidget {
  final double gex;
  const _GexBadge({required this.gex});

  @override
  Widget build(BuildContext context) {
    final positive = gex >= 0;
    final color    = positive ? AppTheme.profitColor : AppTheme.lossColor;
    final label    = positive ? 'LONG GAMMA' : 'SHORT GAMMA';
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

// ── GEX interpretation ────────────────────────────────────────────────────────

class _GexInterpretation extends StatelessWidget {
  final IvAnalysis analysis;
  const _GexInterpretation({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final gex  = analysis.totalGex;
    final wall = analysis.maxGexStrike;
    final pcr  = analysis.putCallRatio;

    String text;
    if (gex == null) {
      text = 'Load an options chain to compute GEX positioning.';
    } else if (gex > 0) {
      text = 'Positive net GEX (${analysis.gexLabel}) — dealers are long gamma. '
          'Expect mean-reversion behavior: price dips get bought, rallies get faded.';
    } else {
      text = 'Negative net GEX (${analysis.gexLabel}) — dealers are short gamma. '
          'Expect trend-following or amplified moves — volatility is likely to expand.';
    }

    if (wall != null) {
      text += '\n\nGamma wall at \$${wall.toStringAsFixed(0)} — '
          'strongest support/resistance level based on open interest positioning.';
    }

    if (pcr != null) {
      final sentiment = pcr > 1.2 ? 'bearish (heavy put loading)'
          : pcr < 0.8 ? 'bullish (calls dominating OI)'
          : 'neutral';
      text += '\n\nPut/Call OI ratio: ${pcr.toStringAsFixed(2)} — $sentiment.';
    }

    return Text(text,
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12));
  }
}
