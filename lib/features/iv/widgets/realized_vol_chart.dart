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
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
                rvAsync.whenOrNull(
                      data: (snaps) {
                        final ivSnaps = ivAsync.valueOrNull ?? [];
                        final valid = snaps
                            .where((s) =>
                                s.rv1d != null ||
                                s.rv5d != null ||
                                s.rv21d != null)
                            .toList();
                        if (valid.length < 2) return null;
                        return IconButton(
                          icon: const Icon(
                            Icons.fullscreen,
                            size: 18,
                            color: AppTheme.neutralColor,
                          ),
                          padding: const EdgeInsets.only(left: 4),
                          constraints: const BoxConstraints(),
                          tooltip: 'Expand chart',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _RvFullScreenPage(
                                ticker: ticker,
                                rvSnaps: valid,
                                ivSnaps: ivSnaps,
                              ),
                            ),
                          ),
                        );
                      },
                    ) ??
                    const SizedBox.shrink(),
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
  final bool showZoomButtons;
  const _RvChart({
    required this.rvSnaps,
    required this.ivSnaps,
    this.showZoomButtons = false,
  });

  @override
  State<_RvChart> createState() => _RvChartState();
}

class _RvChartState extends State<_RvChart> {
  static const _defaultWindow = 15.0;
  static const _minWindow = 10.0;

  late double _minX;
  late double _maxX;
  double _contentWidth = 300.0;

