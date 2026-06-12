// =============================================================================
// features/iv/widgets/vanna_charm_chart.dart
// =============================================================================
// Displays dealer Vanna Exposure (VEX), Charm Exposure (CEX), and Volga
// across strikes, with regime interpretation.
//
// VEX bar chart — shows which strikes create the most dealer delta-hedging
//   pressure when IV moves. Critical for identifying vol-crush rally zones.
//
// Regime summary cards — GammaRegime + VannaRegime in plain English.
//
// Charm + Volga are shown as summary stats (no per-strike chart needed —
//   they're less spatially variable than VEX/GEX).
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';
import '../../../core/widgets/chart/chart_card.dart';

class VannaCharmChart extends StatelessWidget {
  final IvAnalysis analysis;
  const VannaCharmChart({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Regime cards ─────────────────────────────────────────────────
        _RegimeCards(analysis: analysis),
        const SizedBox(height: 12),

        // ── VEX chart ────────────────────────────────────────────────────
        _VexChart(analysis: analysis),
        const SizedBox(height: 12),

        // ── Charm + Volga summary ────────────────────────────────────────
        _CharmVolgaSummary(analysis: analysis),
      ],
    );
  }
}

// ── Regime cards ──────────────────────────────────────────────────────────────

class _RegimeCards extends StatelessWidget {
  final IvAnalysis analysis;
  const _RegimeCards({required this.analysis});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _RegimeCard(
          title:  'GAMMA REGIME',
          label:  analysis.gammaRegime.label,
          desc:   analysis.gammaRegime.description,
          color:  analysis.gammaRegime == GammaRegime.positive
              ? AppTheme.profitColor
              : analysis.gammaRegime == GammaRegime.negative
                  ? AppTheme.lossColor
                  : AppTheme.neutralColor,
          icon:   analysis.gammaRegime == GammaRegime.positive
              ? Icons.compress_rounded
              : Icons.open_in_full_rounded,
        )),
        const SizedBox(width: 10),
        Expanded(child: _RegimeCard(
          title:  'VANNA REGIME',
          label:  analysis.vannaRegime.label,
          desc:   analysis.vannaRegime.description,
          color:  switch (analysis.vannaRegime) {
            VannaRegime.bullishOnVolCrush => AppTheme.profitColor,
            VannaRegime.bearishOnVolCrush => AppTheme.lossColor,
            VannaRegime.bullishOnVolSpike => AppTheme.profitColor,
            VannaRegime.bearishOnVolSpike => AppTheme.lossColor,
            VannaRegime.unknown           => AppTheme.neutralColor,
          },
          icon: switch (analysis.vannaRegime) {
            VannaRegime.bullishOnVolCrush ||
            VannaRegime.bullishOnVolSpike => Icons.trending_up_rounded,
            VannaRegime.bearishOnVolCrush ||
            VannaRegime.bearishOnVolSpike => Icons.trending_down_rounded,
            VannaRegime.unknown           => Icons.help_outline_rounded,
          },
        )),
      ],
    );
  }
}

