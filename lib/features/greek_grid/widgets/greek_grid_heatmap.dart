// =============================================================================
// features/greek_grid/widgets/greek_grid_heatmap.dart
// =============================================================================
// 5×5 heatmap: columns = StrikeBand (deepItm→deepOtm),
//              rows    = ExpiryBucket (weekly→quarterly).
// Color encodes the selected greek's value, scaled to the surface's
// 5th–95th percentile range.
// Delta uses a diverging palette (blue→white→green centred at 0).
// All other greeks use a sequential low→high palette.
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../core/theme.dart';
import '../models/greek_grid_models.dart';

class GreekGridHeatmap extends StatelessWidget {
  final GreekGridSnapshot?  snapshot;
  final GreekSelector       selected;
  final void Function(StrikeBand, ExpiryBucket)? onCellTap;

  static final _bands   = StrikeBand.values;
  static final _buckets = ExpiryBucket.values;

  const GreekGridHeatmap({
    super.key,
    required this.snapshot,
    required this.selected,
    this.onCellTap,
  });

  @override
  Widget build(BuildContext context) {
    // Pre-compute color scale from all non-null values in the snapshot
    final allValues = snapshot == null
        ? <double>[]
        : _bands
            .expand((b) => _buckets.map((bk) =>
                snapshot!.cell(b, bk)?.greekValue(selected)))
            .whereType<double>()
            .toList()
          ..sort();

    double? lo, hi;
    if (allValues.length >= 4) {
      final p5  = allValues[(allValues.length * 0.05).floor().clamp(0, allValues.length - 1)];
      final p95 = allValues[(allValues.length * 0.95).floor().clamp(0, allValues.length - 1)];
      lo = p5;
      hi = p95;
    } else if (allValues.isNotEmpty) {
      lo = allValues.first;
      hi = allValues.last;
    }

    return Column(
      children: [
        // ── Column headers (strike bands) ──────────────────────────────────
        Row(
          children: [
            const SizedBox(width: 64), // row-label gutter
            ..._bands.map((b) => Expanded(
              child: Center(
                child: Text(b.label,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
            )),
          ],
        ),
        const SizedBox(height: 4),
        // ── Grid rows (expiry buckets) ──────────────────────────────────────
        Expanded(
          child: Column(
            children: _buckets.map((bucket) => Expanded(
              child: Row(
                children: [
                  // Row label
                  SizedBox(
                    width: 64,
                    child: Center(
                      child: Text(bucket.label,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 10)),
                    ),
                  ),
                  // Cells
                  ..._bands.map((band) {
                    final point = snapshot?.cell(band, bucket);
                    final value = point?.greekValue(selected);
                    return Expanded(
                      child: GestureDetector(
                        onTap: point != null
                            ? () => onCellTap?.call(band, bucket)
                            : null,
                        child: _GridCell(
                          value:    value,
                          lo:       lo,
                          hi:       hi,
                          greek:    selected,
                          count:    point?.contractCount,
                          isActive: point != null,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            )).toList(),
          ),
        ),
      ],
    );
  }
}

// ── Single cell ───────────────────────────────────────────────────────────────

class _GridCell extends StatelessWidget {
  final double? value;
  final double? lo;
  final double? hi;
  final GreekSelector greek;
  final int?    count;
  final bool    isActive;

  const _GridCell({
    required this.value,
    required this.lo,
    required this.hi,
    required this.greek,
    required this.count,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final bg = _cellColor();
    final textColor = _textColor(bg);
    final label = _label();

    return Container(
      margin: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        children: [
          Center(
            child: Text(
              label,
              style: TextStyle(
                color:      textColor,
                fontSize:   11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Contract count badge (bottom-right)
          if (count != null && count! > 1)
            Positioned(
              right: 3, bottom: 2,
              child: Text(
                'n=$count',
                style: TextStyle(
                    color: textColor.withValues(alpha: 0.55), fontSize: 8),
              ),
            ),
        ],
      ),
    );
  }

  Color _cellColor() {
    if (!isActive || value == null || lo == null || hi == null) {
      return const Color(0xFF1e1e2e);
    }
    final range = hi! - lo!;
    if (range < 1e-10) return AppTheme.elevatedColor;

    final t = ((value! - lo!) / range).clamp(0.0, 1.0);

    // Delta: diverging palette centred at 0
    if (greek == GreekSelector.delta) {
      final centre = lo! < 0 && hi! > 0
          ? (-lo! / range).clamp(0.0, 1.0)
          : 0.5;
      if (t < centre) {
        // negative delta → blue
        final s = centre > 0 ? (1 - t / centre).clamp(0.0, 1.0) : 0.0;
        return Color.lerp(Colors.white, const Color(0xFF2979FF), s)!;
      } else {
        // positive delta → green
        final s = (1 - centre) > 0
            ? ((t - centre) / (1 - centre)).clamp(0.0, 1.0)
            : 0.0;
        return Color.lerp(Colors.white, AppTheme.profitColor, s)!;
      }
    }

    // Sequential: low=dark-teal → high=amber
    return Color.lerp(
        const Color(0xFF1a4a5a), const Color(0xFFFFAB40), t)!;
  }

  Color _textColor(Color bg) {
    final luminance = bg.computeLuminance();
    return luminance > 0.35 ? Colors.black87 : Colors.white;
  }

  String _label() {
    if (value == null) return '—';
    if (greek == GreekSelector.iv) {
      return '${(value! * 100).toStringAsFixed(0)}%';
    }
    if (greek == GreekSelector.delta) {
      return value!.toStringAsFixed(2);
    }
    if (greek == GreekSelector.theta) {
      return value!.toStringAsFixed(3);
    }
    if (value!.abs() < 0.001) return value!.toStringAsExponential(1);
    return value!.toStringAsFixed(3);
  }
}

// ignore: unused_element
double _log10(double x) => math.log(x) / math.ln10;