  // Scale gesture state
  double _minXAtScaleStart = 0.0;
  double _maxXAtScaleStart = 0.0;
  Offset _focalAtScaleStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _initWindow();
  }

  @override
  void didUpdateWidget(_RvChart old) {
    super.didUpdateWidget(old);
    if (old.rvSnaps.length != widget.rvSnaps.length ||
        (old.rvSnaps.isNotEmpty && widget.rvSnaps.isNotEmpty &&
         old.rvSnaps.first.date != widget.rvSnaps.first.date)) {
      _initWindow();
    }
  }

  void _initWindow() {
    final n = widget.rvSnaps.length.toDouble();
    _maxX = n - 1;
    _minX = (_maxX - _defaultWindow + 1).clamp(0.0, _maxX);
  }

  void _zoomIn() {
    final windowSize = _maxX - _minX;
    final maxN = widget.rvSnaps.length.toDouble() - 1;
    final newWindow = (windowSize * 0.7).clamp(_minWindow, maxN);
    final center = (_minX + _maxX) / 2;
    setState(() {
      _minX = (center - newWindow / 2).clamp(0.0, maxN - newWindow);
      _maxX = _minX + newWindow;
    });
  }

  void _zoomOut() {
    final windowSize = _maxX - _minX;
    final maxN = widget.rvSnaps.length.toDouble() - 1;
    final newWindow = (windowSize * 1.43).clamp(_minWindow, maxN);
    final center = (_minX + _maxX) / 2;
    setState(() {
      _minX = (center - newWindow / 2).clamp(0.0, maxN - newWindow);
      _maxX = _minX + newWindow;
    });
  }

  void _scroll(double dxPixels) {
    final windowSize = _maxX - _minX;
    if (windowSize <= 0 || _contentWidth <= 0) return;
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

  void _onScaleStart(ScaleStartDetails details) {
    _minXAtScaleStart = _minX;
    _maxXAtScaleStart = _maxX;
    _focalAtScaleStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount <= 1) {
      _scroll(details.focalPointDelta.dx);
    } else {
      final scale = details.scale;
      if (scale <= 0) return;
      final windowAtStart = _maxXAtScaleStart - _minXAtScaleStart;
      final maxN = widget.rvSnaps.length.toDouble() - 1;
      final newWindow = (windowAtStart / scale).clamp(_minWindow, maxN);

      // y-axis reservedSize(40); outer padding already excluded by LayoutBuilder
      const leftPad = 40.0;
      final focalFrac = ((_focalAtScaleStart.dx - leftPad) / _contentWidth).clamp(0.0, 1.0);
      final focalDataX = _minXAtScaleStart + focalFrac * windowAtStart;
      final newMin = (focalDataX - focalFrac * newWindow).clamp(0.0, maxN - newWindow);
      setState(() {
        _minX = newMin;
        _maxX = newMin + newWindow;
      });
    }
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
    final minY = (allVals.reduce((a, b) => a < b ? a : b) * 0.9).clamp(0.0, double.infinity);
    final maxY = (allVals.reduce((a, b) => a > b ? a : b) * 1.08).ceilToDouble();

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
          // y-axis reservedSize(40); outer padding already excluded by LayoutBuilder
          _contentWidth = (constraints.maxWidth - 40).clamp(
            1.0,
            double.infinity,
          );
          final chart = LineChart(
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

          // Outer GestureDetector consumes vertical drags so the parent
          // ScrollView doesn't scroll the page while the user pans the chart.
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (_) {},
            onVerticalDragEnd: (_) {},
            // Mouse scroll wheel: ctrl+scroll zooms, plain scroll pans
            child: Listener(
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent) return;
                final dy = event.scrollDelta.dy;
                if (event.kind == PointerDeviceKind.mouse &&
                    HardwareKeyboard.instance.isControlPressed) {
                  // Zoom: scroll up = zoom in, scroll down = zoom out
                  final windowSize = _maxX - _minX;
                  final maxN = widget.rvSnaps.length.toDouble() - 1;
                  final zoomFactor = dy > 0 ? 1.12 : 0.89;
                  final newWindow = (windowSize * zoomFactor).clamp(_minWindow, maxN);
                  const leftPad = 40.0;
                  final focalFrac = ((event.localPosition.dx - leftPad) / _contentWidth).clamp(0.0, 1.0);
                  final focalDataX = _minX + focalFrac * windowSize;
                  final newMin = (focalDataX - focalFrac * newWindow).clamp(0.0, maxN - newWindow);
                  setState(() {
                    _minX = newMin;
                    _maxX = newMin + newWindow;
                  });
                } else {
                  // Pan
                  _scroll(-dy * 2);
                }
              },
              child: GestureDetector(
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onDoubleTap: () => setState(_initWindow),
                child: widget.showZoomButtons
                    ? Stack(
                        children: [
                          chart,
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _ZoomButtons(
                              onZoomIn: _zoomIn,
                              onZoomOut: _zoomOut,
                              onReset: () => setState(_initWindow),
                            ),
                          ),
                        ],
                      )
                    : chart,
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

// ── Zoom buttons overlay ──────────────────────────────────────────────────────

class _ZoomButtons extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  const _ZoomButtons({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.add, onTap: onZoomIn, tooltip: 'Zoom in'),
          Container(width: 1, height: 24, color: AppTheme.borderColor),
          _ZoomBtn(icon: Icons.remove, onTap: onZoomOut, tooltip: 'Zoom out'),
          Container(width: 1, height: 24, color: AppTheme.borderColor),
          _ZoomBtn(icon: Icons.fit_screen, onTap: onReset, tooltip: 'Reset'),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const _ZoomBtn({required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Icon(icon, size: 16, color: AppTheme.neutralColor),
      ),
    ),
  );
}

// ── Full-screen page ──────────────────────────────────────────────────────────

class _RvFullScreenPage extends StatelessWidget {
  final String ticker;
  final List<RealizedVolSnapshot> rvSnaps;
  final List<ExpectedMoveSnapshot> ivSnaps;
  const _RvFullScreenPage({
    required this.ticker,
    required this.rvSnaps,
    required this.ivSnaps,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cardColor,
      appBar: AppBar(
        backgroundColor: AppTheme.cardColor,
        title: Text(
          '$ticker — Realized Volatility',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Pinch or use buttons to zoom · Double-tap to reset',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const Divider(height: 1, color: AppTheme.borderColor),
          Expanded(
            child: _RvChart(
              rvSnaps: rvSnaps,
              ivSnaps: ivSnaps,
              showZoomButtons: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
      Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
    ],
  );
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