class _RegimeCard extends StatelessWidget {
  final String title;
  final String label;
  final String desc;
  final Color  color;
  final IconData icon;
  const _RegimeCard({
    required this.title,
    required this.label,
    required this.desc,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10,
                  fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: color, fontSize: 12,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(desc,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ── VEX bar chart ─────────────────────────────────────────────────────────────

class _VexChart extends StatelessWidget {
  final IvAnalysis analysis;
  const _VexChart({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final strikes = analysis.secondOrder;
    final spot    = analysis.underlyingPrice ?? 0.0;

    return AnalyticsCard(
      title: 'VANNA EXPOSURE (VEX)',
      actions: [
        if (analysis.totalVex != null)
          _statChip(
              analysis.vexLabel,
              analysis.totalVex! >= 0
                  ? AppTheme.profitColor
                  : AppTheme.lossColor),
      ],
      children: [
          const SizedBox(height: 4),
          const Text(
            '\$ dealer delta pressure per 1 vol-pt IV move — positive = vol drop triggers buying',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
          const SizedBox(height: 14),

          if (strikes.isEmpty || spot <= 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('No VEX data — open options chain first',
                    style: TextStyle(color: AppTheme.neutralColor)),
              ),
            )
          else
            SizedBox(
              height: 160,
              child: _VexBarChart(
                strikes:      strikes,
                spot:         spot,
                maxVexStrike: analysis.maxVexStrike,
              ),
            ),

          if (analysis.maxVexStrike != null) ...[
            const SizedBox(height: 8),
            Text(
              'Max VEX at \$${analysis.maxVexStrike!.toStringAsFixed(0)} — '
              'this strike is the key dealer delta-hedging level for vol moves.',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
      ],
    );
  }

  Widget _statChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(5),
      border:       Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(label,
        style: TextStyle(color: color, fontSize: 10,
            fontWeight: FontWeight.w700)),
  );
}

class _VexBarChart extends StatelessWidget {
  final List<SecondOrderStrike> strikes;
  final double spot;
  final double? maxVexStrike;
  const _VexBarChart({
    required this.strikes,
    required this.spot,
    required this.maxVexStrike,
  });

  @override
  Widget build(BuildContext context) {
    // Take top 20 by absolute VEX, sorted by strike
    final indexed = strikes.asMap().entries.toList()
      ..sort((a, b) => b.value.dealerVex(spot).abs()
          .compareTo(a.value.dealerVex(spot).abs()));
    final topSet = indexed.take(20).map((e) => e.key).toSet();
    final display = strikes.asMap().entries
        .where((e) => topSet.contains(e.key))
        .toList()
        ..sort((a, b) => a.value.strike.compareTo(b.value.strike));

    if (display.isEmpty) return const SizedBox.shrink();

    final absMax = display
        .map((e) => e.value.dealerVex(spot).abs())
        .reduce((a, b) => a > b ? a : b);
    if (absMax == 0) return const SizedBox.shrink();

    final maxY = absMax * 1.15;

    return BarChart(BarChartData(
      alignment:    BarChartAlignment.spaceAround,
      maxY:         maxY,
      minY:         -maxY,
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppTheme.elevatedColor,
          getTooltipItem: (group, _, rod, _) {
            final s = display[group.x].value;
            return BarTooltipItem(
              '\$${s.strike.toStringAsFixed(0)}\nVEX: ${_fmtDollars(rod.toY)}/vol-pt',
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
          color: Colors.white.withValues(alpha: 0.25), strokeWidth: 1),
      ),
      titlesData: FlTitlesData(
        leftTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles:   true,
            reservedSize: 28,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= display.length) return const SizedBox.shrink();
              final strike = display[i].value.strike;
              final isKey  = maxVexStrike != null &&
                  (strike - maxVexStrike!).abs() < 0.5;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('\$${strike.toStringAsFixed(0)}',
                    style: TextStyle(
                      color:      isKey ? Colors.white : AppTheme.neutralColor,
                      fontSize:   8,
                      fontWeight: isKey ? FontWeight.w800 : FontWeight.normal,
                    )),
              );
            },
          ),
        ),
      ),
      barGroups: List.generate(display.length, (i) {
        final s     = display[i].value;
        final vex   = s.dealerVex(spot);
        final isKey = maxVexStrike != null &&
            (s.strike - maxVexStrike!).abs() < 0.5;
        final color = vex >= 0
            ? (isKey ? AppTheme.profitColor
                     : AppTheme.profitColor.withValues(alpha: 0.6))
            : (isKey ? AppTheme.lossColor
                     : AppTheme.lossColor.withValues(alpha: 0.6));
        return BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: vex, fromY: 0, color: color, width: isKey ? 10 : 7,
            borderRadius: vex >= 0
                ? const BorderRadius.vertical(top: Radius.circular(3))
                : const BorderRadius.vertical(bottom: Radius.circular(3)),
          ),
        ]);
      }),
    ));
  }

  static String _fmtDollars(double v) {
    final abs = v.abs();
    final sign = v >= 0 ? '+' : '-';
    if (abs >= 1e9) return '$sign\$${(abs / 1e9).toStringAsFixed(1)}B';
    if (abs >= 1e6) return '$sign\$${(abs / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '$sign\$${(abs / 1e3).toStringAsFixed(0)}K';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }
}

