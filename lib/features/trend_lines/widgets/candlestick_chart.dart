// =============================================================================
// features/trend_lines/widgets/candlestick_chart.dart
// =============================================================================
// Daily candles for one ticker with saved trend lines overlaid, wrapped in the
// shared PannableChart interaction layer (pan / pinch-zoom / double-tap reset —
// see core/widgets/chart/pannable_chart.dart).
//
// fl_chart (used everywhere else in this app) has no candlestick chart type,
// so this is a plain CustomPainter — the same approach vol_heatmap.dart already
// uses for a chart shape fl_chart doesn't cover.
//
// LEFT-AXIS WIDTH IS A CONTRACT, NOT A CONVENIENCE. PannableChart reserves
// [_kLeftAxisWidth] of pixel-to-data math for panning/zooming and for
// positioning the scrollbar beneath the chart, but it does NOT inset the
// chart it wraps — each chart is responsible for drawing its own left axis
// inside that same width. Using a different value here would desync the
// gesture math from what is actually drawn.
//
// A TREND LINE IS DRAWN ONLY FROM ITS OWN FIRST ANCHOR FORWARD, never
// backward past it. This mirrors services/channel_fit.py's own rule that a
// line "was never tested before its origin" — extending it backward on the
// chart would visually claim a validity the line does not have.
//
// ANCHOR-TO-BAR-INDEX MAPPING IS POSITIONING ONLY, NOT A SECOND ANALYTIC. This
// widget calls TrendLineRecord.nearestBarIndex / .indexSlope for that reason —
// see their doc comments in models/trend_line.dart for why reading a stored
// value back for display is not the same as recomputing it.
//
// ACCURACY IS PASSED IN, NEVER FETCHED HERE. [accuracyByLineId] comes from
// POST /trend-lines/accuracy via trendLineAccuracyProvider, fetched by the
// SCREEN (features/trend_lines/screens/trend_lines_screen.dart) — this widget
// stays a pure renderer of whatever data it is handed, the same separation the
// rest of this feature already keeps between computing and drawing.
//
// A BROKEN LINE IS DRAWN SOLID UP TO ITS VIOLATION, DASHED AFTER. The dashed
// tail is not decoration — it is the same claim services/channel_fit.py makes
// when a candidate line is rejected for being pierced: past that point the
// line no longer describes support or resistance, only where it USED to. A
// manual line (kind == manual) never gets this treatment even if broken=false
// happens to be computed, because track_line_accuracy assigns it no status at
// all — see models/trend_line.dart's TrendLineAccuracy.status doc.
// =============================================================================
import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/chart/chart_card.dart';
import '../../../core/widgets/chart/pannable_chart.dart';
import '../models/equity_bar.dart';
import '../models/trend_line.dart';

const double _kLeftAxisWidth = 52.0;
const double _kTopPad = 10.0;
const double _kBottomPad = 20.0;

class CandlestickChart extends StatelessWidget {
  final List<EquityBar> bars;
  final List<TrendLineRecord> lines;
  /// Keyed by TrendLineRecord.id. A missing entry (still loading, or the
  /// screen hasn't fetched it) draws that line as if it were holding — the
  /// same "don't fabricate a verdict" rule as a manual line's null status.
  final Map<String, TrendLineAccuracy> accuracyByLineId;

  const CandlestickChart({
    super.key,
    required this.bars,
    required this.lines,
    this.accuracyByLineId = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return const ChartEmptyState(
        icon: Icons.candlestick_chart_outlined,
        title: 'No bars yet',
        message: 'equity-bars-pull has not populated this ticker yet.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 320,
          child: PannableChart(
            count: bars.length,
            defaultWindow: 60,
            minWindow: 15,
            leftAxisWidth: _kLeftAxisWidth,
            showZoomButtons: true,
            padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
            builder: (context, minX, maxX) => SizedBox.expand(
              child: CustomPaint(
                painter: _CandlestickPainter(
                  bars: bars,
                  lines: lines,
                  accuracyByLineId: accuracyByLineId,
                  minX: minX,
                  maxX: maxX,
                ),
              ),
            ),
          ),
        ),
        if (lines.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ChartLegendRow(items: [
              if (lines.any((l) => l.kind == TrendLineKind.resistance))
                const ChartLegendItem(AppTheme.lossColor, 'Resistance'),
              if (lines.any((l) => l.kind == TrendLineKind.support))
                const ChartLegendItem(AppTheme.profitColor, 'Support'),
              if (lines.any((l) => l.kind == TrendLineKind.manual))
                const ChartLegendItem(AppTheme.neutralColor, 'Manual'),
            ]),
          ),
      ],
    );
  }
}

