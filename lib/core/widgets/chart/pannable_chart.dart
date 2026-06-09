// =============================================================================
// widgets/chart/pannable_chart.dart
// =============================================================================
// Reusable pan / zoom interaction layer for index-based fl_chart line charts.
//
// Wraps a chart `builder` that receives the current visible x-window
// (minX..maxX) and rebuilds as the user navigates. Handles:
//   • drag / scroll-wheel panning
//   • pinch / ctrl+scroll zooming (focal-point anchored)
//   • double-tap reset
//   • optional on-chart zoom buttons (used in full-screen views)
//   • eats vertical drags so an enclosing ListView doesn't scroll while panning
//
// Extracted from RealizedVolChart so every time-series chart can opt into the
// same interaction by wrapping its LineChart in one widget.
// =============================================================================

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';

/// Builds the chart for the current visible window. The builder must feed
/// [minX]/[maxX] into its `LineChartData` so panning/zooming takes effect.
typedef PannableChartBuilder = Widget Function(
  BuildContext context,
  double minX,
  double maxX,
);

class PannableChart extends StatefulWidget {
  /// Number of discrete x-positions (data is plotted at indices 0..count-1).
  final int count;

  /// Points visible by default (initial window width).
  final double defaultWindow;

  /// Smallest window width allowed when zoomed all the way in.
  final double minWindow;

  /// Width reserved for the chart's left axis labels. Excluded from the
  /// plotting area so focal-point zoom math lines up with the data.
  final double leftAxisWidth;

  /// Outer padding around the chart.
  final EdgeInsets padding;

  /// Show the +/−/reset button cluster (top-right). Used in full-screen views.
  final bool showZoomButtons;

  /// Show a draggable horizontal scrollbar below the chart indicating the
  /// visible window's position within the full data range.
  final bool showScrollbar;

  final PannableChartBuilder builder;

  const PannableChart({
    super.key,
    required this.count,
    required this.builder,
    this.defaultWindow = 15,
    this.minWindow = 10,
    this.leftAxisWidth = 40,
    this.padding = const EdgeInsets.fromLTRB(4, 12, 12, 8),
    this.showZoomButtons = false,
    this.showScrollbar = true,
  });

  @override
  State<PannableChart> createState() => _PannableChartState();
}

class _PannableChartState extends State<PannableChart> {
  late double _minX;
  late double _maxX;
  double _contentWidth = 300;

  // Scale-gesture anchors, captured at gesture start.
  double _minXAtScaleStart = 0;
  double _maxXAtScaleStart = 0;
  Offset _focalAtScaleStart = Offset.zero;

  double get _maxIndex => (widget.count - 1).toDouble();

  @override
  void initState() {
    super.initState();
    _initWindow();
  }

