// features/economy/widgets/crisis_ledger_tab.dart — Crisis Ledger tab
//
// Renders the daily crisis-signal checklist written by api/jobs/crisis_pull.py
// into crisis_checklist_snapshots: a tally header, "now vs prior bubbles"
// gauges, and the nine scored signals. Historical bubble benchmarks are
// compile-time constants (they never change); live readings come from the
// latest snapshot row. Read-only: all computation happens in the backend job.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─── Model ────────────────────────────────────────────────────────────────

class CrisisSnapshot {
  final DateTime obsDate;
  final double? spyClose, spyOffAthPct;
  final int? spyDaysSinceAth;
  final double? cape, marginDebtBn, marginDebtYoyPct;
  final double? fedFundsPct, fedFunds90dChgBps, t10y2yBps;
  final double? cpiYoyPct, cpiCoreYoyPct;
  final double? hyOasBps, igOasBps, hyOas20dChgBps;
  final double? rspSpyOffHighPct, iwmSpyOffHighPct;
  final double? bdcOffHighPct, bdc20dPct, mgrOffHighPct, mgr20dPct;
  final double? specOffHighPct;
  final Map<String, String> verdicts;
  final int? structuralLit, catalystsFiring;
  final bool isFinal;

  CrisisSnapshot.fromJson(Map<String, dynamic> j)
      : obsDate = DateTime.parse(j['obs_date'] as String),
        spyClose = _d(j['spy_close']),
        spyOffAthPct = _d(j['spy_off_ath_pct']),
        spyDaysSinceAth = j['spy_days_since_ath'] as int?,
        cape = _d(j['cape']),
        marginDebtBn = _d(j['margin_debt_bn']),
        marginDebtYoyPct = _d(j['margin_debt_yoy_pct']),
        fedFundsPct = _d(j['fed_funds_pct']),
        fedFunds90dChgBps = _d(j['fed_funds_90d_chg_bps']),
        t10y2yBps = _d(j['t10y2y_bps']),
        cpiYoyPct = _d(j['cpi_yoy_pct']),
        cpiCoreYoyPct = _d(j['cpi_core_yoy_pct']),
        hyOasBps = _d(j['hy_oas_bps']),
        igOasBps = _d(j['ig_oas_bps']),
        hyOas20dChgBps = _d(j['hy_oas_20d_chg_bps']),
        rspSpyOffHighPct = _d(j['rsp_spy_off_high_pct']),
        iwmSpyOffHighPct = _d(j['iwm_spy_off_high_pct']),
        bdcOffHighPct = _d(j['bdc_off_high_pct']),
        bdc20dPct = _d(j['bdc_20d_pct']),
        mgrOffHighPct = _d(j['mgr_off_high_pct']),
        mgr20dPct = _d(j['mgr_20d_pct']),
        specOffHighPct = _d(j['spec_off_high_pct']),
        verdicts = {
          for (final k in const [
            'v_index_ath', 'v_valuation', 'v_leverage', 'v_spec_tier',
            'v_fed', 'v_curve', 'v_public_credit', 'v_private_credit',
            'v_breadth',
          ])
            k: (j[k] as String?) ?? 'unknown',
        },
        structuralLit = j['structural_lit'] as int?,
        catalystsFiring = j['catalysts_firing'] as int?,
        isFinal = (j['is_final'] as bool?) ?? false;

  static double? _d(dynamic v) => v == null ? null : (v as num).toDouble();
}

final crisisChecklistProvider =
    FutureProvider<List<CrisisSnapshot>>((ref) async {
  // Latest first; well under the PostgREST 1000-row cap.
  final rows = await Supabase.instance.client
      .from('crisis_checklist_snapshots')
      .select()
      .order('obs_date', ascending: false)
      .limit(120);
  return (rows as List)
      .map((r) => CrisisSnapshot.fromJson(r as Map<String, dynamic>))
      .toList();
});

// ─── Historical bubble benchmarks (fixed facts; see Crisis Ledger) ────────

class _BubbleMark {
  final String label;
  final double value;
  const _BubbleMark(this.label, this.value);
}

const _capeMarks = [
  _BubbleMark("'29", 32.6),
  _BubbleMark("'00", 44.2),
  _BubbleMark("'07", 27.3),
  _BubbleMark("'22", 38.6),
];

