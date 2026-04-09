// =============================================================================
// features/iv/widgets/iv_history_chart.dart
// =============================================================================
// Visualises the iv_snapshots history for a ticker.
// Each row in iv_snapshots was silently saved whenever the user opened the
// options chain — so this chart shows how IV, skew, GEX and P/C ratio have
// evolved over time without any manual effort.
//
// Tabs:
//   1. IV History  — ATM IV line + 52w high/low band + IVR bar below
//   2. Skew        — put skew over time (steepening = growing fear premium)
//   3. GEX / P/C   — net GEX over time + put/call OI ratio
//
// Shows a "building data" state when < 5 snapshots exist, with a progress
// indicator showing how many chain opens are needed to reach full IVR.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class IvHistoryChart extends StatefulWidget {
  final List<IvSnapshot> history;
  final String ticker;
  const IvHistoryChart({
    super.key,
    required this.history,
    required this.ticker,
  });

  @override
  State<IvHistoryChart> createState() => _IvHistoryChartState();
}

class _IvHistoryChartState extends State<IvHistoryChart>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;

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
                  'IV HISTORY',
                  style: TextStyle(
                    color:      AppTheme.neutralColor,
                    fontSize:   11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                _DataProgress(count: history.length),
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
              Tab(text: 'IV LEVEL'),
              Tab(text: 'SKEW'),
              Tab(text: 'GEX / P/C'),
            ],
          ),

          const Divider(height: 1, color: AppTheme.borderColor),

          // ── Content ────────────────────────────────────────────────────
          SizedBox(
            height: 260,
            child: history.length < 2
                ? _EmptyState(count: history.length)
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _IvLevelTab(history: history),
                      _SkewTab(history: history),
                      _GexPcTab(history: history),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Data progress indicator ───────────────────────────────────────────────────

class _DataProgress extends StatelessWidget {
  final int count;
  const _DataProgress({required this.count});

  @override
  Widget build(BuildContext context) {
    const target = 10; // min for IVR
    const full   = 252;

    if (count >= full) {
      return _chip('Full 52w', AppTheme.profitColor);
    }
    if (count >= target) {
      final pct = (count / full * 100).round();
      return _chip('$count days ($pct%)', const Color(0xFF60A5FA));
    }
    return _chip('$count/${10}d — building', const Color(0xFFFBBF24));
  }

  static Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(5),
      border:       Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(label,
        style: TextStyle(color: color, fontSize: 10,
            fontWeight: FontWeight.w600)),
  );
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final int count;
  const _EmptyState({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.show_chart_rounded,
              size: 36,
              color: AppTheme.neutralColor.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            count == 0
                ? 'No history yet'
                : '$count snapshot${count == 1 ? '' : 's'} collected',
            style: const TextStyle(
                color: Colors.white, fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Every time you open this ticker\'s options chain,\n'
            'a snapshot is saved automatically.\n'
            'Check back after a few more sessions.',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value:            (count / 10).clamp(0.0, 1.0),
            backgroundColor:  AppTheme.borderColor,
            valueColor:       const AlwaysStoppedAnimation(Color(0xFFFBBF24)),
            minHeight:        4,
          ),
          const SizedBox(height: 6),
          Text('$count/10 snapshots to unlock IVR',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10)),
        ],
      ),
    );
  }
}

// ── Tab 1: IV Level ───────────────────────────────────────────────────────────

class _IvLevelTab extends StatelessWidget {
  final List<IvSnapshot> history;
  const _IvLevelTab({required this.history});