Color _kindColor(TrendLineKind k) => switch (k) {
      TrendLineKind.resistance => AppTheme.lossColor,
      TrendLineKind.support => AppTheme.profitColor,
      TrendLineKind.manual => AppTheme.neutralColor,
    };

class _CandlestickPainter extends CustomPainter {
  final List<EquityBar> bars;
  final List<TrendLineRecord> lines;
  final Map<String, TrendLineAccuracy> accuracyByLineId;
  final double minX;
  final double maxX;

  _CandlestickPainter({
    required this.bars,
    required this.lines,
    required this.accuracyByLineId,
    required this.minX,
    required this.maxX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plotLeft = _kLeftAxisWidth;
    final plotWidth = (size.width - _kLeftAxisWidth).clamp(1.0, double.infinity);
    final plotTop = _kTopPad;
    final plotHeight =
        (size.height - _kTopPad - _kBottomPad).clamp(1.0, double.infinity);

    final loIdx = minX.floor().clamp(0, bars.length - 1);
    final hiIdx = maxX.ceil().clamp(0, bars.length - 1);

    // Price range from the VISIBLE CANDLES ONLY, so the y-axis rescales as
    // the user pans/zooms rather than being fixed to the whole history's
    // range. Deliberately NOT widened to fit overlaid lines — a line's two
    // anchors can be close together (a manual line is completely unconstrained,
    // unlike an algorithmic fit's _MIN_SPAN_FRAC requirement), and extrapolating
    // a steep short-baseline slope across the rest of the visible window can
    // reach a value many multiples of the actual price range. Letting that
    // value stretch the axis crushes every candle into a sliver at one edge —
    // caught visually in preview: a 4-trading-day-apart pair of anchors,
    // projected across ~100 more bars, compressed 150 real candles into under
    // 10% of the chart height. A real platform's fix is the same as this one:
    // the price axis is the data's, and an out-of-range line simply runs off
    // the top or bottom rather than rescaling everything around it.
    double lo = bars[loIdx].low, hi = bars[loIdx].high;
    for (int i = loIdx; i <= hiIdx; i++) {
      if (bars[i].low < lo) lo = bars[i].low;
      if (bars[i].high > hi) hi = bars[i].high;
    }
    if (hi <= lo) {
      hi = lo + 1; // degenerate flat window guard
    }
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;

    double px(double index) =>
        plotLeft + (index - minX) / (maxX - minX) * plotWidth;
    double py(double price) =>
        plotTop + (hi - price) / (hi - lo) * plotHeight;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(plotLeft, 0, plotWidth, size.height));

    _drawGridAndPriceAxis(canvas, size, lo, hi, py);
    _drawCandles(canvas, loIdx, hiIdx, px, py, plotWidth);

    // Labels are collected here and painted in a SEPARATE pass after every
    // line has been stroked, rather than inline per line. Painting inline
    // meant two lines whose right edges land at similar prices produced two
    // labels stacked at nearly the same y — confirmed in preview, where "My
    // Line" rendered directly on top of "Sept-Nov Resistance · broken" and
    // neither was readable. Collecting first lets _declutterLabels see every
    // label's desired position at once and space out any that would collide.
    final pendingLabels = <_PendingLabel>[];
    for (final line in lines) {
      final label = _drawLine(canvas, size, line, accuracyByLineId[line.id],
          px, py, hiIdx, plotTop, plotHeight);
      if (label != null) pendingLabels.add(label);
    }
    _paintDeclutteredLabels(canvas, pendingLabels);

    canvas.restore();
  }

  void _drawGridAndPriceAxis(
      Canvas canvas, Size size, double lo, double hi, double Function(double) py) {
    const gridLines = 4;
    final gridPaint = Paint()
      ..color = AppTheme.borderColor.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (int i = 0; i <= gridLines; i++) {
      final price = lo + (hi - lo) * i / gridLines;
      final y = py(price);
      canvas.drawLine(
          Offset(_kLeftAxisWidth, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: price.toStringAsFixed(price >= 100 ? 0 : 2),
          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height / 2));
    }
  }

