// =============================================================================
// features/positions/widgets/leg_regime_badge.dart
// =============================================================================
// Small regime-ML badge for a leg's ticker, reusing regimeMlProvider — the
// same provider Current Regime's screen used, and the same lookup pattern
// features/ticker_profile/screens/ticker_profile_screen.dart already uses
// (filter RegimeMlAnalysis.tickers by symbol). No new backend call.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../current_regime/models/regime_ml_models.dart';
import '../../current_regime/providers/regime_ml_provider.dart';

class LegRegimeBadge extends ConsumerWidget {
  final String ticker;
  const LegRegimeBadge({super.key, required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regimeAsync = ref.watch(regimeMlProvider);
    final result = regimeAsync.valueOrNull?.tickers
        .where((r) => r.ticker == ticker)
        .firstOrNull;

    if (result == null) return const SizedBox.shrink();

    final Color color = switch (result.bucket) {
      RegimeBucket.stablePositive || RegimeBucket.trendingPositive =>
        AppTheme.profitColor,
      RegimeBucket.stableNegative || RegimeBucket.trendingNegative =>
        AppTheme.lossColor,
      RegimeBucket.unknown => AppTheme.neutralColor,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.radar_rounded, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            result.bucket.shortLabel,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 5),
          Text(
            'ML ${result.mlScore >= 0 ? '+' : ''}${result.mlScore.toStringAsFixed(2)}',
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 10, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
