// =============================================================================
// features/positions/widgets/leg_opportunity_badge.dart
// =============================================================================
// Calls this session's new POST /watched-contracts/evaluate for a single
// leg -- scores it against its OWN snapshot history (position_leg_snapshots,
// already fetched by legSnapshotsProvider; LegSnapshot.toSupabaseInsert()
// matches the field names the backend expects) and checks proximity to
// system-derived levels (zero-gamma flip, GEX wall) sourced from
// ivAnalysisProvider(ticker) -- already fetched elsewhere in the app, no
// new backend call needed for the levels either.
//
// Needs >=10 days of leg history (IV_MIN_HISTORY_IVR server-side) before it
// returns a real grade; shows "building history" until then rather than a
// fabricated score.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_providers.dart';
import '../../../services/python_api/python_api_client.dart';
import '../providers/positions_provider.dart';

typedef _Key = ({String legId, String ticker});

final legOpportunityProvider =
    FutureProvider.family<Map<String, dynamic>, _Key>((ref, key) async {
  final snapshots = await ref.watch(legSnapshotsProvider(key.legId).future);
  if (snapshots.isEmpty) {
    return {
      'signal': false,
      'reason': 'No snapshot history yet',
      'opportunity': {'insufficient_history': true, 'grade': 'D', 'opportunity_score': 0},
      'nearby_level': null,
    };
  }

  final ivAnalysis = await ref.watch(ivAnalysisProvider(key.ticker).future);

  final levels = <Map<String, dynamic>>[
    if (ivAnalysis.zeroGammaLevel != null)
      {'label': 'Zero Gamma', 'price': ivAnalysis.zeroGammaLevel, 'source': 'system'},
    if (ivAnalysis.maxGexStrike != null)
      {'label': 'GEX Wall', 'price': ivAnalysis.maxGexStrike, 'source': 'system'},
  ];

  return PythonApiClient.watchedContractsEvaluate(
    snapshots: snapshots.map((s) => s.toSupabaseInsert()).toList(),
    underlyingPrice: ivAnalysis.underlyingPrice,
    levels: levels,
  );
});

class LegOpportunityBadge extends ConsumerWidget {
  final String legId;
  final String ticker;
  const LegOpportunityBadge({super.key, required this.legId, required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(legOpportunityProvider((legId: legId, ticker: ticker)));

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          width: 12, height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (result) {
        final opp = result['opportunity'] as Map<String, dynamic>? ?? {};
        final insufficientHistory = opp['insufficient_history'] as bool? ?? true;
        final grade = opp['grade'] as String? ?? 'D';
        final score = (opp['opportunity_score'] as num?)?.toInt() ?? 0;
        final signal = result['signal'] as bool? ?? false;
        final reason = result['reason'] as String? ?? '';

        if (insufficientHistory) {
          final n = (opp['snapshot_count'] as num?)?.toInt() ?? 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.elevatedColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Text(
              'Opportunity score: building history ($n/10 days)',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
            ),
          );
        }

        final Color color = switch (grade) {
          'A' => AppTheme.profitColor,
          'B' => ChartAmber.color,
          'C' => AppTheme.neutralColor,
          _   => AppTheme.lossColor,
        };

        return Tooltip(
          message: reason,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: signal ? 0.7 : 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (signal) Icon(Icons.bolt_rounded, size: 12, color: color),
                if (signal) const SizedBox(width: 3),
                Text(
                  'Grade $grade',
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 5),
                Text(
                  '($score)',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 10, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Small local amber constant — matches the amber used for "warn"-style
// states elsewhere (GexRegimeCard) without pulling in a whole palette
// import for one color.
abstract final class ChartAmber {
  static const color = Color(0xFFFBBF24);
}
