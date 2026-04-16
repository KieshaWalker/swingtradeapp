// =============================================================================
// features/greek_grid/widgets/greek_cell_detail_sheet.dart
// =============================================================================
// Bottom sheet: shows all greeks for a tapped (StrikeBand × ExpiryBucket)
// cell and a line chart of the selected greek over observation dates.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme.dart';
import '../models/greek_grid_models.dart';
import '../providers/greek_grid_providers.dart';

class GreekCellDetailSheet extends ConsumerStatefulWidget {
  final String       ticker;
  final StrikeBand   band;
  final ExpiryBucket bucket;

  const GreekCellDetailSheet({
    super.key,
    required this.ticker,
    required this.band,
    required this.bucket,
  });

  @override
  ConsumerState<GreekCellDetailSheet> createState() =>
      _GreekCellDetailSheetState();
}

class _GreekCellDetailSheetState
    extends ConsumerState<GreekCellDetailSheet> {
  GreekSelector _chartGreek = GreekSelector.delta;

  @override
  Widget build(BuildContext context) {
    final series = ref.watch(greekGridTimeSeriesProvider(
        (widget.ticker, widget.band, widget.bucket)));

    final latest = series.isNotEmpty ? series.last : null;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize:     0.35,
      maxChildSize:     0.85,
      expand:           false,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Text(
              '${widget.band.label}  ×  ${widget.bucket.label}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700),
            ),
            Text(
              '${series.length} observation${series.length == 1 ? '' : 's'}  ·  ${widget.ticker}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),

            // All-greeks chip row (latest values)
            if (latest != null) _GreekChips(point: latest),
            const SizedBox(height: 16),

            // Chart greek selector
            _ChartGreekSelector(
              selected: _chartGreek,
              onChanged: (g) => setState(() => _chartGreek = g),
            ),
            const SizedBox(height: 12),

            // Time-series chart
            if (series.length >= 2)
              SizedBox(
                height: 160,
                child: _TimeSeriesChart(
                    series: series, greek: _chartGreek),
              )
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Need ≥2 observations to show chart.\nOpen the chain screen again tomorrow.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Greek chips ───────────────────────────────────────────────────────────────

class _GreekChips extends StatelessWidget {
  final GreekGridPoint point;
  const _GreekChips({required this.point});

  @override
  Widget build(BuildContext context) {
    String fmt(double? v, GreekSelector g) {
      if (v == null) return '—';
      if (g == GreekSelector.iv) return '${(v * 100).toStringAsFixed(1)}%';
      if (v.abs() < 0.001) return v.toStringAsExponential(1);
      return v.toStringAsFixed(3);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: GreekSelector.values.map((g) {
        final v = point.greekValue(g);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color:        AppTheme.cardColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(g.shortLabel,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 10)),
              Text(fmt(v, g),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Chart greek selector ──────────────────────────────────────────────────────

class _ChartGreekSelector extends StatelessWidget {
  final GreekSelector selected;
  final ValueChanged<GreekSelector> onChanged;
  const _ChartGreekSelector(
      {required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: GreekSelector.values.map((g) {
          final active = g == selected;
          return GestureDetector(
            onTap: () => onChanged(g),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color:        active ? AppTheme.profitColor : AppTheme.cardColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                g.shortLabel,
                style: TextStyle(
                  color:      active ? Colors.black : Colors.white70,
                  fontSize:   12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Time-series line chart ────────────────────────────────────────────────────

class _TimeSeriesChart extends StatelessWidget {
  final List<GreekGridPoint> series;
  final GreekSelector        greek;
  const _TimeSeriesChart({required this.series, required this.greek});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < series.length; i++) {
      final v = series[i].greekValue(greek);
      if (v != null) spots.add(FlSpot(i.toDouble(), v));
    }
    if (spots.isEmpty) {
      return const Center(
        child: Text('No data for this greek',
            style: TextStyle(color: Colors.white38)),
      );
    }

    final fmt = DateFormat('MMM d');

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.white10, strokeWidth: 0.5),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, _) => Text(
                greek == GreekSelector.iv
                    ? '${(v * 100).toStringAsFixed(0)}%'
                    : v.toStringAsFixed(2),
                style: const TextStyle(
                    color: Colors.white38, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (series.length / 4).ceilToDouble().clamp(1, 9999),
              getTitlesWidget: (v, _) {
                final idx = v.toInt().clamp(0, series.length - 1);
                return Text(
                  fmt.format(series[idx].obsDate),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 9),
                );
              },
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
            spots:          spots,
            isCurved:       true,
            color:          AppTheme.profitColor,
            barWidth:       2,
            dotData:        const FlDotData(show: false),
            belowBarData:   BarAreaData(
              show: true,
              color: AppTheme.profitColor.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );
  }
}
