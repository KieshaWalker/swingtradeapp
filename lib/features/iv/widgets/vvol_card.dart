// =============================================================================
// features/iv/widgets/vvol_card.dart
// =============================================================================
// Vol-of-Vol (VVol) summary card — surfaces the SABR ν rank computed by
// vvol_analytics.py. Shows how volatile the IV surface itself is.
//
// High vvolRank → IV surface is wildly shifting → widen strikes, size down vega.
// Low  vvolRank → IV surface is stable → vol-selling conditions are safer.
// =============================================================================
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class VvolCard extends StatelessWidget {
  final IvAnalysis analysis;
  const VvolCard({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final rank = analysis.vvolRank;
    if (rank == null) return const SizedBox.shrink();

    final pct      = analysis.vvolPercentile;
    final rating   = analysis.vvolRating ?? '';
    final trend    = analysis.vvolTrend  ?? 'flat';
    final nu       = analysis.vvolNu;

    final ratingColor = _ratingColor(rating);

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
          // ── Header ───────────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                'VOL-OF-VOL RANK',
                style: TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11,
                  fontWeight: FontWeight.w700, letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              _TrendBadge(trend: trend),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'How volatile the IV surface itself is (SABR ν rank)',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
          const SizedBox(height: 14),

          // ── Gauge bar ─────────────────────────────────────────────────────
          _RankBar(rank: rank, color: ratingColor),
          const SizedBox(height: 14),

          // ── Stat row ──────────────────────────────────────────────────────
          Row(
            children: [
              _Stat(label: 'VVol Rank',  value: '${rank.toStringAsFixed(0)}%',    color: ratingColor),
              const SizedBox(width: 16),
              if (pct != null)
                _Stat(label: 'VVol Pct', value: '${pct.toStringAsFixed(0)}%',  color: AppTheme.neutralColor),
              if (pct != null) const SizedBox(width: 16),
              _Stat(label: 'Rating',     value: _ratingLabel(rating),             color: ratingColor),
              if (nu != null) ...[
                const SizedBox(width: 16),
                _Stat(label: 'ν (nu)',   value: nu.toStringAsFixed(3),            color: AppTheme.neutralColor),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // ── Interpretation ────────────────────────────────────────────────
          _Interpretation(rank: rank, trend: trend),
        ],
      ),
    );
  }

  Color _ratingColor(String rating) => switch (rating) {
    'extreme'  => AppTheme.lossColor,
    'elevated' => const Color(0xFFFBBF24),
    'fair'     => AppTheme.neutralColor,
    _          => AppTheme.profitColor,
  };

  String _ratingLabel(String rating) => switch (rating) {
    'extreme'  => 'Extreme',
    'elevated' => 'Elevated',
    'fair'     => 'Fair',
    'cheap'    => 'Cheap',
    _          => '—',
  };
}

// ── Gauge bar ─────────────────────────────────────────────────────────────────

class _RankBar extends StatelessWidget {
  final double rank;
  final Color  color;
  const _RankBar({required this.rank, required this.color});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth;
      return Stack(
        children: [
          Container(
            height: 6,
            decoration: BoxDecoration(
              color:        AppTheme.borderColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Container(
            height: 6,
            width:  w * (rank / 100).clamp(0.0, 1.0),
            decoration: BoxDecoration(
              color:        color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      );
    });
  }
}

// ── Trend badge ───────────────────────────────────────────────────────────────

class _TrendBadge extends StatelessWidget {
  final String trend;
  const _TrendBadge({required this.trend});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (trend) {
      'rising'  => (Icons.trending_up_rounded,   AppTheme.lossColor),
      'falling' => (Icons.trending_down_rounded,  AppTheme.profitColor),
      _         => (Icons.trending_flat_rounded,  AppTheme.neutralColor),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          trend[0].toUpperCase() + trend.substring(1),
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ── Stat chip ─────────────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _Stat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
    ],
  );
}

// ── Plain-English interpretation ──────────────────────────────────────────────

class _Interpretation extends StatelessWidget {
  final double rank;
  final String trend;
  const _Interpretation({required this.rank, required this.trend});

  @override
  Widget build(BuildContext context) {
    final text = _interpret(rank, trend);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:        AppTheme.borderColor.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11, height: 1.45),
      ),
    );
  }

  String _interpret(double rank, String trend) {
    if (rank >= 80) {
      return 'Vol-of-vol is in the top 20% of its range — the IV surface is extremely '
          'unstable. Vega positions are high-risk: use tighter strikes, smaller size, '
          'or avoid selling premium until ν calms.';
    }
    if (rank >= 50) {
      return 'Vol-of-vol elevated. IV moves are larger than average — '
          'expect wider bid/ask spreads and faster IV shifts around catalysts. '
          'Size down on vega or use spreads over naked premium.';
    }
    if (rank >= 25) {
      return 'Vol-of-vol near fair value. IV surface is moving at a normal pace. '
          'Standard position sizing applies.';
    }
    return 'Vol-of-vol compressed — the IV surface is unusually stable. '
        'Good conditions for premium selling: vol moves are small and predictable.';
  }
}
