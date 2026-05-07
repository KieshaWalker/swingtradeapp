// =============================================================================
// features/iv/widgets/realized_vol_chart.dart
// =============================================================================
// Realized volatility time series: rv_1d (daily), rv_5d (weekly), rv_21d (monthly)
// with IV overlay from expected_move_snapshots so the IV/RV spread is visible.
//
// Data sourced entirely from backend — no client-side computation.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/realized_vol_models.dart';
import '../../../services/iv/realized_vol_providers.dart';
import '../../../services/iv/expected_move_providers.dart';
import '../../../services/iv/expected_move_models.dart';

const _green = Color(0xFF4ADE80);
const _yellow = Color(0xFFFBBF24);
const _white = Colors.white;
const _indigo = Color(0xFF818CF8);

class RealizedVolChart extends ConsumerWidget {
  final String ticker;
  const RealizedVolChart({super.key, required this.ticker});

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
            children: [
              _NotePoint(
                number: '1',
                text:
                    'In dollar terms, a volatility change has a greater effect on an at-the-money option than an equivalent in-the-money or out-of-the-money option.',
              ),
              const SizedBox(height: 12),
              _NotePoint(
                number: '2',
                text:
                    'In percent terms, a volatility change has a greater effect on an out-of-the-money option than an equivalent in-the-money or at-the-money option.',
              ),
              const SizedBox(height: 12),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rvAsync = ref.watch(realizedVolHistoryProvider(ticker));
    final ivAsync = ref.watch(expectedMoveMonthlyProvider(ticker));

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(
              children: [
                const Text(
                  'REALIZED VOLATILITY',
                  style: TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                rvAsync.whenOrNull(
                      data: (snaps) {
                        final last = snaps.isNotEmpty ? snaps.last : null;
                        if (last == null) return null;
                        return Text(
                          '1d ${_pct(last.rv1d)}  '
                          '5d ${_pct(last.rv5d)}  '
                          '21d ${_pct(last.rv21d)}',
                          style: const TextStyle(
                            color: AppTheme.neutralColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ) ??
                    const SizedBox.shrink(),
                IconButton(
                  icon: const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: AppTheme.neutralColor,
                  ),
                  padding: const EdgeInsets.only(left: 8),
                  constraints: const BoxConstraints(),
                  tooltip: 'About IV vs RV',
                  onPressed: () => _showVolNote(context),
                ),
              ],
            ),
          ),

          const SizedBox(height: 4),
          const Divider(height: 1, color: AppTheme.borderColor),

          // ── Chart ─────────────────────────────────────────────────────
          SizedBox(
            height: 220,
            child: rvAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              error: (e, _) => const Center(
                child: Text(
                  'Error loading data',
                  style: TextStyle(color: AppTheme.neutralColor),
                ),
              ),
              data: (rvSnaps) {
                final valid = rvSnaps
                    .where(
                      (s) =>
                          s.rv1d != null || s.rv5d != null || s.rv21d != null,
                    )
                    .toList();
                if (valid.length < 2) {
                  return const _EmptyState();
                }
                final ivSnaps = ivAsync.valueOrNull ?? [];
                return _RvChart(rvSnaps: valid, ivSnaps: ivSnaps);
              },
            ),
          ),

          // ── Legend ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendItem(_white, 'RV 1d'),
                const SizedBox(width: 14),
                _legendItem(_yellow, 'RV 5d'),
                const SizedBox(width: 14),
                _legendItem(_green, 'RV 21d'),
                const SizedBox(width: 14),
                _legendItem(_indigo, 'IV'),
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
        width: 12,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
      ),
    ],
  );

  String _pct(double? v) =>
      v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';
}

// ── Chart ─────────────────────────────────────────────────────────────────────

class _RvChart extends StatefulWidget {
  final List<RealizedVolSnapshot> rvSnaps;
  final List<ExpectedMoveSnapshot> ivSnaps;
  const _RvChart({required this.rvSnaps, required this.ivSnaps});

  @override
  State<_RvChart> createState() => _RvChartState();
}

class _RvChartState extends State<_RvChart> {
  // ~90 trading days ≈ 4.5 months shown by default
  static const _defaultWindow = 90.0;

  late double _minX;
  late double _maxX;
  double _contentWidth = 300.0;

  @override
  void initState() {
    super.initState();
    _initWindow();
  }

  @override
  void didUpdateWidget(_RvChart old) {
    super.didUpdateWidget(old);
    if (old.rvSnaps.length != widget.rvSnaps.length) _initWindow();
  }

  void _initWindow() {
    final n = widget.rvSnaps.length.toDouble();
    _maxX = n - 1;
    _minX = (_maxX - _defaultWindow + 1).clamp(0.0, _maxX);
  }

