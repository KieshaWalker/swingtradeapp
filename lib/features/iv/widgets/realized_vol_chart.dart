// =============================================================================
// features/iv/widgets/realized_vol_chart.dart
// =============================================================================
// Realized volatility time series: rv_1d (daily), rv_5d (weekly), rv_21d
// (monthly) with an IV overlay from expected_move_snapshots so the IV/RV
// spread is visible.
//
// Data sourced entirely from the backend — no client-side computation.
//
// Chrome (card, header, legend, stats) comes from ChartCard; pan / zoom /
// pinch / fullscreen come from PannableChart.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/realized_vol_models.dart';
import '../../../services/iv/realized_vol_providers.dart';
import '../../../services/iv/expected_move_providers.dart';
import '../../../services/iv/expected_move_models.dart';
import '../../../core/widgets/chart/chart_card.dart';
import '../../../core/widgets/chart/pannable_chart.dart';

const _white = ChartPalette.white;
const _yellow = ChartPalette.yellow;
const _green = ChartPalette.green;
const _indigo = ChartPalette.indigo;

const _legend = [
  ChartLegendItem(_white, 'RV 1d', dashed: true),
  ChartLegendItem(_yellow, 'RV 5d'),
  ChartLegendItem(_green, 'RV 21d'),
  ChartLegendItem(_indigo, 'IV'),
];

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

bool _hasAnyRv(RealizedVolSnapshot s) =>
    s.rv1d != null || s.rv5d != null || s.rv21d != null;

