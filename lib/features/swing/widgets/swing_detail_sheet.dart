// =============================================================================
// features/swing/widgets/swing_detail_sheet.dart
// =============================================================================
// Full breakdown for one setup, opened from a row on the Swing Setups screen.
//
// Presents the four legs SEPARATELY rather than as a combined verdict. The
// legs disagree often, and that disagreement is the useful part — a clean
// channel whose target the option market cannot reach inside a quarter is a
// different situation from one it can, and collapsing both into a single score
// would hide exactly the distinction worth acting on.
//
// Every value renders '—' when null. See the model header for why null, false
// and a value are three different states here.
// =============================================================================
import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../models/swing_setup.dart';

class SwingDetailSheet extends StatelessWidget {
  final SwingSetup setup;
  const SwingDetailSheet({super.key, required this.setup});

  @override
  Widget build(BuildContext context) {
    final s = setup;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(bottom: 14),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(children: [
            Text(s.ticker,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            if (s.spot != null)
              Text(s.spot!.toStringAsFixed(2),
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 16)),
            const Spacer(),
            if (s.structureQuality != null)
              _Pill(
                label: 'structure ${s.structureQuality!.toStringAsFixed(2)}',
                color: AppTheme.profitColor,
              ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Structure quality ranks how legible the chart is. It is not a '
            'direction: channel position alone showed no reliable directional '
            'edge on this universe.',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),

          _section('Channel'),
          if (!s.channelFound)
            _note('No channel fitted — ${s.channelReason ?? "unknown"}. '
                'This is a normal outcome; most charts are not in a channel.')
          else ...[
            _row('Kind', '${s.channelKind} / ${s.channelDirection}'),
            _row('Upper', s.channelUpper?.toStringAsFixed(2)),
            _row('Lower', s.channelLower?.toStringAsFixed(2)),
            _row('Width', s.channelWidthPct == null
                ? null
                : '${s.channelWidthPct!.toStringAsFixed(1)}% of spot'),
            _row('Position', s.channelPosition?.toStringAsFixed(2),
                hint: '0 = lower boundary, 1 = upper'),
            _row('Confidence', s.channelConfidence?.toStringAsFixed(2)),
            _row('Target up', s.targetUp?.toStringAsFixed(2),
                hint: 'measured move: channel height projected from the break'),
            _row('Target down', s.targetDown?.toStringAsFixed(2)),
            if (s.upperLine != null)
              _row('Touches',
                  '${s.upperLine!.touches} upper / ${s.lowerLine?.touches ?? 0} lower'),
            if (s.channelStartIdx != null)
              _note('Boundaries are only valid from bar ${s.channelStartIdx} '
                  'onward — they were never tested before their first anchor.'),
          ],

          _section('Trend'),
          _row('50 SMA', s.sma50?.toStringAsFixed(2)),
          _row('200 SMA', s.sma200?.toStringAsFixed(2),
              hint: s.sma200 == null ? 'under 200 bars of history' : null),
          _row('Price vs 50', _pct(s.pctToSma50)),
          _row('Price vs 200', _pct(s.pctToSma200)),
          _row('50 above 200',
              s.sma50Above200 == null ? null : (s.sma50Above200! ? 'yes' : 'no'),
              hint: s.sma50Above200 == null ? 'cannot tell — not enough history' : null),

          _section('Volume'),
          _row('Session vs 30d median',
              s.volRatio == null ? null : '${s.volRatio!.toStringAsFixed(2)}x',
              hint: 'surge threshold 1.79x (measured p90)'),
          _row('Log z-score', s.volZ?.toStringAsFixed(2)),
          _row('Surge', s.volSurge == null ? null : (s.volSurge! ? 'yes' : 'no')),
          _row('Participation', s.participation,
              hint: '30d vs 50d average — a sustained regime, not one day'),

          _section('Options confirmation'),
          _row('Expected move',
              s.emPct == null ? null : '${s.emPct!.toStringAsFixed(1)}% @ ${s.emDte}d'),
          _row('Target / EM', s.emRatioUp?.toStringAsFixed(2),
              hint: 'magnitude only — never a threshold, it exceeds 1 for '
                  'essentially every channel'),
          _row('Implied days to target',
              s.impliedDaysUp == null ? null : '${s.impliedDaysUp!.toStringAsFixed(0)}d',
              hint: 'the DTE this thesis needs: the horizon at which the '
                  "market's own vol makes the target a 1σ move"),
          _row('Reachable in 90d',
              s.reachableUp == null ? null : (s.reachableUp! ? 'yes' : 'no'),
              hint: s.reachableUp == null
                  ? 'target beyond the credible horizon'
                  : null),
          _row('Gamma regime', s.gammaRegime),
          _row('Zero gamma', s.zeroGammaLevel?.toStringAsFixed(2)),
          _row('Dealer posture', s.dealerPosture,
              hint: s.dealerPosture == 'dampening'
                  ? 'dealers hedge against the move — ranges tend to hold'
                  : s.dealerPosture == 'amplifying'
                      ? 'dealers hedge with the move — breakouts tend to extend'
                      : null),
        ],
      ),
    );
  }

  static String? _pct(double? v) =>
      v == null ? null : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0)),
      );

  Widget _row(String label, String? value, {String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 12)),
                ),
                Text(value ?? '—',
                    style: TextStyle(
                        color: value == null ? AppTheme.neutralColor : Colors.white,
                        fontSize: 13,
                        fontWeight:
                            value == null ? FontWeight.w400 : FontWeight.w600)),
              ],
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(hint,
                    style: TextStyle(
                        color: AppTheme.neutralColor.withValues(alpha: 0.75),
                        fontSize: 10,
                        fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11, height: 1.4)),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}