  @override
  Widget build(BuildContext context) {
    final ivs    = history.map((s) => s.atmIv).toList();
    final maxIv  = ivs.reduce((a, b) => a > b ? a : b);
    final minIv  = ivs.reduce((a, b) => a < b ? a : b);
    final latest = ivs.last;

    // IVR for latest
    final range = maxIv - minIv;
    final ivr   = range < 0.001 ? 50.0 : ((latest - minIv) / range * 100);

    final spots = List.generate(history.length, (i) =>
        FlSpot(i.toDouble(), history[i].atmIv));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
      child: Column(
        children: [
          // IV line chart
          Expanded(
            child: LineChart(LineChartData(
              minY: (minIv - 5).clamp(0, double.infinity),
              maxY: maxIv + 5,
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
                    showTitles:   true,
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
                    showTitles:   true,
                    reservedSize: 22,
                    interval:     (history.length / 4).ceilToDouble().clamp(1, double.infinity),
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= history.length) return const SizedBox.shrink();
                      final d = history[i].date;
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
              // 52w high / low reference lines
              extraLinesData: ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y: maxIv,
                  color: AppTheme.lossColor.withValues(alpha: 0.5),
                  strokeWidth: 1,
                  dashArray: [4, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    labelResolver: (_) => 'Hi ${maxIv.toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: AppTheme.lossColor, fontSize: 9),
                  ),
                ),
                HorizontalLine(
                  y: minIv,
                  color: AppTheme.profitColor.withValues(alpha: 0.5),
                  strokeWidth: 1,
                  dashArray: [4, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.bottomRight,
                    labelResolver: (_) => 'Lo ${minIv.toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: AppTheme.profitColor, fontSize: 9),
                  ),
                ),
              ]),
              lineBarsData: [
                LineChartBarData(
                  spots:        spots,
                  isCurved:     true,
                  color:        _ivrColor(ivr),
                  barWidth:     2,
                  dotData:      const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show:  true,
                    color: _ivrColor(ivr).withValues(alpha: 0.08),
                  ),
                ),
              ],
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.elevatedColor,
                  getTooltipItems: (spots) => spots.map((s) {
                    final i = s.x.toInt().clamp(0, history.length - 1);
                    final d = history[i].date;
                    return LineTooltipItem(
                      '${d.month}/${d.day}: ${s.y.toStringAsFixed(1)}% IV',
                      const TextStyle(color: Colors.white, fontSize: 11),
                    );
                  }).toList(),
                ),
              ),
            )),
          ),

          const SizedBox(height: 8),

          // IVR bar
          Row(
            children: [
              const Text('IVR', style: TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10,
                  fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value:            (ivr / 100).clamp(0.0, 1.0),
                    backgroundColor:  AppTheme.borderColor,
                    valueColor:       AlwaysStoppedAnimation(_ivrColor(ivr)),
                    minHeight:        8,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${ivr.toStringAsFixed(0)}%',
                  style: TextStyle(
                      color: _ivrColor(ivr), fontSize: 11,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }

  Color _ivrColor(double ivr) {
    if (ivr >= 80) return AppTheme.lossColor;
    if (ivr >= 50) return const Color(0xFFFBBF24);
    if (ivr >= 25) return const Color(0xFF60A5FA);
    return AppTheme.profitColor;
  }
}

// ── Tab 2: Skew history ───────────────────────────────────────────────────────

class _SkewTab extends StatelessWidget {
  final List<IvSnapshot> history;
  const _SkewTab({required this.history});

  @override
  Widget build(BuildContext context) {
    final withSkew = history.where((s) => s.skew != null).toList();

    if (withSkew.length < 2) {
      return const Center(
        child: Text('Skew data will appear after more chain loads',
            style: TextStyle(color: AppTheme.neutralColor)),
      );
    }

    final skews  = withSkew.map((s) => s.skew!).toList();
    final maxSkew = skews.reduce((a, b) => a > b ? a : b);
    final minSkew = skews.reduce((a, b) => a < b ? a : b);
    final avg     = skews.reduce((a, b) => a + b) / skews.length;

    final spots = List.generate(withSkew.length, (i) =>
        FlSpot(i.toDouble(), withSkew[i].skew!));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
      child: Column(
        children: [
          Expanded(
            child: LineChart(LineChartData(
              minY: minSkew - 2,
              maxY: maxSkew + 2,
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
                    showTitles:   true,
                    reservedSize: 32,
                    getTitlesWidget: (v, _) => Text(
                      '${v.toStringAsFixed(0)}pp',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 9),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles:   true,
                    reservedSize: 22,
                    interval:     (withSkew.length / 4).ceilToDouble().clamp(1, double.infinity),
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= withSkew.length) return const SizedBox.shrink();
                      final d = withSkew[i].date;
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${d.month}/${d.day}',
                            style: const TextStyle(
                                color: AppTheme.neutralColor, fontSize: 9)),
                      );
                    },
                  ),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              // Average skew reference line
              extraLinesData: ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y:           avg,
                  color:       Colors.white.withValues(alpha: 0.25),
                  strokeWidth: 1,
                  dashArray:   [4, 4],
                  label: HorizontalLineLabel(
                    show:      true,
                    alignment: Alignment.topRight,
                    labelResolver: (_) => 'avg ${avg.toStringAsFixed(1)}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 9),
                  ),
                ),
              ]),
              lineBarsData: [
                LineChartBarData(
                  spots:        spots,
                  isCurved:     true,
                  color:        AppTheme.lossColor,
                  barWidth:     2,
                  dotData:      const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show:  true,
                    color: AppTheme.lossColor.withValues(alpha: 0.08),
                  ),
                ),
              ],
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.elevatedColor,
                  getTooltipItems: (spots) => spots.map((s) {
                    final i = s.x.toInt().clamp(0, withSkew.length - 1);
                    final d = withSkew[i].date;
                    return LineTooltipItem(
                      '${d.month}/${d.day}: ${s.y.toStringAsFixed(1)}pp skew',
                      const TextStyle(color: Colors.white, fontSize: 11),
                    );
                  }).toList(),
                ),
              ),
            )),
          ),
          const SizedBox(height: 6),
          Text(
            'Put skew in percentage points — rising line = growing fear premium',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Tab 3: GEX / Put-Call ratio ───────────────────────────────────────────────

class _GexPcTab extends StatelessWidget {
  final List<IvSnapshot> history;
  const _GexPcTab({required this.history});

  @override
  Widget build(BuildContext context) {
    final withGex = history.where((s) => s.totalGex != null).toList();
    final withPcr = history.where((s) => s.putCallRatio != null).toList();

    if (withGex.length < 2) {
      return const Center(
        child: Text('GEX history will appear after more chain loads',
            style: TextStyle(color: AppTheme.neutralColor)),
      );
    }

    final gexVals = withGex.map((s) => s.totalGex!).toList();
    final maxAbs  = gexVals.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
    final gexSpots = List.generate(withGex.length, (i) =>
        FlSpot(i.toDouble(), withGex[i].totalGex!));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
      child: Column(
        children: [
          // GEX line chart
          Expanded(
            flex: 3,
            child: LineChart(LineChartData(
              minY: -maxAbs * 1.1,
              maxY:  maxAbs * 1.1,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                checkToShowHorizontalLine: (v) => v == 0,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.white.withValues(alpha: 0.25),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles:   true,
                    reservedSize: 42,
                    getTitlesWidget: (v, _) {
                      final abs = v.abs();
                      final fmt = abs >= 1000
                          ? '${(v / 1000).toStringAsFixed(1)}B'
                          : '${v.toStringAsFixed(0)}M';
                      return Text(fmt,
                          style: const TextStyle(
                              color: AppTheme.neutralColor, fontSize: 8));
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles:   true,
                    reservedSize: 22,
                    interval:     (withGex.length / 4).ceilToDouble().clamp(1, double.infinity),
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= withGex.length) return const SizedBox.shrink();
                      final d = withGex[i].date;
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${d.month}/${d.day}',
                            style: const TextStyle(
                                color: AppTheme.neutralColor, fontSize: 9)),
                      );
                    },
                  ),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots:    gexSpots,
                  isCurved: true,
                  barWidth: 2,
                  dotData:  const FlDotData(show: false),
                  // Colour each segment positive/negative
                  color: const Color(0xFF60A5FA),
                  belowBarData: BarAreaData(
                    show: true,
                    cutOffY: 0,
                    applyCutOffY: true,
                    color: AppTheme.lossColor.withValues(alpha: 0.12),
                  ),
                  aboveBarData: BarAreaData(
                    show: true,
                    cutOffY: 0,
                    applyCutOffY: true,
                    color: AppTheme.profitColor.withValues(alpha: 0.12),
                  ),
                ),
              ],
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.elevatedColor,
                  getTooltipItems: (spots) => spots.map((s) {
                    final i = s.x.toInt().clamp(0, withGex.length - 1);
                    final d = withGex[i].date;
                    final v = s.y;
                    final fmt = v.abs() >= 1000
                        ? '\$${(v / 1000).toStringAsFixed(1)}B'
                        : '\$${v.toStringAsFixed(0)}M';
                    return LineTooltipItem(
                      '${d.month}/${d.day}: $fmt GEX',
                      const TextStyle(color: Colors.white, fontSize: 11),
                    );
                  }).toList(),
                ),
              ),
            )),
          ),

          // P/C ratio sparkline (compact)
          if (withPcr.length >= 2) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('P/C OI',
                    style: TextStyle(color: AppTheme.neutralColor,
                        fontSize: 10, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: _PcrSparkline(history: withPcr),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  withPcr.last.putCallRatio!.toStringAsFixed(2),
                  style: TextStyle(
                    color:      withPcr.last.putCallRatio! > 1.2
                        ? AppTheme.lossColor
                        : withPcr.last.putCallRatio! < 0.8
                            ? AppTheme.profitColor
                            : AppTheme.neutralColor,
                    fontSize:   12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend(AppTheme.profitColor,  '+GEX (stable)'),
              const SizedBox(width: 16),
              _legend(AppTheme.lossColor,    '−GEX (amplified)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(Color color, String label) => Row(
    children: [
      Container(width: 12, height: 3,
          decoration: BoxDecoration(color: color,
              borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(
          color: AppTheme.neutralColor, fontSize: 10)),
    ],
  );
}

// ── P/C sparkline ─────────────────────────────────────────────────────────────

class _PcrSparkline extends StatelessWidget {
  final List<IvSnapshot> history;
  const _PcrSparkline({required this.history});

  @override
  Widget build(BuildContext context) {
    final spots = List.generate(history.length, (i) =>
        FlSpot(i.toDouble(), history[i].putCallRatio!));
    final vals  = history.map((s) => s.putCallRatio!).toList();
    final min   = vals.reduce((a, b) => a < b ? a : b);
    final max   = vals.reduce((a, b) => a > b ? a : b);

    return LineChart(LineChartData(
      minY: (min - 0.1).clamp(0, double.infinity),
      maxY: max + 0.1,
      gridData:   const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: const FlTitlesData(
        leftTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:  AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles:    AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      lineBarsData: [
        LineChartBarData(
          spots:    spots,
          isCurved: true,
          color:    const Color(0xFFFBBF24),
          barWidth: 1.5,
          dotData:  const FlDotData(show: false),
        ),
      ],
      lineTouchData: const LineTouchData(enabled: false),
    ));
  }
}
