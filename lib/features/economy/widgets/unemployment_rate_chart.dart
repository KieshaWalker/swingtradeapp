// =============================================================================
// features/economy/widgets/unemployment_rate_chart.dart
// =============================================================================
// Monthly US unemployment rate (U-3) chart.
// Source: BLS LNS14000000 — stored in us_unemployment_rate_history.
// Tap to expand full-screen with interactive tooltip.
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/economy/economy_snapshot_models.dart';
import '../../../services/economy/economy_storage_providers.dart';
import '../providers/api_data_providers.dart';

const _lineColor = Color(0xFFFF7B72); // red

class UnemploymentRateChart extends ConsumerStatefulWidget {
  const UnemploymentRateChart({super.key});

  @override
  ConsumerState<UnemploymentRateChart> createState() =>
      _UnemploymentRateChartState();
}

class _UnemploymentRateChartState extends ConsumerState<UnemploymentRateChart> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ref.listen<AsyncValue>(blsEmploymentProvider, (_, next) {
      next.whenData((resp) async {
        await ref
            .read(economyStorageServiceProvider)
            .saveUnemploymentHistory(resp);
        ref.invalidate(unemploymentRateHistoryProvider);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final storageAsync = ref.watch(unemploymentRateHistoryProvider);

    return storageAsync.when(
      loading: () => const _ChartFrame(
        child: Center(
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
          return const _ChartFrame(
            child: Center(
              child: Text('No data',
                  style:
                      TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
            ),
          );
        }
        return _UnemploymentCard(points: points);
      },
    );
  }
}

// ─── Frame ────────────────────────────────────────────────────────────────────

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
          const Text('Unemployment Rate (U-3)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const Text('Monthly %  ·  BLS LNS14000000',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ─── Compact card ─────────────────────────────────────────────────────────────

class _UnemploymentCard extends StatelessWidget {
  final List<UnemploymentRatePoint> points;
  const _UnemploymentCard({required this.points});

  @override
  Widget build(BuildContext context) {
    final n = points.length;
    final spots = points
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.rate))
        .toList();
    final labelSet = _evenIndices(n, 5).toSet();
    final latest = points.last;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              _UnemploymentFullScreen(points: points, spots: spots),
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Unemployment Rate (U-3)',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      Text(
                        'Monthly %  ·  BLS LNS14000000  ·  Latest: ${latest.rate.toStringAsFixed(1)}%'
                        '  (${DateFormat('MMM yyyy').format(latest.date)})',
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.open_in_full,
                    size: 13, color: AppTheme.neutralColor),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 130,
              child: LineChart(
                  _buildData(spots, points, labelSet, compact: true)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Full-screen page ─────────────────────────────────────────────────────────

class _UnemploymentFullScreen extends StatelessWidget {
  final List<UnemploymentRatePoint> points;
  final List<FlSpot> spots;
  const _UnemploymentFullScreen(
      {required this.points, required this.spots});

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
            const Text('Unemployment Rate (U-3)',
                style: TextStyle(fontSize: 16)),
            Text(
              'Monthly %  ·  BLS LNS14000000  ·  Latest: ${latest.rate.toStringAsFixed(1)}%'
              '  (${DateFormat('MMM yyyy').format(latest.date)})',
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
  List<UnemploymentRatePoint> points,
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
                    ? DateFormat('MMM yyyy').format(points[idx].date)
                    : '';
                return LineTooltipItem(
                  '$dateStr\n${s.y.toStringAsFixed(1)}%',
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
                '${v.toStringAsFixed(1)}%',
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
        barWidth: compact ? 2 : 2.5,
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