// ── Charm + Volga summary ─────────────────────────────────────────────────────

class _CharmVolgaSummary extends StatelessWidget {
  final IvAnalysis analysis;
  const _CharmVolgaSummary({required this.analysis});

  @override
  Widget build(BuildContext context) {
    return AnalyticsCard(
      title: 'CHARM & VOLGA',
      children: [
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _statBlock(
                label:    'Charm (CEX)',
                value:    analysis.cexLabel,
                subtitle: 'Delta decay per day',
                color:    (analysis.totalCex ?? 0) >= 0
                    ? AppTheme.profitColor : AppTheme.lossColor,
              )),
              const SizedBox(width: 10),
              Expanded(child: _statBlock(
                label:    'Volga',
                value:    analysis.totalVolga != null
                    ? '${_VexBarChart._fmtDollars(analysis.totalVolga!)}/pt'
                    : '—',
                subtitle: 'Vega change per 1 vol-pt IV move',
                color:    const Color(0xFF60A5FA),
              )),
            ],
          ),
          const SizedBox(height: 12),
          _charmInterpretation(analysis),
          const SizedBox(height: 8),
          _volgaInterpretation(analysis),
      ],
    );
  }

  Widget _statBlock({
    required String label,
    required String value,
    required String subtitle,
    required Color  color,
  }) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color:        AppTheme.elevatedColor,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(
            color: AppTheme.neutralColor, fontSize: 10,
            fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(
            color: color, fontSize: 18, fontWeight: FontWeight.w900)),
        Text(subtitle, style: const TextStyle(
            color: AppTheme.neutralColor, fontSize: 10)),
      ],
    ),
  );

  Widget _charmInterpretation(IvAnalysis a) {
    final cex = a.totalCex;
    String text;
    if (cex == null) {
      text = 'Charm data unavailable.';
    } else if (cex > 0) {
      text = 'Positive CEX (${a.cexLabel}): as time passes, dealers accumulate '
          'long delta. Expect intraday "buying pressure" — particularly near market '
          'close as hedges are unwound. Bullish AM drift common in this regime.';
    } else {
      text = 'Negative CEX (${a.cexLabel}): dealers shed delta as time passes. '
          'Expect selling pressure to build through the session. Watch for '
          'end-of-day weakness as hedges roll off.';
    }
    return _interpretationBox(Icons.access_time_rounded, 'Charm', text);
  }

  Widget _volgaInterpretation(IvAnalysis a) {
    final volga = a.totalVolga;
    String text;
    if (volga == null) {
      text = 'Volga data unavailable.';
    } else if (volga.abs() < 10000) {
      // < $10K vega per vol-pt across the whole chain = negligible convexity
      text = 'Low Volga — options pricing is relatively insensitive to '
          'vol-of-vol. Skew and smile effects are muted.';
    } else if (volga > 0) {
      text = 'Positive Volga — dealers are short vol convexity. Large IV '
          'moves (in either direction) hurt dealers → they bid up wings to '
          'hedge, steepening the skew. Watch for smile-amplifying reactions '
          'around catalysts (earnings, macro prints).';
    } else {
      text = 'Negative Volga — dealers are long vol convexity. They benefit '
          'from IV spikes. Less incentive to bid wings; skew may flatten '
          'post-event as dealer hedging pressure normalises.';
    }
    return _interpretationBox(Icons.waves_rounded, 'Volga (Vomma)', text);
  }

  Widget _interpretationBox(IconData icon, String title, String text) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: AppTheme.neutralColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(text,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
}
