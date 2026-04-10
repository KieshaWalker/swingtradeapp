// =============================================================================
// vol_surface/widgets/vol_heatmap.dart
// CustomPainter heatmap: X = strike, Y = DTE, color = IV
// =============================================================================
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/vol_surface_models.dart';

class VolHeatmap extends StatefulWidget {
  final List<VolPoint> points;
  final double? spotPrice;
  final String ivMode;

  const VolHeatmap({
    super.key,
    required this.points,
    this.spotPrice,
    required this.ivMode,
  });

  @override
  State<VolHeatmap> createState() => _VolHeatmapState();
}

class _VolHeatmapState extends State<VolHeatmap> {
  _GridData? _grid;
  _HitCell? _hit;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(VolHeatmap old) {
    super.didUpdateWidget(old);
    if (old.points != widget.points ||
        old.ivMode != widget.ivMode ||
        old.spotPrice != widget.spotPrice) {
      _rebuild();
    }
  }

  void _rebuild() {
    _grid = _GridData.build(widget.points, widget.spotPrice, widget.ivMode);
    _hit = null;
  }

  void _onTap(Offset pos, Size size) {
    final g = _grid;
    if (g == null || g.strikes.isEmpty || g.dtes.isEmpty) return;
    const lm = _HeatmapPainter.leftMargin;
    const bm = _HeatmapPainter.bottomMargin;
    const tm = _HeatmapPainter.topMargin;
    const rm = _HeatmapPainter.rightMargin;
    const legendW = _HeatmapPainter.legendWidth;
    final plotW = size.width - lm - rm - legendW;
    final plotH = size.height - tm - bm;
    final cw = plotW / g.strikes.length;
    final ch = plotH / g.dtes.length;

    final xi = ((pos.dx - lm) / cw).floor();
    final yi = ((pos.dy - tm) / ch).floor();

    if (xi < 0 || xi >= g.strikes.length || yi < 0 || yi >= g.dtes.length) {
      setState(() => _hit = null);
      return;
    }
    final iv = g.grid[yi][xi];
    setState(() => _hit = _HitCell(
          strike: g.strikes[xi],
          dte: g.dtes[yi],
          iv: iv,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final g = _grid;
    if (g == null || g.strikes.isEmpty) {
      return const Center(
          child: Text('No data', style: TextStyle(color: Colors.white38)));
    }

    return Stack(
      children: [
        GestureDetector(
          onTapDown: (d) => _onTap(d.localPosition, context.size ?? Size.zero),
          onTapUp: (_) => setState(() => _hit = null),
          child: LayoutBuilder(
            builder: (_, constraints) => CustomPaint(
              size: constraints.biggest,
              painter: _HeatmapPainter(grid: g, spotPrice: widget.spotPrice),
            ),
          ),
        ),
        if (_hit != null)
          Positioned(
            top: 8,
            right: _HeatmapPainter.legendWidth + 12,
            child: _Tooltip(hit: _hit!),
          ),
      ],
    );
  }
}

// ── Grid data ──────────────────────────────────────────────────────────────────
class _HitCell {
  final double strike;
  final int dte;
  final double? iv;
  const _HitCell({required this.strike, required this.dte, this.iv});
}

class _GridData {
  final List<double> strikes;
  final List<int> dtes;
  final List<List<double?>> grid; // grid[dteIdx][strikeIdx]
  final double minIv;
  final double maxIv;

  const _GridData({
    required this.strikes,
    required this.dtes,
    required this.grid,
    required this.minIv,
    required this.maxIv,
  });

  static _GridData build(List<VolPoint> points, double? spot, String mode) {
    final strikes = points.map((p) => p.strike).toSet().toList()..sort();
    final dtes = points.map((p) => p.dte).toSet().toList()..sort();

    final strikeIdx = {for (var i = 0; i < strikes.length; i++) strikes[i]: i};
    final dteIdx = {for (var i = 0; i < dtes.length; i++) dtes[i]: i};

    final grid = List.generate(
        dtes.length, (_) => List<double?>.filled(strikes.length, null));

    double minIv = double.infinity;
    double maxIv = double.negativeInfinity;

    for (final p in points) {
      final iv = p.iv(mode, spot);
      if (iv == null) continue;
      final di = dteIdx[p.dte]!;
      final si = strikeIdx[p.strike]!;
      grid[di][si] = iv;
      if (iv < minIv) minIv = iv;
      if (iv > maxIv) maxIv = iv;
    }

    return _GridData(
      strikes: strikes,
      dtes: dtes,
      grid: grid,
      minIv: minIv.isFinite ? minIv : 0,
      maxIv: maxIv.isFinite ? maxIv : 1,
    );
  }
}

// ── Painter ────────────────────────────────────────────────────────────────────
class _HeatmapPainter extends CustomPainter {
  final _GridData grid;
  final double? spotPrice;

  static const leftMargin = 52.0;
  static const bottomMargin = 44.0;
  static const topMargin = 12.0;
  static const rightMargin = 8.0;
  static const legendWidth = 56.0;

  const _HeatmapPainter({required this.grid, this.spotPrice});

  @override
  void paint(Canvas canvas, Size size) {
    if (grid.strikes.isEmpty || grid.dtes.isEmpty) return;

    final plotW = size.width - leftMargin - rightMargin - legendWidth;
    final plotH = size.height - topMargin - bottomMargin;
    final cw = plotW / grid.strikes.length;
    final ch = plotH / grid.dtes.length;

    final textStyle = const TextStyle(
        color: Color(0xFFa09fc8), fontSize: 10, fontFamily: 'monospace');
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);

    // ── Cells ──
    for (var di = 0; di < grid.dtes.length; di++) {
      for (var si = 0; si < grid.strikes.length; si++) {
        final iv = grid.grid[di][si];
        final rect = Rect.fromLTWH(
          leftMargin + si * cw,
          topMargin + di * ch,
          cw,
          ch,
        );
        final color = iv != null
            ? _ivColor(iv, grid.minIv, grid.maxIv)
            : const Color(0xFF1e1e2e);
        canvas.drawRect(rect, Paint()..color = color);
      }
    }

    // ── Spot price vertical line ──
    if (spotPrice != null &&
        spotPrice! >= grid.strikes.first &&
        spotPrice! <= grid.strikes.last) {
      final t = (spotPrice! - grid.strikes.first) /
          (grid.strikes.last - grid.strikes.first);
      final x = leftMargin + t * plotW;
      canvas.drawLine(
        Offset(x, topMargin),
        Offset(x, topMargin + plotH),
        Paint()
          ..color = const Color(0xFFfbbf24)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── Y axis labels (DTEs) ──
    final strideDte = max(1, (grid.dtes.length / 12).ceil());
    for (var di = 0; di < grid.dtes.length; di++) {
      if (di % strideDte != 0 && di != grid.dtes.length - 1) continue;
      final y = topMargin + (di + 0.5) * ch;
      labelPainter
        ..text = TextSpan(text: '${grid.dtes[di]}', style: textStyle)
        ..layout();
      labelPainter.paint(
        canvas,
        Offset(leftMargin - labelPainter.width - 4, y - labelPainter.height / 2),
      );
    }

    // ── X axis labels (strikes) — every Nth to avoid crowding ──
    final strideStrike = max(1, (grid.strikes.length / 10).ceil());
    for (var si = 0; si < grid.strikes.length; si++) {
      if (si % strideStrike != 0) continue;
      final x = leftMargin + (si + 0.5) * cw;
      final label = _fmtStrike(grid.strikes[si]);
      labelPainter
        ..text = TextSpan(text: label, style: textStyle)
        ..layout();
      canvas.save();
      canvas.translate(x, topMargin + plotH + 4);
      canvas.rotate(-pi / 4);
      labelPainter.paint(canvas, Offset(-labelPainter.width, 0));
      canvas.restore();
    }

    // ── Axis titles ──
    final axisTitleStyle = const TextStyle(
        color: Color(0xFF6b7280), fontSize: 9, fontFamily: 'monospace');
    labelPainter
      ..text = TextSpan(text: 'DTE', style: axisTitleStyle)
      ..layout();
    canvas.save();
    canvas.translate(10, topMargin + plotH / 2 + labelPainter.width / 2);
    canvas.rotate(-pi / 2);
    labelPainter.paint(canvas, Offset.zero);
    canvas.restore();

    labelPainter
      ..text = TextSpan(text: 'Strike', style: axisTitleStyle)
      ..layout();
    labelPainter.paint(
      canvas,
      Offset(leftMargin + plotW / 2 - labelPainter.width / 2,
          size.height - 12),
    );

    // ── Color legend ──
    _drawLegend(canvas, size, plotH);
  }

  void _drawLegend(Canvas canvas, Size size, double plotH) {
    final lx2 = size.width - legendWidth + 8;
    final ly = topMargin;
    final lh = plotH;
    const lw = 14.0;

    final rect = Rect.fromLTWH(lx2, ly, lw, lh);
    final gradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        _ivColor(grid.minIv, grid.minIv, grid.maxIv),
        _ivColor((grid.minIv + grid.maxIv) / 2, grid.minIv, grid.maxIv),
        _ivColor(grid.maxIv, grid.minIv, grid.maxIv),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xFF374151)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5);

    final labelStyle = const TextStyle(
        color: Color(0xFFa09fc8), fontSize: 9, fontFamily: 'monospace');
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);

    for (final frac in [0.0, 0.5, 1.0]) {
      final iv = grid.minIv + frac * (grid.maxIv - grid.minIv);
      final label = '${(iv * 100).toStringAsFixed(0)}%';
      final y = ly + lh * (1 - frac);
      labelPainter
        ..text = TextSpan(text: label, style: labelStyle)
        ..layout();
      labelPainter.paint(canvas, Offset(lx2 + lw + 3, y - labelPainter.height / 2));
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.grid != grid || old.spotPrice != spotPrice;

  static String _fmtStrike(double s) =>
      s == s.truncateToDouble() ? s.toInt().toString() : s.toStringAsFixed(1);

  static Color _ivColor(double iv, double minIv, double maxIv) {
    if (maxIv <= minIv) return const Color(0xFF1d4ed8);
    final t = ((iv - minIv) / (maxIv - minIv)).clamp(0.0, 1.0);
    // Deep blue → cyan → green → yellow → orange → red
    const stops = [
      (0.00, Color(0xFF1e3a8a)),
      (0.20, Color(0xFF0ea5e9)),
      (0.40, Color(0xFF22c55e)),
      (0.60, Color(0xFFeab308)),
      (0.80, Color(0xFFf97316)),
      (1.00, Color(0xFFdc2626)),
    ];
    for (var i = 0; i < stops.length - 1; i++) {
      final (t0, c0) = stops[i];
      final (t1, c1) = stops[i + 1];
      if (t <= t1) {
        final local = (t - t0) / (t1 - t0);
        return Color.lerp(c0, c1, local)!;
      }
    }
    return stops.last.$2;
  }
}

// ── Tooltip overlay ────────────────────────────────────────────────────────────
class _Tooltip extends StatelessWidget {
  final _HitCell hit;
  const _Tooltip({required this.hit});

  @override
  Widget build(BuildContext context) {
    final iv = hit.iv != null ? '${(hit.iv! * 100).toStringAsFixed(2)}%' : 'N/A';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        border: Border.all(color: const Color(0xFF374151)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Strike  \$${hit.strike.toStringAsFixed(hit.strike == hit.strike.truncateToDouble() ? 0 : 2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace')),
          Text('DTE  ${hit.dte}',
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace')),
          Text('IV  $iv',
              style: const TextStyle(color: Color(0xFF4ade80), fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
