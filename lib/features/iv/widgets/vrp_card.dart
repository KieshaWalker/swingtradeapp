// =============================================================================
// features/iv/widgets/vrp_card.dart
// =============================================================================
// Volatility Risk Premium — implied vol vs realized vol, the single most
// important number for deciding whether to BUY or SELL premium:
//
//   VRP = ATM IV (~30d) − 21-day realized vol     (vol points)
//
// IV Rank says "expensive vs its own history"; VRP says "expensive vs what
// the stock actually moves". Selling premium with a negative VRP means
// selling insurance for less than the expected claims.
//
// RV is computed by the Python backend (expected_move_pull job) and read
// from realized_vol_snapshots — never computed in Flutter.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';
import '../../../services/iv/realized_vol_providers.dart';
import '../../../core/widgets/chart/chart_card.dart';

class VrpCard extends ConsumerWidget {
  final String symbol;
  final IvAnalysis analysis;
  const VrpCard({super.key, required this.symbol, required this.analysis});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rvAsync = ref.watch(realizedVolProvider(symbol));

    return rvAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rv) {
        final rv21 = rv?.rv21d;
        if (rv21 == null || rv21 <= 0 || analysis.currentIv <= 0) {
          return const SizedBox.shrink();
        }

        final ivPct  = analysis.currentIv;   // percent (e.g. 28.5)
        final rvPct  = rv21 * 100;           // decimal → percent
        final spread = ivPct - rvPct;        // vol points
        final ratio  = ivPct / rvPct;

        // Bottom spacing lives here so the whole block (card + gap) collapses
        // when RV data is unavailable.
        return Column(children: [
          AnalyticsCard(
          title: 'VOLATILITY RISK PREMIUM',
          actions: [_VrpBadge(ratio: ratio)],
          children: [
            const SizedBox(height: 4),
            const Text(
              'Implied vol vs what the stock actually moves — the edge in premium selling',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChartStatChip(
                  label: 'IV (~30d ATM)',
                  value: '${ivPct.toStringAsFixed(1)}%',
                  dotColor: ChartPalette.indigo,
                ),
                ChartStatChip(
                  label: 'RV (21d)',
                  value: '${rvPct.toStringAsFixed(1)}%',
                  dotColor: ChartPalette.green,
                ),
                ChartStatChip(
                  label: 'VRP',
                  value:
                      '${spread >= 0 ? '+' : ''}${spread.toStringAsFixed(1)}pp',
                ),
                ChartStatChip(
                  label: 'IV/RV',
                  value: '${ratio.toStringAsFixed(2)}×',
                ),
                if (rv?.rv21dPct != null)
                  ChartStatChip(
                    label: 'RV percentile',
                    value: '${rv!.rv21dPct!.toStringAsFixed(0)}th',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _interpretation(spread, ratio),
              style:
                  const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
          ],
          ),
          const SizedBox(height: 16),
        ]);
      },
    );
  }

  String _interpretation(double spread, double ratio) {
    if (ratio >= 1.3) {
      return 'IV is pricing ${spread.toStringAsFixed(1)} vol points more movement '
          'than the stock has delivered (${ratio.toStringAsFixed(2)}× realized). '
          'Premium sellers are being paid well above realized claims — credit '
          'spreads, iron condors and covered calls have statistical edge here, '
          'provided no known catalyst explains the gap (check earnings dates and '
          'the term structure for event premium).';
    }
    if (ratio >= 1.05) {
      return 'IV carries a normal premium over realized vol '
          '(+${spread.toStringAsFixed(1)}pp). This is the typical state — options '
          'are mildly overpriced as insurance usually is. No strong edge either '
          'way from VRP alone; lean on IV Rank and regime signals.';
    }
    if (ratio >= 0.9) {
      return 'IV is roughly at realized vol (${ratio.toStringAsFixed(2)}×). '
          'Premium selling has no statistical cushion — short-vol positions are '
          'betting realized vol falls from here. Long premium is fairly priced.';
    }
    return 'WARNING: IV is BELOW realized vol (${spread.toStringAsFixed(1)}pp). '
        'The stock is moving more than options are pricing — selling premium '
        'here is selling insurance below expected claims. Long options, debit '
        'spreads and straddles are statistically cheap; short-vol structures '
        'should be avoided or hedged.';
  }
}

class _VrpBadge extends StatelessWidget {
  final double ratio;
  const _VrpBadge({required this.ratio});

  @override
  Widget build(BuildContext context) {
    final (color, label) = ratio >= 1.3
        ? (AppTheme.profitColor, 'RICH PREMIUM')
        : ratio >= 1.05
            ? (const Color(0xFF60A5FA), 'NORMAL')
            : ratio >= 0.9
                ? (const Color(0xFFFBBF24), 'THIN')
                : (AppTheme.lossColor, 'IV < RV');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
