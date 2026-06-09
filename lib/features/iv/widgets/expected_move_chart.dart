// =============================================================================
// features/iv/widgets/expected_move_chart.dart
// =============================================================================
// IV-implied expected move bands for a ticker.
//
// Shows the last 90 daily or 252 monthly snapshots from expected_move_snapshots,
// with price bands at ±1σ (68%), ±2σ (95%), and ±3σ (99.7%).
//
// Chart layout (bottom → top):
//   lower_3s ─ lower_2s ─ lower_1s ─ spot ─ upper_1s ─ upper_2s ─ upper_3s
//   Red fill between ±2σ–3σ bands, yellow ±1σ–2σ, green ±1σ (centre).
//
// Chrome (card, header, segmented control, legend) comes from ChartCard;
// pan / zoom / pinch / fullscreen come from PannableChart.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/iv/expected_move_models.dart';
import '../../../services/iv/expected_move_providers.dart';
import '../../../core/widgets/chart/chart_card.dart';
import '../../../core/widgets/chart/pannable_chart.dart';

const _green = ChartPalette.green;
const _yellow = ChartPalette.yellow;
const _red = ChartPalette.red;

const _legend = [
  ChartLegendItem(_green, '±1σ  68%'),
  ChartLegendItem(_yellow, '±2σ  95%'),
  ChartLegendItem(_red, '±3σ  99.7%'),
];

final _money = NumberFormat('\$#,##0.00');

class ExpectedMoveChart extends ConsumerStatefulWidget {
  final String ticker;
  const ExpectedMoveChart({super.key, required this.ticker});

  @override
  ConsumerState<ExpectedMoveChart> createState() => _ExpectedMoveChartState();
}

class _ExpectedMoveChartState extends ConsumerState<ExpectedMoveChart> {
  int _tab = 0; // 0 = daily, 1 = monthly

  @override
  Widget build(BuildContext context) {
    final dailyAsync = ref.watch(expectedMoveDailyProvider(widget.ticker));
    final monthlyAsync = ref.watch(expectedMoveMonthlyProvider(widget.ticker));
    final current = _tab == 0 ? dailyAsync : monthlyAsync;

    final snaps = current.valueOrNull?.where((s) => s.hasBands).toList() ?? [];
    final last = snaps.isNotEmpty ? snaps.last : null;
    final canExpand = snaps.length >= 2;

    return ChartCard(
      title: 'EXPECTED MOVE',
      height: 280,
      actions: [
        if (canExpand)
          ChartActionButton(
            icon: Icons.fullscreen,
            tooltip: 'Expand chart',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChartFullScreenScaffold(
                  title: '${widget.ticker} — Expected Move',
                  legend: _legend,
                  child: _BandChart(snapshots: snaps, showZoomButtons: true),
                ),
              ),
            ),
          ),
      ],
      stats: last == null
          ? null
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChartStatChip(
                  label: 'Spot',
                  value: _money.format(last.spot),
                  dotColor: Colors.white,
                ),
                ChartStatChip(label: 'IV', value: fmtPct(last.iv)),
                ChartStatChip(
                  label: 'EM',
                  value: '±\$${last.emDollars?.toStringAsFixed(2) ?? '—'}',
                ),
              ],
            ),
      segmentedControl: ChartSegmentedTabs(
        labels: const ['DAILY', 'MONTHLY'],
        selected: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
      legend: _legend,
      child: current.when(
        loading: () => const ChartMessage.loading(),
        error: (_, _) => const ChartMessage.error(),
        data: (all) {
          final valid = all.where((s) => s.hasBands).toList();
          if (valid.isEmpty) return const _EmptyState();
          if (valid.length == 1) return _SingleSnapshot(snapshot: valid.first);
          return _BandChart(snapshots: valid);
        },
      ),
    );
  }
}

// ── Band chart ──────────────────────────────────────────────────────────────

class _BandChart extends StatelessWidget {
  final List<ExpectedMoveSnapshot> snapshots;
  final bool showZoomButtons;
  const _BandChart({required this.snapshots, this.showZoomButtons = false});

  @override
  Widget build(BuildContext context) => PannableChart(
        count: snapshots.length,
        leftAxisWidth: 54, // matches the band chart's left-axis reservedSize
        showZoomButtons: showZoomButtons,
        builder: (ctx, minX, maxX) => _chart(minX, maxX),
      );