class RealizedVolChart extends ConsumerWidget {
  final String ticker;
  const RealizedVolChart({super.key, required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rvAsync = ref.watch(realizedVolHistoryProvider(ticker));
    final ivAsync = ref.watch(expectedMoveMonthlyProvider(ticker));

    final valid =
        rvAsync.valueOrNull?.where(_hasAnyRv).toList() ?? const [];
    final last = valid.isNotEmpty ? valid.last : null;
    final ivSnaps = ivAsync.valueOrNull ?? const [];
    final canExpand = valid.length >= 2;

    return ChartCard(
      title: 'REALIZED VOLATILITY',
      height: 220,
      actions: [
        ChartActionButton(
          icon: Icons.info_outline,
          tooltip: 'About IV vs RV',
          onPressed: () => _showVolNote(context),
        ),
        if (canExpand)
          ChartActionButton(
            icon: Icons.fullscreen,
            tooltip: 'Expand chart',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChartFullScreenScaffold(
                  title: '$ticker — Realized Volatility',
                  legend: _legend,
                  child: _RvPlot(
                    rvSnaps: valid,
                    ivSnaps: ivSnaps,
                    showZoomButtons: true,
                  ),
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
                    label: '1d', value: fmtPct(last.rv1d), dotColor: _white),
                ChartStatChip(
                    label: '5d', value: fmtPct(last.rv5d), dotColor: _yellow),
                ChartStatChip(
                    label: '21d', value: fmtPct(last.rv21d), dotColor: _green),
              ],
            ),
      legend: _legend,
      child: rvAsync.when(
        loading: () => const ChartMessage.loading(),
        error: (_, _) => const ChartMessage.error(),
        data: (rvSnaps) {
          final v = rvSnaps.where(_hasAnyRv).toList();
          if (v.length < 2) return const _EmptyState();
          return _RvPlot(rvSnaps: v, ivSnaps: ivSnaps);
        },
      ),
    );
  }

  static void _showVolNote(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text(
          'Volatility & Options',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _NotePoint(
                number: '1',
                text:
                    'In dollar terms, a volatility change has a greater effect on an at-the-money option than an equivalent in-the-money or out-of-the-money option.',
              ),
              SizedBox(height: 12),
              _NotePoint(
                number: '2',
                text:
                    'In percent terms, a volatility change has a greater effect on an out-of-the-money option than an equivalent in-the-money or at-the-money option.',
              ),
              SizedBox(height: 12),
              _NotePoint(
                number: '3',
                text:
                    'Future realized volatility determines the true value of options on a contract; implied volatility reflects their market price. '
                    'When IV is low relative to expected future RV, prefer buying options. '
                    'When IV is high relative to expected future RV, prefer selling.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

// ── Plot ────────────────────────────────────────────────────────────────────

class _RvPlot extends StatelessWidget {
  final List<RealizedVolSnapshot> rvSnaps;
  final List<ExpectedMoveSnapshot> ivSnaps;
  final bool showZoomButtons;
  const _RvPlot({
    required this.rvSnaps,
    required this.ivSnaps,
    this.showZoomButtons = false,
  });

  @override
  Widget build(BuildContext context) {
    final n = rvSnaps.length;

    final ivByDate = <String, double>{};
    for (final s in ivSnaps) {
      if (s.iv != null) ivByDate[_dateKey(s.date)] = s.iv!;
    }

    List<FlSpot> toSpots(double? Function(RealizedVolSnapshot) fn) =>
        List.generate(n, (i) {
          final v = fn(rvSnaps[i]);
          return v != null ? FlSpot(i.toDouble(), v * 100) : FlSpot.nullSpot;
        });

    final rv1d = toSpots((s) => s.rv1d);
    final rv5d = toSpots((s) => s.rv5d);
    final rv21d = toSpots((s) => s.rv21d);
    final iv = List.generate(n, (i) {
      final val = ivByDate[_dateKey(rvSnaps[i].date)];
      return val != null ? FlSpot(i.toDouble(), val * 100) : FlSpot.nullSpot;
    });

    final allVals = [...rv1d, ...rv5d, ...rv21d, ...iv]
        .where((s) => s != FlSpot.nullSpot)
        .map((s) => s.y)
        .toList();
    if (allVals.isEmpty) return const _EmptyState();
    final minY =
        (allVals.reduce((a, b) => a < b ? a : b) * 0.9).clamp(0.0, double.infinity);
    final maxY = (allVals.reduce((a, b) => a > b ? a : b) * 1.08).ceilToDouble();

    LineChartBarData line(List<FlSpot> spots, Color color, double width,
            {List<int>? dash}) =>
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: color,
          barWidth: width,
          dotData: const FlDotData(show: false),
          dashArray: dash,
          belowBarData: BarAreaData(show: false),
        );

    bool any(List<FlSpot> s) => s.any((p) => p != FlSpot.nullSpot);
    final lineBars = <LineChartBarData>[
      if (any(rv1d)) line(rv1d, _white.withValues(alpha: 0.4), 1, dash: [3, 3]),
      if (any(rv5d)) line(rv5d, _yellow, 1.5),
      if (any(rv21d)) line(rv21d, _green, 2),
      if (any(iv)) line(iv, _indigo, 2),
    ];

    return PannableChart(
      count: n,
      showZoomButtons: showZoomButtons,
      builder: (ctx, minX, maxX) =>
          _chart(minX, maxX, n, lineBars, ivByDate, minY, maxY),
    );
  }

  LineChart _chart(
    double minX,
    double maxX,
    int n,
    List<LineChartBarData> lineBars,
    Map<String, double> ivByDate,
    double minY,
    double maxY,
  ) {
    final interval =
        ((maxX - minX) / 4).ceilToDouble().clamp(1.0, double.infinity);

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
            reservedSize: 40,
            getTitlesWidget: (v, _) => Text(
              '${v.toStringAsFixed(0)}%',
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
              final d = rvSnaps[i].date;
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
      lineBarsData: lineBars,
      lineTouchData: LineTouchData(
        handleBuiltInTouches: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => AppTheme.elevatedColor,
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItems: (spots) {
            final i = spots.first.x.toInt().clamp(0, n - 1);
            final s = rvSnaps[i];
            final ivVal = ivByDate[_dateKey(s.date)];
            return spots.map((ts) {
              if (ts.barIndex != 0) return const LineTooltipItem('', TextStyle());
              return LineTooltipItem(
                '${s.date.month}/${s.date.day}/${s.date.year}\n'
                'RV 1d   ${fmtPct(s.rv1d)}\n'
                'RV 5d   ${fmtPct(s.rv5d)}\n'
                'RV 21d  ${fmtPct(s.rv21d)}\n'
                'IV      ${ivVal != null ? fmtPct(ivVal) : '—'}',
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

// ── Note point ──────────────────────────────────────────────────────────────

class _NotePoint extends StatelessWidget {
  final String number;
  final String text;
  const _NotePoint({required this.number, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(right: 8, top: 1),
            decoration: BoxDecoration(
              color: _indigo.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(color: _indigo.withValues(alpha: 0.5)),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: _indigo,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      );
}

// ── Empty state ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const ChartEmptyState(
        icon: Icons.show_chart_rounded,
        title: 'No data yet',
        message: 'Run the RV backfill job to populate historical data.',
      );
}