  void _drawCandles(Canvas canvas, int loIdx, int hiIdx,
      double Function(double) px, double Function(double) py, double plotWidth) {
    final visibleCount = (maxX - minX).clamp(1.0, double.infinity);
    final bodyWidth = (plotWidth / visibleCount * 0.62).clamp(1.0, 40.0);

    for (int i = loIdx; i <= hiIdx; i++) {
      final b = bars[i];
      final x = px(i.toDouble());
      final color = b.isUp ? AppTheme.profitColor : AppTheme.lossColor;

      canvas.drawLine(
        Offset(x, py(b.high)),
        Offset(x, py(b.low)),
        Paint()
          ..color = color
          ..strokeWidth = 1,
      );

      final top = py(b.isUp ? b.close : b.open);
      final bottom = py(b.isUp ? b.open : b.close);
      final rect = Rect.fromLTRB(
        x - bodyWidth / 2, top, x + bodyWidth / 2,
        // A doji (open == close) would paint a zero-height rect and vanish;
        // floor it to one pixel so the bar is still visible.
        (bottom - top).abs() < 1 ? top + 1 : bottom,
      );
      canvas.drawRect(rect, Paint()..color = color);
    }
  }

  /// Strokes one line's solid/dashed/marker path and returns its DESIRED
  /// label placement, or null if the line isn't drawn at all (origin or whole
  /// segment out of view). The label itself is painted later by
  /// _paintDeclutteredLabels, once every line's desired position is known.
  _PendingLabel? _drawLine(Canvas canvas, Size size, TrendLineRecord line,
      TrendLineAccuracy? acc,
      double Function(double) px, double Function(double) py, int hiIdx,
      double plotTop, double plotHeight) {
    final i1 = TrendLineRecord.nearestBarIndex(bars, line.anchor1Date);
    if (i1 > hiIdx) return null; // origin is after everything currently visible

    // Drawn from the line's own first anchor forward only — see file header.
    final startX = i1.toDouble().clamp(minX, maxX);
    final endX = maxX.clamp(startX, (bars.length - 1).toDouble());
    if (endX <= startX) return null;

    final slope = line.indexSlope(bars);
    double valueAt(double x) => line.anchor1Price + slope * (x - i1);
    final color = _kindColor(line.kind);

    // acc.status is only ever 'holding'/'broken' for support/resistance —
    // track_line_accuracy leaves it null for a manual line, on purpose (no
    // side is assumed for a hand-drawn line, so no verdict is drawn for one
    // either). A missing map entry (still loading) is treated the same as
    // "no verdict yet", never as "broken".
    double? violationX;
    if (acc?.status == 'broken' && acc!.firstViolationDate != null) {
      violationX = TrendLineRecord.nearestBarIndex(bars, acc.firstViolationDate!)
          .toDouble();
    }

    if (violationX == null || violationX >= endX) {
      // Holding, no verdict yet, or the break lies beyond what is currently
      // visible — the whole visible segment still describes an active line.
      _strokeSegment(canvas, px, py, valueAt, startX, endX, color, dashed: false);
    } else if (violationX <= startX) {
      // Already broken before this visible window begins — nothing here
      // still describes a live line, so the whole segment renders dashed.
      _strokeSegment(canvas, px, py, valueAt, startX, endX, color, dashed: true);
    } else {
      // The break happens inside the visible window: solid up to it, dashed
      // after, and a marker at the exact bar it happened.
      _strokeSegment(canvas, px, py, valueAt, startX, violationX, color, dashed: false);
      _strokeSegment(canvas, px, py, valueAt, violationX, endX, color, dashed: true);
      _drawViolationMarker(canvas, Offset(px(violationX), py(valueAt(violationX))), color);
    }

    // A steep or off-scale line can land its endpoint far outside the plot
    // band (see the axis-range note above — that is now expected, not a bug).
    // The label must not follow it off-canvas, so its y is clamped to the
    // visible band regardless of where the line itself actually is.
    final broken = violationX != null && violationX <= endX;
    final tp = TextPainter(
      text: TextSpan(
        text: broken ? '${line.name} · broken' : line.name,
        style: TextStyle(
            // Faded once broken, matching the dashed tail's reduced claim.
            color: broken ? color.withValues(alpha: 0.6) : color,
            fontSize: 10,
            fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var labelX = px(endX) - tp.width - 2;
    var labelY = (py(valueAt(endX)) - tp.height - 2)
        .clamp(plotTop, plotTop + plotHeight - tp.height);
    // The zoom-button cluster occupies the top-right corner (see
    // PannableChart(showZoomButtons: true)) and paints ABOVE this canvas in
    // the widget stack, so a label placed there would be hidden behind it
    // rather than simply overlapping — push it below that reserved band.
    const buttonZoneWidth = 100.0;
    const buttonZoneHeight = 40.0;
    if (labelX > size.width - buttonZoneWidth && labelY < buttonZoneHeight) {
      labelY = buttonZoneHeight + 4;
    }
    return _PendingLabel(
      tp: tp, x: labelX, y: labelY,
      minY: plotTop, maxY: plotTop + plotHeight - tp.height,
    );
  }

  /// Paints every collected label, pushing any that would overlap another
  /// straight down until there is a clean gap. Sorted top-to-bottom first so
  /// "push down to clear a collision" only ever compounds in one direction —
  /// without the sort, two labels could each try to dodge into the other's
  /// space and still end up overlapping.
  void _paintDeclutteredLabels(Canvas canvas, List<_PendingLabel> labels) {
    if (labels.isEmpty) return;
    labels.sort((a, b) => a.y.compareTo(b.y));

    // Extra breathing room below each label's own measured height, not a
    // flat guessed pixel count. A first attempt at this used a bare 13.0 —
    // confirmed by instrumenting a preview build that it WAS being applied
    // exactly (labels landed exactly 13.0px apart), and they still visually
    // read as fully overlapping: 10pt bold text measures ~13-14px tall on its
    // own, so a 13px gap between two label TOPS left the second one starting
    // before the first had finished. The fix measures against each label's
    // REAL tp.height instead of assuming one.
    const extraGap = 4.0;
    for (int i = 1; i < labels.length; i++) {
      final prev = labels[i - 1];
      final needed = prev.y + prev.tp.height + extraGap;
      if (labels[i].y < needed) {
        // Reclamped to each label's OWN bound, not the previous one's — a
        // label near the plot's bottom edge must not be pushed further down
        // than it can legally go just because it collided with one above it.
        labels[i].y = needed.clamp(labels[i].minY, labels[i].maxY);
      }
    }
    for (final label in labels) {
      label.tp.paint(canvas, Offset(label.x, label.y));
    }
  }

  /// One straight stretch of a trend line, either solid or dashed. Splitting
  /// this out is what lets _drawLine draw a pre-break and post-break portion
  /// with two different strokes without duplicating the coordinate math.
  void _strokeSegment(
      Canvas canvas, double Function(double) px, double Function(double) py,
      double Function(double) valueAt, double fromX, double toX, Color color,
      {required bool dashed}) {
    final p1 = Offset(px(fromX), py(valueAt(fromX)));
    final p2 = Offset(px(toX), py(valueAt(toX)));
    final paint = Paint()
      ..color = dashed ? color.withValues(alpha: 0.55) : color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    if (!dashed) {
      canvas.drawLine(p1, p2, paint);
      return;
    }
    // Canvas has no native dashed stroke — step along the segment drawing
    // short strokes with gaps. Cheap at this scale (at most a few hundred
    // pixels per line).
    const dashLen = 5.0, gapLen = 4.0;
    final total = (p2 - p1).distance;
    if (total <= 0) return;
    final dir = (p2 - p1) / total;
    double drawn = 0;
    while (drawn < total) {
      final segEnd = (drawn + dashLen).clamp(0.0, total);
      canvas.drawLine(p1 + dir * drawn, p1 + dir * segEnd, paint);
      drawn += dashLen + gapLen;
    }
  }

  /// Small ring marking exactly where a line was violated — the bar
  /// track_line_accuracy reports as first_violation_date, mapped back to an
  /// x-position the same way every other anchor on this chart is.
  void _drawViolationMarker(Canvas canvas, Offset at, Color color) {
    canvas.drawCircle(at, 4, Paint()..color = color);
    canvas.drawCircle(
      at, 4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _CandlestickPainter old) =>
      old.minX != minX || old.maxX != maxX ||
      old.bars.length != bars.length || old.lines != lines ||
      // Length, not deep equality: catches the real-world case (an accuracy
      // fetch completing adds an entry) cheaply. Would miss a value flipping
      // in place at the same map size, which only happens on a manual
      // re-fetch of an already-resolved line — accepted, not fixed, since the
      // paint itself is cheap enough that a missed repaint here is at worst a
      // one-frame staleness, not a persistent wrong render.
      old.accuracyByLineId.length != accuracyByLineId.length;
}

/// One line's desired label placement, collected during the stroke pass and
/// spaced apart from its neighbours during _paintDeclutteredLabels. `y` is
/// mutable — decluttering adjusts it in place after every line has proposed
/// its own position.
class _PendingLabel {
  final TextPainter tp;
  final double x;
  double y;
  final double minY;
  final double maxY;

  _PendingLabel({
    required this.tp,
    required this.x,
    required this.y,
    required this.minY,
    required this.maxY,
  });
}
