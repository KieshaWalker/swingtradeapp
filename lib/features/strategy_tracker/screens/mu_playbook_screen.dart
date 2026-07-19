// features/economy/widgets/playbook_tab.dart — Playbook tab
//
// The composite MU strategy (backtests/mu_composite.py) as a living page:
// pre-registered rules, backtest results so far, and a live position card
// wired to data already flowing daily — the credit filter reads
// crisis_checklist_snapshots.hyg_ief_20d_pct, MU's current price reads the
// user's own iv_snapshots. Guidelines are fixed text (pre-registration means
// they do not move with the market); results update only when the backtest
// is re-run and this file's constants are refreshed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../economy/widgets/crisis_ledger_tab.dart' show crisisChecklistProvider;

// ─── Pre-registered live trade (entered by the rules, 2026-07-02) ─────────

const _entryDate = '2026-07-02';
const _entryPrice = 975.56;
const _plannedExit = '2026-07-30'; // entry + 20 trading sessions
const _creditRedThreshold = -1.0; // HYG/IEF 20d %

/// MU's latest marked price from the user's own iv_snapshots (authed read).
final muLivePriceProvider = FutureProvider<double?>((ref) async {
  if (Supabase.instance.client.auth.currentUser == null) return null;
  final rows = await Supabase.instance.client
      .from('iv_snapshots')
      .select('underlying_price,date')
      .eq('ticker', 'MU')
      .order('date', ascending: false)
      .limit(1);
  if ((rows as List).isEmpty) return null;
  final v = rows.first['underlying_price'];
  return v == null ? null : (v as num).toDouble();
});

class MuPlaybookScreen extends ConsumerWidget {
  const MuPlaybookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final crisis = ref.watch(crisisChecklistProvider).valueOrNull;
    final hygIef20d =
        crisis?.isNotEmpty == true ? crisis!.first.hygIef20dPct : null;
    final muPrice = ref.watch(muLivePriceProvider).valueOrNull;

    final creditGreen =
        hygIef20d == null ? null : hygIef20d >= _creditRedThreshold;
    final pnl = muPrice == null ? null : (muPrice / _entryPrice - 1) * 100;