  @override
  void didUpdateWidget(PannableChart old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count) _initWindow();
  }

  void _initWindow() {
    _maxX = _maxIndex;
    _minX = (_maxX - widget.defaultWindow + 1).clamp(0.0, _maxX);
  }

  void _setWindow(double newMin, double newWindow) {
    setState(() {
      _minX = newMin;
      _maxX = newMin + newWindow;
    });
  }

  /// Zoom by [factor] (<1 zooms in, >1 zooms out), anchored at [focalFrac]
  /// (0..1 across the plotting area; defaults to centre).
  void _zoomBy(double factor, {double? focalFrac}) {
    final window = _maxX - _minX;
    final newWindow = (window * factor).clamp(widget.minWindow, _maxIndex);
    final frac = focalFrac ?? 0.5;
    final focalDataX = _minX + frac * window;
    final newMin =
        (focalDataX - frac * newWindow).clamp(0.0, _maxIndex - newWindow);
    _setWindow(newMin, newWindow);
  }

  void _scroll(double dxPixels) {
    final window = _maxX - _minX;
    if (window <= 0 || _contentWidth <= 0) return;
    final pxPerUnit = _contentWidth / window;
    final newMin = (_minX - dxPixels / pxPerUnit).clamp(0.0, _maxIndex - window);
    if (newMin == _minX) return;
    _setWindow(newMin, window);
  }

  /// Pan from a scrollbar drag: thumb travels in track-space (the full data
  /// range maps to [trackWidth]), so dragging right advances the window.
  void _scrollbarDrag(double dxPixels, double trackWidth) {
    final window = _maxX - _minX;
    if (trackWidth <= 0 || _maxIndex <= 0) return;
    final deltaData = dxPixels / trackWidth * _maxIndex;
    final newMin = (_minX + deltaData).clamp(0.0, _maxIndex - window);
    if (newMin == _minX) return;
    _setWindow(newMin, window);
  }

  double _focalFrac(double localDx) =>
      ((localDx - widget.leftAxisWidth) / _contentWidth).clamp(0.0, 1.0);

  void _onScaleStart(ScaleStartDetails d) {
    _minXAtScaleStart = _minX;
    _maxXAtScaleStart = _maxX;
    _focalAtScaleStart = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount <= 1) {
      _scroll(d.focalPointDelta.dx);
      return;
    }
    final scale = d.scale;
    if (scale <= 0) return;
    final windowAtStart = _maxXAtScaleStart - _minXAtScaleStart;
    final newWindow =
        (windowAtStart / scale).clamp(widget.minWindow, _maxIndex);
    final frac = _focalFrac(_focalAtScaleStart.dx);
    final focalDataX = _minXAtScaleStart + frac * windowAtStart;
    final newMin =
        (focalDataX - frac * newWindow).clamp(0.0, _maxIndex - newWindow);
    _setWindow(newMin, newWindow);
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy;
    final zooming = e.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.isControlPressed;
    if (zooming) {
      // scroll up = zoom in, scroll down = zoom out
      _zoomBy(dy > 0 ? 1.12 : 0.89, focalFrac: _focalFrac(e.localPosition.dx));
    } else {
      _scroll(-dy * 2);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          _contentWidth = (constraints.maxWidth - widget.leftAxisWidth)
              .clamp(1.0, double.infinity);
          final chart = widget.builder(ctx, _minX, _maxX);

          final body = widget.showZoomButtons
              ? Stack(
                  children: [
                    chart,
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _ZoomButtons(
                        onZoomIn: () => _zoomBy(0.7),
                        onZoomOut: () => _zoomBy(1.43),
                        onReset: () => setState(_initWindow),
                      ),
                    ),
                  ],
                )
              : chart;

          // Outer GestureDetector eats vertical drags so a parent ScrollView
          // doesn't scroll the page while the user pans the chart.
          final interactive = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (_) {},
            onVerticalDragEnd: (_) {},
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onDoubleTap: () => setState(_initWindow),
                child: body,
              ),
            ),
          );

          if (!widget.showScrollbar) return interactive;

          return Column(
            children: [
              Expanded(child: interactive),
              const SizedBox(height: 6),
              // Align the track under the plotting area (past the y-axis).
              Padding(
                padding: EdgeInsets.only(left: widget.leftAxisWidth),
                child: _ScrollIndicator(
                  minX: _minX,
                  maxX: _maxX,
                  maxIndex: _maxIndex,
                  onDrag: _scrollbarDrag,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Scrollbar ───────────────────────────────────────────────────────────────

/// Thin draggable indicator of the visible window ([minX]..[maxX]) within the
/// full data range (0..[maxIndex]). Dragging pans the chart.
class _ScrollIndicator extends StatelessWidget {
  final double minX;
  final double maxX;
  final double maxIndex;
  final void Function(double dxPixels, double trackWidth) onDrag;

  const _ScrollIndicator({
    required this.minX,
    required this.maxX,
    required this.maxIndex,
    required this.onDrag,
  });

  static const _height = 12.0;

  @override
  Widget build(BuildContext context) {
    if (maxIndex <= 0) return const SizedBox(height: _height);

    return LayoutBuilder(
      builder: (ctx, c) {
        final trackW = c.maxWidth;
        final leftFrac = (minX / maxIndex).clamp(0.0, 1.0);
        final rightFrac = (maxX / maxIndex).clamp(0.0, 1.0);
        // Keep the thumb grabbable even when zoomed far out/in.
        final thumbW = ((rightFrac - leftFrac) * trackW).clamp(28.0, trackW);
        final maxLeft = (trackW - thumbW).clamp(0.0, trackW);
        final thumbLeft = (leftFrac * trackW).clamp(0.0, maxLeft);
        final fullyVisible = leftFrac <= 0.001 && rightFrac >= 0.999;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx, trackW),
          child: SizedBox(
            height: _height,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Track
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderColor.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Thumb
                Positioned(
                  left: thumbLeft,
                  child: Container(
                    width: thumbW,
                    height: 6,
                    decoration: BoxDecoration(
                      color: AppTheme.profitColor
                          .withValues(alpha: fullyVisible ? 0.25 : 0.7),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Zoom button cluster ─────────────────────────────────────────────────────

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
  Widget build(BuildContext context) => Container(
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

class _ZoomBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const _ZoomBtn({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

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