  LineChart _chart(double minX, double maxX) {
    final n = snapshots.length;

    // Index: 0=lower3s 1=lower2s 2=lower1s 3=upper1s 4=upper2s 5=upper3s 6=spot
    List<FlSpot> toSpots(double? Function(ExpectedMoveSnapshot) fn) =>
        List.generate(n, (i) => FlSpot(i.toDouble(), fn(snapshots[i]) ?? 0));

    final l3 = toSpots((s) => s.lower3s);
    final l2 = toSpots((s) => s.lower2s);
    final l1 = toSpots((s) => s.lower1s);
    final u1 = toSpots((s) => s.upper1s);
    final u2 = toSpots((s) => s.upper2s);
    final u3 = toSpots((s) => s.upper3s);
    final sp = toSpots((s) => s.spot);

    final allPrices = snapshots.expand((s) => [
          s.lower3s!, s.lower2s!, s.lower1s!, s.spot,
          s.upper1s!, s.upper2s!, s.upper3s!,
        ]);
    final minY = allPrices.reduce((a, b) => a < b ? a : b) * 0.995;
    final maxY = allPrices.reduce((a, b) => a > b ? a : b) * 1.005;

    final window = maxX - minX;
    final interval = (window / 4).ceilToDouble().clamp(1.0, double.infinity);

    LineChartBarData bandBar(List<FlSpot> bSpots, Color color) =>
        LineChartBarData(
          spots: bSpots,
          isCurved: true,
          color: color.withValues(alpha: 0.4),
          barWidth: 1,
          dotData: const FlDotData(show: false),
          dashArray: [4, 4],
        );

    return LineChart(LineChartData(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      clipData: const FlClipData.all(),
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
            reservedSize: 54,
            getTitlesWidget: (v, _) => Text(
              '\$${v.toStringAsFixed(0)}',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: interval,
            getTitlesWidget: (v, _) {
              final i = v.round();
              if (i < 0 || i >= n) return const SizedBox.shrink();
              final d = snapshots[i].date;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${d.month}/${d.day}',
                  style:
                      const TextStyle(color: AppTheme.neutralColor, fontSize: 9),
                ),
              );
            },
          ),
        ),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),

      // Fills: 0↔1 outer red, 1↔2 yellow, 2↔3 green 1σ, 3↔4 yellow, 4↔5 red
      betweenBarsData: [
        BetweenBarsData(fromIndex: 0, toIndex: 1, color: _red.withValues(alpha: 0.10)),
        BetweenBarsData(fromIndex: 1, toIndex: 2, color: _yellow.withValues(alpha: 0.12)),
        BetweenBarsData(fromIndex: 2, toIndex: 3, color: _green.withValues(alpha: 0.18)),
        BetweenBarsData(fromIndex: 3, toIndex: 4, color: _yellow.withValues(alpha: 0.12)),
        BetweenBarsData(fromIndex: 4, toIndex: 5, color: _red.withValues(alpha: 0.10)),
      ],

      lineBarsData: [
        bandBar(l3, _red), // 0
        bandBar(l2, _yellow), // 1
        bandBar(l1, _green), // 2
        bandBar(u1, _green), // 3
        bandBar(u2, _yellow), // 4
        bandBar(u3, _red), // 5
        LineChartBarData( // 6: spot — solid white on top
          spots: sp,
          isCurved: true,
          color: Colors.white,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      ],

      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => AppTheme.elevatedColor,
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItems: (touchedSpots) {
            // Only the spot line (index 6) carries the tooltip text.
            final spotLine = touchedSpots.firstWhere(
              (s) => s.barIndex == 6,
              orElse: () => touchedSpots.first,
            );
            final i = spotLine.x.toInt().clamp(0, n - 1);
            final s = snapshots[i];
            return touchedSpots.map((ts) {
              if (ts.barIndex != 6) return const LineTooltipItem('', TextStyle());
              return LineTooltipItem(
                '${s.date.month}/${s.date.day}/${s.date.year}\n'
                'Spot  ${_money.format(s.spot)}\n'
                '±1σ   ${_money.format(s.lower1s!)} – ${_money.format(s.upper1s!)}\n'
                '±2σ   ${_money.format(s.lower2s!)} – ${_money.format(s.upper2s!)}\n'
                '±3σ   ${_money.format(s.lower3s!)} – ${_money.format(s.upper3s!)}',
                const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              );
            }).toList();
          },
        ),
      ),
    ));
  }
}

// ── Single snapshot (only one close collected) ──────────────────────────────

class _SingleSnapshot extends StatelessWidget {
  final ExpectedMoveSnapshot snapshot;
  const _SingleSnapshot({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final s = snapshot;

    Widget row(String label, Color color, double? lo, double? hi) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: Text(label,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
              ),
              Text(
                lo != null && hi != null
                    ? '${_money.format(lo)}  –  ${_money.format(hi)}'
                    : '—',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Spot  ${_money.format(s.spot)}   '
            'IV ${fmtPct(s.iv)}   '
            'EM ±\$${s.emDollars?.toStringAsFixed(2) ?? '—'}',
            style: const TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          row('±1σ  68%', _green, s.lower1s, s.upper1s),
          row('±2σ  95%', _yellow, s.lower2s, s.upper2s),
          row('±3σ  99.7%', _red, s.lower3s, s.upper3s),
          const SizedBox(height: 14),
          const Text(
            'Chart builds after 2+ market closes.',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const ChartEmptyState(
        icon: Icons.candlestick_chart_rounded,
        title: 'No data yet',
        message: 'Expected move bands are captured at market close\n'
            'each weekday by the backend pipeline.',
      );
}