    return Scaffold(
      appBar: AppBar(title: const Text('MU Composite Playbook')),
      body: RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(crisisChecklistProvider);
        ref.invalidate(muLivePriceProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Live position ────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text('Live position — MU composite',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('LONG',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    _kv(theme, 'Entered', '$_entryDate @ \$$_entryPrice (dip rule: ≥15% below 252d high, credit green)'),
                    _kv(theme, 'Latest snapshot',
                        muPrice == null
                            ? '— (no MU iv_snapshot visible)'
                            : '\$${muPrice.toStringAsFixed(2)}  (${pnl! >= 0 ? "+" : ""}${pnl.toStringAsFixed(1)}% on shares · ATM Aug-7 call ≈ -55%)'),
                    _kv(theme, 'Planned exit', '$_plannedExit (20-session hold)'),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Credit filter now:  ',
                          style: theme.textTheme.bodySmall),
                      Expanded(
                        child: Text(
                          creditGreen == null
                              ? '—'
                              : creditGreen
                                  ? 'GREEN (HYG/IEF ${hygIef20d!.toStringAsFixed(2)}% /20d)'
                                  : 'RED (HYG/IEF ${hygIef20d!.toStringAsFixed(2)}% /20d) — invalidation state',
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: creditGreen == false
                                  ? theme.colorScheme.error
                                  : const Color(0xFF2E7D52)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      'Invalidation: HYG/IEF 20d falling through '
                      '${_creditRedThreshold.toStringAsFixed(1)}% — the state that '
                      'front-ran the Apr-2025 and Jun-2026 breaks. This card reads '
                      'it live from the daily crisis snapshot.',
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55)),
                    ),
                  ]),
            ),
          ),
          const SizedBox(height: 16),

          // ── Exact mechanics — nothing here requires interpretation ────
          _section(theme, 'Exact triggers (evaluated once daily, at the close)'),
          _rule(theme, 'LONG entry — fires when BOTH are true at a close',
              '(a) MU close ≤ 85% of its highest close over the prior 252 '
              'sessions.  (b) crisis snapshot hyg_ief_20d_pct ≥ -1.0. '
              'Action: enter at that close. Exit: at the close of the 20th '
              'session after entry — no discretion, no stop, no target.'),
          _rule(theme, 'LONG early exit — the only override',
              'If an MU report date falls inside the holding window AND MU '
              'closed the print day ≥ +10% above its close 21 sessions '
              'earlier ("hot"): exit at the print-day close instead. If not '
              'hot: hold through the print.'),
          _rule(theme, 'SHORT entry — fires only on a report date',
              'If MU is hot into the print (same +10%/21-session test): '
              'enter short at the print-day close. Exit at the close of the '
              '5th session after. Not hot: no trade.'),
          _rule(theme, 'Credit veto scope',
              'The HYG/IEF filter blocks NEW entries only. It does not force '
              'exits — an open position rides its clock even if credit turns '
              'red mid-hold.'),
          _rule(theme, 'Sequencing',
              'One position at a time. After any exit, evaluation resumes '
              'the next session. Non-overlapping by construction.'),
          const SizedBox(height: 16),
          _section(theme, 'Backtest implementation (fixed, committed)'),
          _rule(theme, 'Method',
              'Data: split-adjusted daily closes, 2025-01-02 → 2026-07-16 '
              '(384 sessions), MU + HYG + IEF, file data/backtest_2025_2026.csv. '
              'Returns: close-to-close on the underlying, no slippage, no '
              'costs. Script: backtests/mu_composite.py (committed a99bafb) — '
              'rerunnable, deterministic, thresholds hard-coded above. The '
              'options layer replays covered trades on our own '
              'vol_surface_snapshots at recorded ask (entry) and bid (exit).'),
          _rule(theme, 'Audit (2026-07-17) — measures behind the findings',
              '• Execution robustness: delaying every entry one full session '
              'IMPROVED results (+34.9% vs +32.6% avg) — no same-close '
              'look-ahead dependence.\n'
              '• Sensitivity: every cell of the D∈[12,20] × credit∈[-0.5,-1.5] '
              'grid is positive (+14.7% to +34.4%) — the edge is a plateau, '
              'not a tuned point.\n'
              '• Max adverse excursion: two of four closed longs never traded '
              'below entry; worst intra-trade drawdown -15.8% (recovered to '
              '+26.1%). Current open trade\'s -12.5% is inside that envelope.\n'
              '• Closed-trade avg is +32.6%; including the open trade, +23.6% '
              '— the results table includes the open trade.\n'
              '• Monte Carlo, 10,000 draws of random non-overlapping 20d '
              'holds: strategy beats 88% of them (p≈0.12). NOT significant at '
              'conventional thresholds — the regime was so strong that random '
              'entries averaged +20.2%. Suggestive edge, unproven skill: '
              'n=4 closed trades cannot separate the two. This line stays '
              'until the sample says otherwise.\n'
              '• First 2025 entry used a 76-session high (window still '
              'warming up), not a full 252.'),
          const SizedBox(height: 16),
          // ── Guidelines ───────────────────────────────────────────────
          _section(theme, 'The rules — why each exists (pre-registered 2026-07-17)'),
          _rule(theme, '1 · Dip entry',
              'Go long MU when it closes ≥15% below its trailing 252-day high — '
              'AND the credit filter is green. Hold 20 trading sessions, '
              'non-overlapping.'),
          _rule(theme, '2 · Credit filter',
              'Green when HYG/IEF 20-day change ≥ -1.0%. Red = credit '
              'deteriorating: no new entries. Historically red front-ran the '
              'only two real crashes and otherwise produced losing put trades — '
              'it is a veto, not a trade signal.'),
          _rule(theme, '3 · Earnings overlay',
              'MU "hot" into a print (≥ +10% over the prior 21 sessions) → '
              'exit longs at the print-day close; the post-print fade took the '
              'entire run-up back in Mar-2026 and Jun-2026. "Cold" into a '
              'print → hold through (Dec-2025: cold print ripped +14.6%).'),
          _rule(theme, '4 · Fade short',
              'Hot into a print → short at the print-day close, hold 5 '
              'sessions. Fired 4 times, 3 winners, no disasters; correctly '
              'stood aside at the cold Dec-2025 print.'),
          _rule(theme, '5 · What this is NOT',
              'Not a system for down-cycles: every result below comes from one '
              'secular bull regime (MU +877% over the window). Buy-and-hold '
              'beat every variant on total return; the composite trades ~half '
              'the time with a worst outcome of -13% vs MU\'s own -41% '
              'drawdown. The edge claimed is shape, not magnitude.'),
          const SizedBox(height: 16),

          // ── Results so far ───────────────────────────────────────────
          _section(theme, 'Results so far (Jan-2025 → Jul-2026, 384 sessions)'),
          _resultsTable(theme),
          const SizedBox(height: 10),
          _section(theme, 'Trade log — full composite (D)'),
          for (final t in _trades)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(
                    width: 46,
                    child: Text(t.$1,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontWeight: FontWeight.w700))),
                Expanded(
                    child: Text('${t.$2} → ${t.$3}',
                        style: theme.textTheme.bodySmall)),
                Text(t.$4,
                    style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: t.$4.startsWith('-')
                            ? theme.colorScheme.error
                            : const Color(0xFF2E7D52))),
              ]),
            ),
          const SizedBox(height: 16),
          _section(theme, 'Options reality — replayed on OUR vol-surface data'),
          _rule(theme, 'Real fills, real spreads',
              'For trades inside our own chain-capture window (since '
              '2026-04-14), option returns use OUR recorded asks and bids:\n\n'
              '• #7 long 5/18: 680C bought \$88.20 ask at 90% IV → deep ITM by '
              'exit, conservative floor +286% (underlying: +49.8%). Winners '
              'explode.\n'
              '• #8 fade short 6/24: ATM put bought \$82.50 ask at 129% IV — '
              'direction was RIGHT (underlying +1.5%) and the option still '
              'lost 61% to IV crush, theta, and 3.7pp of spread. Never buy '
              'event-priced volatility for a fade.\n'
              '• #9 open 7/2: 975C bought \$130.55 ask at 99% IV — shares '
              '-12.5%, the call ≈ -55%. Premium converts a drawdown into a '
              'near-wipeout.\n'),
          _rule(theme, '6 · Instrument gate (added from the above)',
              'Before expressing any signal in long options, check MU IV '
              'percentile (iv_snapshots). Elevated IV (as at all three 2026 '
              'entries: 90-129%) → prefer shares, deep-ITM low-extrinsic '
              'calls, or spreads. Buying ATM premium at high IV made a '
              'correct system nearly untradeable in option form.'),
          const SizedBox(height: 12),
          Text(
            'Direction-scored on the underlying: real option implementations '
            'pay theta and spread on top (2026 MU straddles ran ~20% of spot '
            'per earnings cycle). 9 trades, one regime, thresholds chosen '
            'in-sample. Source: backtests/mu_composite.py — rerun it after '
            'adding data; update these constants only from its output.',
            style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 100,
              child: Text(k,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6)))),
          Expanded(child: Text(v, style: theme.textTheme.bodySmall)),
        ]),
      );

  Widget _section(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2, fontWeight: FontWeight.w600)),
      );

  Widget _rule(ThemeData theme, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(body, style: theme.textTheme.bodySmall),
        ]),
      );

  Widget _resultsTable(ThemeData theme) {
    const rows = [
      ('Buy & hold', '—', '+877%', '—', '-41% DD'),
      ('A · dip only', '8', '+258%', '75%', '-13.3%'),
      ('B · + credit filter', '5', '+167%', '80%', '-12.5%'),
      ('D · full composite', '9', '+266%', '78%', '-12.5%'),
    ];
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(
                flex: 3,
                child: Text(r.$1,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600))),
            Expanded(child: Text(r.$2, style: theme.textTheme.bodySmall)),
            Expanded(
                flex: 2, child: Text(r.$3, style: theme.textTheme.bodySmall)),
            Expanded(child: Text(r.$4, style: theme.textTheme.bodySmall)),
            Expanded(
                flex: 2, child: Text(r.$5, style: theme.textTheme.bodySmall)),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          Expanded(
              child: Text('variant · trades · total · hit · worst',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.45)))),
        ]),
      ),
    ]);
  }
}

// (side, entry, exit, return) — from backtests/mu_composite.py variant D
const _trades = <(String, String, String, String)>[
  ('LONG', '2025-04-24', '2025-05-22', '+22.5%'),
  ('SHORT', '2025-06-25', '2025-07-02', '+4.3%'),
  ('SHORT', '2025-09-23', '2025-09-30', '-0.5%'),
  ('LONG', '2025-11-20', '2025-12-19', '+32.1%'),
  ('SHORT', '2026-03-18', '2026-03-25', '+17.2%'),
  ('LONG', '2026-03-26', '2026-04-24', '+39.7%'),
  ('LONG', '2026-05-18', '2026-06-16', '+49.8%'),
  ('SHORT', '2026-06-24', '2026-07-01', '+1.5%'),
  ('LONG', '2026-07-02', 'open', '-12.5%*'),
];