  void _scroll(double dxPixels) {
    final windowSize = _maxX - _minX;
    if (windowSize <= 0) return;
    final pxPerUnit = _contentWidth / windowSize;
    final delta = -dxPixels / pxPerUnit;
    final n = widget.rvSnaps.length.toDouble();
    final newMin = (_minX + delta).clamp(0.0, (n - 1) - windowSize);
    if (newMin == _minX) return;
    setState(() {
      _minX = newMin;
      _maxX = newMin + windowSize;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rvSnaps = widget.rvSnaps;
    final ivSnaps = widget.ivSnaps;
    final n = rvSnaps.length;

    final ivByDate = <String, double>{};
    for (final s in ivSnaps) {
      if (s.iv != null) {
        ivByDate['${s.date.year}-${s.date.month.toString().padLeft(2, '0')}-${s.date.day.toString().padLeft(2, '0')}'] =
            s.iv!;
      }
    }

    List<FlSpot> toSpots(double? Function(RealizedVolSnapshot) fn) =>
        List.generate(n, (i) {
          final v = fn(rvSnaps[i]);
          return v != null ? FlSpot(i.toDouble(), v * 100) : FlSpot.nullSpot;
        });

    final rv1dSpots = toSpots((s) => s.rv1d);
    final rv5dSpots = toSpots((s) => s.rv5d);
    final rv21dSpots = toSpots((s) => s.rv21d);

    final ivSpots = List.generate(n, (i) {
      final s = rvSnaps[i];
      final key =
          '${s.date.year}-${s.date.month.toString().padLeft(2, '0')}-${s.date.day.toString().padLeft(2, '0')}';
      final iv = ivByDate[key];
      return iv != null ? FlSpot(i.toDouble(), iv * 100) : FlSpot.nullSpot;
    });

    final allVals = [
      ...rv1dSpots,
      ...rv5dSpots,
      ...rv21dSpots,
      ...ivSpots,
    ].where((s) => s != FlSpot.nullSpot).map((s) => s.y).toList();
    if (allVals.isEmpty) return const _EmptyState();
    final minY = (allVals.reduce((a, b) => a < b ? a : b) * 0.9).clamp(
      0.0,
      double.infinity,
    );
    final maxY = allVals.reduce((a, b) => a > b ? a : b) * 1.1;

    LineChartBarData line(
      List<FlSpot> spots,
      Color color,
      double width, {
      List<int>? dash,
    }) => LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: width,
      dotData: const FlDotData(show: false),
      dashArray: dash,
      belowBarData: BarAreaData(show: false),
    );

    bool hasValidSpot(List<FlSpot> spots) =>
        spots.any((s) => s != FlSpot.nullSpot);
    final lineBars = <LineChartBarData>[
      if (hasValidSpot(rv1dSpots))
        line(rv1dSpots, _white.withValues(alpha: 0.4), 1, dash: [3, 3]),
      if (hasValidSpot(rv5dSpots)) line(rv5dSpots, _yellow, 1.5),
      if (hasValidSpot(rv21dSpots)) line(rv21dSpots, _green, 2),
      if (hasValidSpot(ivSpots)) line(ivSpots, _indigo, 2),
    ];

    final windowSize = _maxX - _minX;
    final interval = (windowSize / 4).ceilToDouble().clamp(
      1.0,
      double.infinity,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 12, 8),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // left padding(4) + y-axis reservedSize(40) + right padding(12)
          _contentWidth = (constraints.maxWidth - 56).clamp(
            1.0,
            double.infinity,
          );
          return LineChart(
            LineChartData(
              minX: _minX,
              maxX: _maxX,
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
                      style: const TextStyle(
                        color: AppTheme.neutralColor,
                        fontSize: 9,
                      ),
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
                          style: const TextStyle(
                            color: AppTheme.neutralColor,
                            fontSize: 9,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
              ), // horizontal scoll and hover

              lineBarsData: lineBars,
              lineTouchData: LineTouchData(
                handleBuiltInTouches: true,
                touchCallback: (event, response) {
                  if (event is FlPanUpdateEvent) {
                    _scroll(event.details.delta.dx);
                  }
                },
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.elevatedColor,
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (spots) {
                    final i = spots.first.x.toInt().clamp(0, n - 1);
                    final s = rvSnaps[i];
                    final ivVal =
                        ivByDate['${s.date.year}-${s.date.month.toString().padLeft(2, '0')}-${s.date.day.toString().padLeft(2, '0')}'];
                    return spots.map((ts) {
                      if (ts.barIndex != 0) {
                        return LineTooltipItem('', const TextStyle());
                      }
                      return LineTooltipItem(
                        '${s.date.month}/${s.date.day}/${s.date.year}\n'
                        'RV 1d   ${_fmtPct(s.rv1d)}\n'
                        'RV 5d   ${_fmtPct(s.rv5d)}\n'
                        'RV 21d  ${_fmtPct(s.rv21d)}\n'
                        'IV       ${ivVal != null ? '${(ivVal * 100).toStringAsFixed(1)}%' : '—'}',
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
            ),
          );
        },
      ),
    );
  }

  String _fmtPct(double? v) =>
      v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';
}

// ── Note point ────────────────────────────────────────────────────────────────

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

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.show_chart_rounded, size: 36, color: Color(0x80808080)),
        SizedBox(height: 12),
        Text(
          'No data yet',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Run the RV backfill job to populate historical data.',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
