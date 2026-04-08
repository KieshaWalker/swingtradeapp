// =============================================================================
// features/iv/widgets/iv_rank_gauge.dart
// =============================================================================
// Shows IV Rank (IVR) and IV Percentile (IVP) with a colour-coded arc gauge,
// a rating badge, and a "cheap vs expensive" interpretation label.
// =============================================================================
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class IvRankGauge extends StatelessWidget {
  final IvAnalysis analysis;
  const IvRankGauge({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text(
                'IV RANK',
                style: TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              _RatingBadge(rating: analysis.rating),
            ],
          ),
          const SizedBox(height: 16),

          // Arc gauge + center text
          Center(
            child: SizedBox(
              width:  180,
              height: 100,
              child: CustomPaint(
                painter: _ArcGaugePainter(
                  ivr:   analysis.ivRank,
                  ivp:   analysis.ivPercentile,
                  color: _ratingColor(analysis.rating),
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        analysis.ivRankLabel,
                        style: TextStyle(
                          color:      _ratingColor(analysis.rating),
                          fontSize:   28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Text(
                        'IV Rank',
                        style: TextStyle(
                          color:    AppTheme.neutralColor,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // IVR / IVP / current IV row
          Row(
            children: [
              _statCell('Current IV', '${analysis.currentIv.toStringAsFixed(1)}%'),
              _statCell('IVP', analysis.ivPercentileLabel),
              _statCell('52w High', analysis.iv52wHigh != null
                  ? '${analysis.iv52wHigh!.toStringAsFixed(1)}%' : '—'),
              _statCell('52w Low', analysis.iv52wLow != null
                  ? '${analysis.iv52wLow!.toStringAsFixed(1)}%' : '—'),
            ],
          ),

          if (analysis.historyDays < 10) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color:        const Color(0xFFFBBF24).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border:       Border.all(
                    color: const Color(0xFFFBBF24).withValues(alpha: 0.4)),
              ),
              child: Text(
                '${analysis.historyDays} days of data — IVR/IVP available after 10',
                style: const TextStyle(
                    color: Color(0xFFFBBF24), fontSize: 11),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              analysis.rating.description,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statCell(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        Text(label,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 10)),
      ],
    ),
  );

  Color _ratingColor(IvRating r) => switch (r) {
    IvRating.extreme   => AppTheme.lossColor,
    IvRating.expensive => const Color(0xFFFBBF24),
    IvRating.fair      => const Color(0xFF60A5FA),
    IvRating.cheap     => AppTheme.profitColor,
    IvRating.noData    => AppTheme.neutralColor,
  };
}

// ── Rating badge ──────────────────────────────────────────────────────────────

class _RatingBadge extends StatelessWidget {
  final IvRating rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    final color = switch (rating) {
      IvRating.extreme   => AppTheme.lossColor,
      IvRating.expensive => const Color(0xFFFBBF24),
      IvRating.fair      => const Color(0xFF60A5FA),
      IvRating.cheap     => AppTheme.profitColor,
      IvRating.noData    => AppTheme.neutralColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        rating.label.toUpperCase(),
        style: TextStyle(
          color:      color,
          fontSize:   11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ── Arc gauge painter ─────────────────────────────────────────────────────────

class _ArcGaugePainter extends CustomPainter {
  final double? ivr;
  final double? ivp;
  final Color color;

  _ArcGaugePainter({required this.ivr, required this.ivp, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx   = size.width / 2;
    final cy   = size.height - 10;
    final r    = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Background arc
    final bgPaint = Paint()
      ..color       = AppTheme.borderColor.withValues(alpha: 0.4)
      ..strokeWidth = 12
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, bgPaint);

    // IVR fill arc
    if (ivr != null) {
      final sweep = (ivr! / 100).clamp(0.0, 1.0) * math.pi;
      final fgPaint = Paint()
        ..color       = color
        ..strokeWidth = 12
        ..style       = PaintingStyle.stroke
        ..strokeCap   = StrokeCap.round;
      canvas.drawArc(rect, math.pi, sweep, false, fgPaint);
    }

    // IVP tick mark (secondary indicator)
    if (ivp != null) {
      final angle = math.pi + (ivp! / 100).clamp(0.0, 1.0) * math.pi;
      final x1 = cx + (r - 18) * math.cos(angle);
      final y1 = cy + (r - 18) * math.sin(angle);
      final x2 = cx + (r + 2)  * math.cos(angle);
      final y2 = cy + (r + 2)  * math.sin(angle);
      canvas.drawLine(
        Offset(x1, y1),
        Offset(x2, y2),
        Paint()
          ..color       = Colors.white.withValues(alpha: 0.6)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      old.ivr != ivr || old.ivp != ivp || old.color != color;
}
