// =============================================================================
// features/economy/widgets/gasoline_price_history_chart.dart
// =============================================================================
// Weekly US retail gasoline price history from 1990 to present.
// Source: EIA /v2/petroleum/pri/gnd/data/ — series EMM_EPM0_PTE_NUS_DPG
//
// Flow:
//   1. On first load, reads from us_gasoline_price_history (Supabase).
//   2. Simultaneously triggers the EIA API fetch.
//   3. When EIA data arrives, upserts to Supabase and refreshes the chart.
//   4. Subsequent opens just read from Supabase (fast, offline-safe).
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/economy/economy_snapshot_models.dart';
import '../../../services/economy/economy_storage_providers.dart';
import '../../../services/economy/economy_storage_service.dart';
import '../providers/api_data_providers.dart';

const _lineColor = Color(0xFFF78166);

class GasolinePriceHistoryChart extends ConsumerWidget {
  const GasolinePriceHistoryChart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageAsync = ref.watch(gasolinePriceHistoryStorageProvider);

    // When EIA data arrives: save to Supabase, then refresh the storage provider.
    ref.listen<AsyncValue>(eiaGasolinePriceHistoryProvider, (_, next) {
      next.whenData((resp) async {
        await ref
            .read(economyStorageServiceProvider)
            .saveGasolinePriceHistory(resp);
        ref.invalidate(gasolinePriceHistoryStorageProvider);
      });
    });

    return storageAsync.when(
      loading: () => _ChartFrame(
        child: const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ),
      error: (_, _) => const _ChartFrame(
        child: Center(
          child: Text('Failed to load',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
        ),
      ),
      data: (points) {
        if (points.isEmpty) {
          // Storage empty — EIA fetch is in progress
          return _ChartFrame(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(height: 8),
                  Text('Fetching from EIA…',
                      style: TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11)),
                ],
              ),
            ),
          );
        }
        return _GasolineCard(points: points);
      },
    );
  }
}

// ─── Frame for loading / empty / error states ─────────────────────────────────

class _ChartFrame extends StatelessWidget {
  final Widget child;
  const _ChartFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 196,
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('US Retail Gasoline Price',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const Text('Weekly Avg \$/gal  ·  1990–present  ·  EIA',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ─── Compact card ─────────────────────────────────────────────────────────────

class _GasolineCard extends StatelessWidget {
  final List<GasolinePricePoint> points;
  const _GasolineCard({required this.points});

  @override
  Widget build(BuildContext context) {
    final n = points.length;
    final spots = points
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.price))
        .toList();
    final labelSet = _evenIndices(n, 5).toSet();

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => _GasolineFullScreen(points: points, spots: spots),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1C2128),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('US Retail Gasoline Price',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      Text('Weekly Avg \$/gal  ·  1990–present  ·  EIA',
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 10)),
                    ],
                  ),
                ),
                Text('$n wks',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 10)),
                const SizedBox(width: 8),
                const Icon(Icons.open_in_full,
                    size: 13, color: AppTheme.neutralColor),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 130,
              child: LineChart(_buildData(spots, points, labelSet,
                  compact: true)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Full-screen page ─────────────────────────────────────────────────────────

class _GasolineFullScreen extends StatelessWidget {
  final List<GasolinePricePoint> points;
  final List<FlSpot> spots;
  const _GasolineFullScreen({required this.points, required this.spots});

  @override
  Widget build(BuildContext context) {
    final n = points.length;
    final latest = points.last;
    final labelSet = _evenIndices(n, 7).toSet();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('US Retail Gasoline Price',
                style: TextStyle(fontSize: 16)),
            Text(
              'Weekly  ·  EIA  ·  Latest: \$${latest.price.toStringAsFixed(3)}/gal'
              '  (${DateFormat('MMM d, yyyy').format(latest.date)})',
              style: const TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: LineChart(
              _buildData(spots, points, labelSet, compact: false)),
        ),
      ),
    );
  }
}

// ─── Chart data builder ───────────────────────────────────────────────────────

LineChartData _buildData(
  List<FlSpot> spots,
  List<GasolinePricePoint> points,
  Set<int> labelSet, {
  required bool compact,
}) {
  final n = points.length;
  return LineChartData(
    gridData: FlGridData(
      show: true,
      drawVerticalLine: !compact,
      getDrawingHorizontalLine: (_) => FlLine(
        color: Colors.white.withValues(alpha: compact ? 0.05 : 0.06),
        strokeWidth: 1,
      ),
      getDrawingVerticalLine: (_) => FlLine(
        color: Colors.white.withValues(alpha: 0.04),
        strokeWidth: 1,
      ),
    ),
    borderData: FlBorderData(show: false),
    lineTouchData: compact
        ? const LineTouchData(enabled: false)
        : LineTouchData(
            enabled: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => const Color(0xFF30363D),
              getTooltipItems: (touched) => touched.map((s) {
                final idx = s.x.round();
                final dateStr = idx >= 0 && idx < n
                    ? DateFormat('MMM d, yyyy').format(points[idx].date)
                    : '';
                return LineTooltipItem(
                  '$dateStr\n\$${s.y.toStringAsFixed(3)}/gal',
                  const TextStyle(
                      color: _lineColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                );
              }).toList(),
            ),
          ),
    titlesData: FlTitlesData(
      topTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: compact ? 36 : 48,
          getTitlesWidget: (v, meta) {
            if (v != meta.min && v != meta.max) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '\$${v.toStringAsFixed(2)}',
                style: TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: compact ? 9 : 10),
                textAlign: TextAlign.right,
              ),
            );
          },
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: compact ? 22 : 28,
          interval: 1,
          getTitlesWidget: (v, _) {
            final idx = v.round();
            if (!labelSet.contains(idx) || idx < 0 || idx >= n) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: EdgeInsets.only(top: compact ? 4 : 6),
              child: Text(
                DateFormat('yyyy').format(points[idx].date),
                style: TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: compact ? 9 : 10),
              ),
            );
          },
        ),
      ),
    ),
    lineBarsData: [
      LineChartBarData(
        spots: spots,
        isCurved: true,
        color: _lineColor,
        barWidth: compact ? 1.5 : 2,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: _lineColor.withValues(alpha: 0.08),
        ),
      ),
    ],
  );
}

// ─── Even index picker ────────────────────────────────────────────────────────

List<int> _evenIndices(int total, int count) {
  if (total <= 0) return [];
  if (total <= count) return List.generate(total, (i) => i);
  if (count == 1) return [0];
  return List.generate(
    count,
    (i) => ((i * (total - 1)) / (count - 1)).round(),
  );
}