// HY OAS reference points (bps): Jun-2007 record tights and the ledger alert
// level. Crisis wides (2008: ~2,000; 2020: ~1,100) sit far off this scale.
const _hyMarks = [
  _BubbleMark("'07 tights", 240),
  _BubbleMark('alert', 400),
];

// ─── Tab ──────────────────────────────────────────────────────────────────

class CrisisLedgerTab extends ConsumerWidget {
  const CrisisLedgerTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(crisisChecklistProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(crisisChecklistProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to load crisis checklist: $e'),
          ),
        ]),
        data: (rows) {
          if (rows.isEmpty) {
            return ListView(children: const [
              Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No snapshots yet — run the crisis-pull job once to seed '
                  'crisis_checklist_snapshots.',
                ),
              ),
            ]);
          }
          final s = rows.first;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _TallyCard(s: s),
              const SizedBox(height: 16),
              _SectionHeader('Now vs prior bubbles'),
              _BubbleGauge(
                title: 'Shiller CAPE',
                min: 15,
                max: 48,
                now: s.cape,
                marks: _capeMarks,
                nowLabel: s.cape?.toStringAsFixed(1),
              ),
              _BubbleGauge(
                title: 'High-yield OAS (bps) — signal is the turn, not the level',
                min: 150,
                max: 700,
                now: s.hyOasBps,
                marks: _hyMarks,
                nowLabel: s.hyOasBps?.toStringAsFixed(0),
              ),
              const SizedBox(height: 16),
              _SectionHeader('Structural conditions (slow variables)'),
              ..._structuralRows(s),
              const SizedBox(height: 16),
              _SectionHeader('Cyclical catalysts (fast variables)'),
              ..._catalystRows(s),
              const SizedBox(height: 12),
              Text(
                'Thresholds calibrated on 13 crises, 1873–2022. Conditions can '
                'stay lit for years (CAPE crossed its 1929 record in 1997, three '
                'years before the top); catalysts are what end it. CAPE and '
                'margin debt update via monthly manual upsert.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _structuralRows(CrisisSnapshot s) => [
        _SignalRow(
          name: 'Index at highs',
          verdict: s.verdicts['v_index_ath']!,
          reading:
              'SPY ${_fmt(s.spyOffAthPct)}% off 52-wk high · ${s.spyDaysSinceAth ?? "—"} sessions since',
          precedent: '9 of 10 crises broke from near-ATH',
        ),
        _SignalRow(
          name: 'Valuation (CAPE)',
          verdict: s.verdicts['v_valuation']!,
          reading: 'CAPE ${_fmt(s.cape)}',
          precedent: "1929: 32.6 · 2000: 44.2 · 2022: 38.6",
        ),
        _SignalRow(
          name: 'Leverage (margin debt)',
          verdict: s.verdicts['v_leverage']!,
          reading:
              '\$${_fmt(s.marginDebtBn, 0)}B · ${_fmt(s.marginDebtYoyPct, 0)}% YoY',
          precedent: 'Records marked the 1929, 2000, 2007, 2021 tops',
        ),
        _SignalRow(
          name: 'Speculative tier',
          verdict: s.verdicts['v_spec_tier']!,
          reading: 'Spec basket ${_fmt(s.specOffHighPct)}% off high',
          precedent: "Trusts '29 · Nifty '72 · dot-coms '00 · ARKK '21 — peaked first",
        ),
      ];

  List<Widget> _catalystRows(CrisisSnapshot s) => [
        _SignalRow(
          name: 'Fed tightening',
          verdict: s.verdicts['v_fed']!,
          reading:
              'Fed funds ${_fmt(s.fedFundsPct)}% · ${_fmt(s.fedFunds90dChgBps, 0)} bps / 90d',
          precedent: 'Tightening preceded 8 of 10 crises',
        ),
        _SignalRow(
          name: 'Yield curve',
          verdict: s.verdicts['v_curve']!,
          reading: '10y–2y ${_fmt(s.t10y2yBps, 0)} bps',
          precedent: 'Inverted before 6 of 10',
        ),
        _SignalRow(
          name: 'Public credit',
          verdict: s.verdicts['v_public_credit']!,
          reading:
              'HY ${_fmt(s.hyOasBps, 0)} bps (${_fmt(s.hyOas20dChgBps, 0)} 20d) · IG ${_fmt(s.igOasBps, 0)}',
          precedent: 'Jun-2007: record tights, then the turn',
        ),
        _SignalRow(
          name: 'Private credit',
          verdict: s.verdicts['v_private_credit']!,
          reading:
              'BDCs ${_fmt(s.bdcOffHighPct)}% / managers ${_fmt(s.mgrOffHighPct)}% off high',
          precedent: 'Financials topped Feb-07 — 8 months before the index',
        ),
        _SignalRow(
          name: 'Breadth',
          verdict: s.verdicts['v_breadth']!,
          reading:
              'RSP/SPY ${_fmt(s.rspSpyOffHighPct)}% · IWM/SPY ${_fmt(s.iwmSpyOffHighPct)}% off ratio high',
          precedent: "A/D line peaked 2 yrs before the 2000 top",
        ),
      ];

  static String _fmt(double? v, [int dp = 1]) =>
      v == null ? '—' : v.toStringAsFixed(dp);
}

