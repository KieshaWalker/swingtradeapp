// =============================================================================
// features/iv/widgets/expected_move_chart.dart
// =============================================================================
// IV-implied expected move bands for a ticker.
//
// Shows the last 90 daily or 24 monthly snapshots from expected_move_snapshots,
// with price bands at ±1σ (68%), ±2σ (95%), and ±3σ (99.7%).
//
// Chart layout (bottom → top):
//   lower_3s ─ lower_2s ─ lower_1s ─ spot ─ upper_1s ─ upper_2s ─ upper_3s
//   Red fill between ±2σ–3σ bands, yellow ±1σ–2σ, green ±1σ (centre).
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/iv/expected_move_models.dart';
import '../../../services/iv/expected_move_providers.dart';

// Band palette
const _green  = Color(0xFF4ADE80);
const _yellow = Color(0xFFFBBF24);
const _red    = Color(0xFFFF7B72);

class ExpectedMoveChart extends ConsumerStatefulWidget {
  final String ticker;
  const ExpectedMoveChart({super.key, required this.ticker});

  @override
  ConsumerState<ExpectedMoveChart> createState() => _ExpectedMoveChartState();
}

class _ExpectedMoveChartState extends ConsumerState<ExpectedMoveChart>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dailyAsync   = ref.watch(expectedMoveDailyProvider(widget.ticker));
    final monthlyAsync = ref.watch(expectedMoveMonthlyProvider(widget.ticker));

    final current = _tabs.index == 0 ? dailyAsync : monthlyAsync;

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                const Text(
                  'EXPECTED MOVE',
                  style: TextStyle(
                    color:         AppTheme.neutralColor,
                    fontSize:      11,
                    fontWeight:    FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                current.whenOrNull(
                  data: (snaps) {
                    final valid = snaps.where((s) => s.hasBands).toList();
                    if (valid.isEmpty) return null;
                    final last = valid.last;
                    return Text(
                      'IV ${((last.iv ?? 0) * 100).toStringAsFixed(1)}%  '
                      '±\$${last.emDollars?.toStringAsFixed(2) ?? '—'}',
                      style: const TextStyle(
                        color:      AppTheme.neutralColor,
                        fontSize:   10,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ) ?? const SizedBox.shrink(),
              ],
            ),
          ),

          // ── Tab bar ────────────────────────────────────────────────────
          TabBar(
            controller:           _tabs,
            indicatorColor:       AppTheme.profitColor,
            labelColor:           AppTheme.profitColor,
            unselectedLabelColor: AppTheme.neutralColor,
            labelStyle:    const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            indicatorSize: TabBarIndicatorSize.label,
            tabs: const [
              Tab(text: 'DAILY'),
              Tab(text: 'MONTHLY'),
            ],
          ),

          const Divider(height: 1, color: AppTheme.borderColor),

          // ── Chart ──────────────────────────────────────────────────────
          SizedBox(
            height: 280,
            child: current.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => Center(
                child: Text('Error loading data',
                    style: const TextStyle(color: AppTheme.neutralColor)),
              ),
              data: (snaps) {
                final valid = snaps.where((s) => s.hasBands).toList();
                if (valid.length < 2) {
                  return _EmptyState(count: valid.length);
                }
                return _BandChart(snapshots: valid);
              },
            ),
          ),

          // ── Legend ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendItem(_green,  '±1σ  68%'),
                const SizedBox(width: 14),
                _legendItem(_yellow, '±2σ  95%'),
                const SizedBox(width: 14),
                _legendItem(_red,    '±3σ  99.7%'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) => Row(
    children: [
      Container(
        width: 12, height: 3,
        decoration: BoxDecoration(
          color:        color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label,
          style: const TextStyle(
              color: AppTheme.neutralColor, fontSize: 10)),
    ],
  );
}

// ── Band chart ────────────────────────────────────────────────────────────────

class _BandChart extends StatelessWidget {
  final List<ExpectedMoveSnapshot> snapshots;
  const _BandChart({required this.snapshots});

  @override
  Widget build(BuildContext context) {
    final n = snapshots.length;

    // Build FlSpot lists — bar order determines BetweenBarsData fill pairing
    // Index: 0=lower3s  1=lower2s  2=lower1s  3=upper1s  4=upper2s  5=upper3s  6=spot
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
    ]).toList();
    final minY = allPrices.reduce((a, b) => a < b ? a : b) * 0.995;
    final maxY = allPrices.reduce((a, b) => a > b ? a : b) * 1.005;

    final fmt = NumberFormat('\$#,##0.00');

    LineChartBarData bandBar(List<FlSpot> bSpots, Color color) =>
        LineChartBarData(
          spots:    bSpots,
          isCurved: true,
          color:    color.withValues(alpha: 0.4),
          barWidth: 1,
          dotData:  const FlDotData(show: false),
          dashArray: [4, 4],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 12, 8),
      child: LineChart(LineChartData(
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show:             true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color:       AppTheme.borderColor.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles:   true,
              reservedSize: 54,
              getTitlesWidget: (v, _) => Text(
                '\$${v.toStringAsFixed(0)}',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles:   true,
              reservedSize: 22,
              interval:     (n / 4).ceilToDouble().clamp(1, double.infinity),
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= n) return const SizedBox.shrink();
                final d = snapshots[i].date;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${d.month}/${d.day}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 9),
                  ),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),

        // Fills: 0↔1 = outer red, 1↔2 = yellow, 2↔3 = green 1σ, 3↔4 = yellow, 4↔5 = outer red
        betweenBarsData: [
          BetweenBarsData(
            fromIndex: 0, toIndex: 1,
            color: _red.withValues(alpha: 0.10),
          ),
          BetweenBarsData(
            fromIndex: 1, toIndex: 2,
            color: _yellow.withValues(alpha: 0.12),
          ),
          BetweenBarsData(
            fromIndex: 2, toIndex: 3,
            color: _green.withValues(alpha: 0.18),
          ),
          BetweenBarsData(
            fromIndex: 3, toIndex: 4,
            color: _yellow.withValues(alpha: 0.12),
          ),
          BetweenBarsData(
            fromIndex: 4, toIndex: 5,
            color: _red.withValues(alpha: 0.10),
          ),
        ],

        lineBarsData: [
          // 0: lower_3s
          bandBar(l3, _red),
          // 1: lower_2s
          bandBar(l2, _yellow),
          // 2: lower_1s
          bandBar(l1, _green),
          // 3: upper_1s
          bandBar(u1, _green),
          // 4: upper_2s
          bandBar(u2, _yellow),
          // 5: upper_3s
          bandBar(u3, _red),
          // 6: spot — solid white on top
          LineChartBarData(
            spots:    sp,
            isCurved: true,
            color:    Colors.white,
            barWidth: 2,
            dotData:  const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],

        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.elevatedColor,
            fitInsideHorizontally: true,
            fitInsideVertically:   true,
            getTooltipItems: (touchedSpots) {
              // Only show tooltip from the spot line (index 6)
              final spotLine = touchedSpots.firstWhere(
                (s) => s.barIndex == 6,
                orElse: () => touchedSpots.first,
              );
              final i = spotLine.x.toInt().clamp(0, n - 1);
              final s = snapshots[i];
              return touchedSpots.map((ts) {
                if (ts.barIndex != 6) {
                  return LineTooltipItem('', const TextStyle());
                }
                return LineTooltipItem(
                  '${s.date.month}/${s.date.day}/${s.date.year}\n'
                  'Spot  ${fmt.format(s.spot)}\n'
                  '±1σ   ${fmt.format(s.lower1s!)} – ${fmt.format(s.upper1s!)}\n'
                  '±2σ   ${fmt.format(s.lower2s!)} – ${fmt.format(s.upper2s!)}\n'
                  '±3σ   ${fmt.format(s.lower3s!)} – ${fmt.format(s.upper3s!)}',
                  const TextStyle(
                    color:      Colors.white,
                    fontSize:   10,
                    height:     1.5,
                    fontFamily: 'monospace',
                  ),
                );
              }).toList();
            },
          ),
        ),
      )),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final int count;
  const _EmptyState({required this.count});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.candlestick_chart_rounded,
            size: 36,
            color: AppTheme.neutralColor.withValues(alpha: 0.5)),
        const SizedBox(height: 12),
        Text(
          count == 0 ? 'No data yet' : '$count snapshot${count == 1 ? '' : 's'} collected',
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Expected move bands are captured at market close\n'
          'each weekday by the backend pipeline.',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
