// =============================================================================
// features/positions/widgets/leg_history_charts.dart
// =============================================================================
// Two time-series charts over a leg's own LegSnapshot history (position_leg_
// snapshots) — implied vol and P&L vs entry. Chrome from ChartCard, pan/zoom
// from PannableChart, same pattern as features/iv/widgets/realized_vol_chart
// .dart. Both were previously stored but never charted (table-only).
//
// P&L uses (marketPrice - entryPrice) * quantity -- no *100 multiplier,
// matching EnrichedLeg._edge()'s existing convention elsewhere on this page
// (position_models.dart) so the numbers read consistently against the
// Greek/edge tiles already shown on the same card.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/chart/chart_card.dart';
import '../../../core/widgets/chart/pannable_chart.dart';
import '../models/position_models.dart';

class LegIvHistoryChart extends StatelessWidget {
  final List<LegSnapshot> snapshots;
  const LegIvHistoryChart({super.key, required this.snapshots});

  @override
  Widget build(BuildContext context) {
    final v = snapshots.where((s) => s.impliedVol != null).toList()
      ..sort((a, b) => a.snapshotDate.compareTo(b.snapshotDate));

    final last = v.isNotEmpty ? v.last : null;

    return ChartCard(
      title: 'IV HISTORY',
      height: 160,
      stats: last == null
          ? null
          : Wrap(spacing: 8, children: [
              ChartStatChip(
                label: 'Latest',
                value: '${(last.impliedVol! * 100).toStringAsFixed(1)}%',
                dotColor: ChartPalette.indigo,
              ),
            ]),
      child: v.length < 2
          ? const ChartEmptyState(
              icon: Icons.show_chart_rounded,
              title: 'Not enough history yet',
              message: 'IV history builds up one snapshot per trading day.',
            )
          : _IvPlot(snaps: v),
    );
  }
}

class _IvPlot extends StatelessWidget {
  final List<LegSnapshot> snaps;
  const _IvPlot({required this.snaps});

  @override
  Widget build(BuildContext context) {
    final n = snaps.length;
    final spots = List.generate(
        n, (i) => FlSpot(i.toDouble(), snaps[i].impliedVol! * 100));
    final vals = spots.map((s) => s.y).toList();
    final minY = (vals.reduce((a, b) => a < b ? a : b) * 0.9);
    final maxY = (vals.reduce((a, b) => a > b ? a : b) * 1.1);

    return PannableChart(
      count: n,
      builder: (ctx, minX, maxX) => LineChart(LineChartData(
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
              color: AppTheme.borderColor.withValues(alpha: 0.3), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, _) => Text('${v.toStringAsFixed(0)}%',
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
                final d = snaps[i].snapshotDate;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.month}/${d.day}',
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
            spots: spots,
            isCurved: true,
            color: ChartPalette.indigo,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
                show: true, color: ChartPalette.indigo.withValues(alpha: 0.08)),
          ),
        ],
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            fitInsideHorizontally: true,
            getTooltipItems: (spots) => spots.map((ts) {
              final i = ts.x.toInt().clamp(0, n - 1);
              final s = snaps[i];
              return LineTooltipItem(
                '${s.snapshotDate.month}/${s.snapshotDate.day}/${s.snapshotDate.year}\n'
                'IV  ${(s.impliedVol! * 100).toStringAsFixed(1)}%',
                const TextStyle(color: Colors.white, fontSize: 10, height: 1.5),
              );
            }).toList(),
          ),
        ),
      )),
    );
  }
}

class LegPnlHistoryChart extends StatelessWidget {
  final List<LegSnapshot> snapshots;
  final double? entryPrice;
  final int quantity;
  const LegPnlHistoryChart({
    super.key,
    required this.snapshots,
    required this.entryPrice,
    required this.quantity,
  });

  @override
  Widget build(BuildContext context) {
    final entry = entryPrice;
    if (entry == null) {
      return const ChartCard(
        title: 'P&L HISTORY',
        height: 160,
        child: ChartEmptyState(
          icon: Icons.trending_up_rounded,
          title: 'No entry price recorded',
          message: 'P&L needs an entry price to compare against.',
        ),
      );
    }

    final v = snapshots.where((s) => s.marketPrice != null).toList()
      ..sort((a, b) => a.snapshotDate.compareTo(b.snapshotDate));

    final lastPnl =
        v.isNotEmpty ? (v.last.marketPrice! - entry) * quantity : null;
    final pnlColor = (lastPnl ?? 0) >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return ChartCard(
      title: 'P&L HISTORY',
      height: 160,
      stats: lastPnl == null
          ? null
          : Wrap(spacing: 8, children: [
              ChartStatChip(
                label: 'Latest',
                value: '${lastPnl >= 0 ? '+' : ''}${lastPnl.toStringAsFixed(2)}',
                dotColor: pnlColor,
              ),
            ]),
      child: v.length < 2
          ? const ChartEmptyState(
              icon: Icons.trending_up_rounded,
              title: 'Not enough history yet',
              message: 'P&L history builds up one snapshot per trading day.',
            )
          : _PnlPlot(snaps: v, entryPrice: entry, quantity: quantity),
    );
  }
}

class _PnlPlot extends StatelessWidget {
  final List<LegSnapshot> snaps;
  final double entryPrice;
  final int quantity;
  const _PnlPlot({
    required this.snaps,
    required this.entryPrice,
    required this.quantity,
  });

  @override
  Widget build(BuildContext context) {
    final n = snaps.length;
    final spots = List.generate(n, (i) {
      final pnl = (snaps[i].marketPrice! - entryPrice) * quantity;
      return FlSpot(i.toDouble(), pnl);
    });
    final vals = spots.map((s) => s.y).toList();
    var minY = vals.reduce((a, b) => a < b ? a : b);
    var maxY = vals.reduce((a, b) => a > b ? a : b);
    // Always include zero so the profit/loss line is visible on the axis.
    minY = (minY < 0 ? minY * 1.15 : 0);
    maxY = (maxY > 0 ? maxY * 1.15 : 0);
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    final positive = ChartPalette.green;
    final negative = const Color(0xFFFF7B72);
    final lineColor = spots.last.y >= 0 ? positive : negative;

    return PannableChart(
      count: n,
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
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
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
                final d = snaps[i].snapshotDate;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.month}/${d.day}',
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
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData:
                BarAreaData(show: true, color: lineColor.withValues(alpha: 0.10)),
          ),
        ],
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            fitInsideHorizontally: true,
            getTooltipItems: (spots) => spots.map((ts) {
              final i = ts.x.toInt().clamp(0, n - 1);
              final s = snaps[i];
              final pnl = (s.marketPrice! - entryPrice) * quantity;
              return LineTooltipItem(
                '${s.snapshotDate.month}/${s.snapshotDate.day}/${s.snapshotDate.year}\n'
                'Mkt \$${s.marketPrice!.toStringAsFixed(2)}\n'
                'P&L ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}',
                const TextStyle(color: Colors.white, fontSize: 10, height: 1.5),
              );
            }).toList(),
          ),
        ),
      )),
    );
  }
}