// ─── Widgets ──────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2, fontWeight: FontWeight.w600)),
      );
}

class _TallyCard extends StatelessWidget {
  final CrisisSnapshot s;
  const _TallyCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date =
        '${s.obsDate.year}-${s.obsDate.month.toString().padLeft(2, '0')}-${s.obsDate.day.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('Crisis Ledger',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Text('$date${s.isFinal ? " · EOD" : " · intraday"}',
                  style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _TallyStat(
                  label: 'Structural lit',
                  value: '${s.structuralLit ?? "—"}/4',
                  color: (s.structuralLit ?? 0) >= 3
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary),
              const SizedBox(width: 24),
              _TallyStat(
                  label: 'Catalysts firing',
                  value: '${s.catalystsFiring ?? "—"}/5',
                  color: (s.catalystsFiring ?? 0) >= 2
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary),
              const SizedBox(width: 24),
              _TallyStat(
                  label: 'SPY off high',
                  value: '${s.spyOffAthPct?.toStringAsFixed(1) ?? "—"}%',
                  color: theme.colorScheme.onSurface),
            ]),
            const SizedBox(height: 10),
            Text(
              'Conditions class the market; catalysts end it. Watch for a '
              'catalyst flip while conditions stay lit.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TallyStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _TallyStat(
      {required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700, color: color)),
      Text(label, style: theme.textTheme.bodySmall),
    ]);
  }
}

/// Horizontal gauge: muted markers for historical bubble readings, an accent
/// marker for today. Pure comparison — no interpolation, no prediction.
class _BubbleGauge extends StatelessWidget {
  final String title;
  final double min, max;
  final double? now;
  final String? nowLabel;
  final List<_BubbleMark> marks;
  const _BubbleGauge({
    required this.title,
    required this.min,
    required this.max,
    required this.now,
    required this.marks,
    this.nowLabel,
  });

  double _pos(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: theme.textTheme.bodySmall),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          return SizedBox(
            height: 34,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              for (final m in marks) ...[
                Positioned(
                  left: _pos(m.value) * w - 1,
                  top: 4,
                  child: Container(width: 2, height: 12, color: muted),
                ),
                Positioned(
                  left: (_pos(m.value) * w - 24).clamp(0.0, w - 48),
                  top: 18,
                  child: SizedBox(
                    width: 48,
                    child: Text('${m.label}\n${_short(m.value)}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: muted, height: 1.1)),
                  ),
                ),
              ],
              if (now != null) ...[
                Positioned(
                  left: _pos(now!) * w - 5,
                  top: 0,
                  child: Container(
                    width: 10,
                    height: 20,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                Positioned(
                  left: (_pos(now!) * w - 24).clamp(0.0, w - 48),
                  top: -18,
                  child: SizedBox(
                    width: 48,
                    child: Text('now ${nowLabel ?? ""}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ]),
          );
        }),
      ]),
    );
  }

  static String _short(double v) =>
      v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class _SignalRow extends StatelessWidget {
  final String name, verdict, reading, precedent;
  const _SignalRow({
    required this.name,
    required this.verdict,
    required this.reading,
    required this.precedent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label) = switch (verdict) {
      'firing' => (theme.colorScheme.error, 'FIRING'),
      'partial' => (const Color(0xFFB8860B), 'PARTIAL'),
      'clean' => (const Color(0xFF2E7D52), 'CLEAN'),
      _ => (theme.colorScheme.onSurface.withValues(alpha: 0.4), 'UNKNOWN'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(reading, style: theme.textTheme.bodySmall),
            Text(precedent,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic)),
          ]),
        ),
      ]),
    );
  }
}
