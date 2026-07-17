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

import '../screens/crisis_history_screen.dart';

// ─── Model ────────────────────────────────────────────────────────────────

class CrisisSnapshot {
  final DateTime obsDate;
  final double? spyClose, spyOffAthPct;
  final int? spyDaysSinceAth;
  final double? cape, marginDebtBn, marginDebtYoyPct;
  final double? fedFundsPct, fedFunds90dChgBps, t10y2yBps;
  final double? cpiYoyPct, cpiCoreYoyPct;
  final double? hyOasBps, igOasBps, hyOas20dChgBps;
  final double? hygIef20dPct, lqdIef20dPct, tlt20dPct;
  final double? ccDelinqPct, loanDelinqPct, bankDepositsYoyPct, bankCreditYoyPct;
  final double? dollarIdx, dollar20dPct, jpyusd20dPct, fxi20dPct;
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
        hygIef20dPct = _d(j['hyg_ief_20d_pct']),
        lqdIef20dPct = _d(j['lqd_ief_20d_pct']),
        tlt20dPct = _d(j['tlt_20d_pct']),
        ccDelinqPct = _d(j['cc_delinq_pct']),
        loanDelinqPct = _d(j['loan_delinq_pct']),
        bankDepositsYoyPct = _d(j['bank_deposits_yoy_pct']),
        bankCreditYoyPct = _d(j['bank_credit_yoy_pct']),
        dollarIdx = _d(j['dollar_idx']),
        dollar20dPct = _d(j['dollar_20d_pct']),
        jpyusd20dPct = _d(j['jpyusd_20d_pct']),
        fxi20dPct = _d(j['fxi_20d_pct']),
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

// ─── Prediction markets (Polymarket, snapshotted daily by crisis_pull) ────

class PredictionMarket {
  final DateTime obsDate;
  final String eventSlug, eventTitle, question;
  final double? yesProbability;
  final double volumeUsd;

  PredictionMarket.fromJson(Map<String, dynamic> j)
      : obsDate = DateTime.parse(j['obs_date'] as String),
        eventSlug = j['event_slug'] as String,
        eventTitle = (j['event_title'] as String?) ?? '',
        question = j['question'] as String,
        yesProbability = j['yes_probability'] == null
            ? null
            : (j['yes_probability'] as num).toDouble(),
        volumeUsd = ((j['volume_usd'] as num?) ?? 0).toDouble();
}

final predictionMarketsProvider =
    FutureProvider<List<PredictionMarket>>((ref) async {
  final rows = await Supabase.instance.client
      .from('prediction_market_snapshots')
      .select()
      .order('obs_date', ascending: false)
      .limit(60);
  final all = (rows as List)
      .map((r) => PredictionMarket.fromJson(r as Map<String, dynamic>))
      .toList();
  if (all.isEmpty) return all;
  final latest = all.first.obsDate;
  return all.where((m) => m.obsDate == latest).toList();
});

/// Card of real-money forward probabilities. Pass a [slugFilter] to show a
/// subset (e.g. only the data-center moratorium market on the AI Cycle tab).
class PredictionMarketsCard extends ConsumerWidget {
  final String? slugFilter;
  final String? footnote;
  const PredictionMarketsCard({super.key, this.slugFilter, this.footnote});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(predictionMarketsProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (markets) {
        var shown = slugFilter == null
            ? markets
            : markets.where((m) => m.eventSlug.contains(slugFilter!)).toList();
        if (shown.isEmpty) return const SizedBox.shrink();
        shown = [...shown]..sort((a, b) {
            final t = a.eventTitle.compareTo(b.eventTitle);
            return t != 0 ? t : b.volumeUsd.compareTo(a.volumeUsd);
          });
        final byEvent = <String, List<PredictionMarket>>{};
        for (final m in shown) {
          byEvent.putIfAbsent(m.eventTitle, () => []).add(m);
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Prediction markets — what real money expects',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text(
                  'Polymarket YES prices, snapshotted daily · '
                  '${shown.first.obsDate.toIso8601String().split("T").first}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.55))),
              const SizedBox(height: 10),
              for (final entry in byEvent.entries) ...[
                Text(entry.key,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                for (final m in entry.value) _PmRow(market: m),
                const SizedBox(height: 8),
              ],
              if (footnote != null)
                Text(footnote!,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55))),
            ]),
          ),
        );
      },
    );
  }

  static String _shorten(String q) => q
      .replaceFirst('Will the Fed ', '')
      .replaceFirst('Will there be ', '')
      .replaceFirst('Fed Rate Hike by ', 'Hike by ')
      .replaceFirst(' after the September 2026 meeting?', ' (Sept)')
      .replaceFirst(' Meeting?', '')
      .replaceFirst('Will any state enact a data center moratorium by December 31?',
          'Any state enacts a data-center moratorium by Dec 31');
}

/// Full daily history for one market question (for the sparkline).
final pmHistoryProvider =
    FutureProvider.family<List<(DateTime, double)>, String>((ref, question) async {
  final rows = await Supabase.instance.client
      .from('prediction_market_snapshots')
      .select('obs_date,yes_probability')
      .eq('question', question)
      .order('obs_date', ascending: true)
      .limit(730);
  return (rows as List)
      .where((r) => r['yes_probability'] != null)
      .map((r) => (
            DateTime.parse(r['obs_date'] as String),
            (r['yes_probability'] as num).toDouble(),
          ))
      .toList();
});

class PmAlert {
  final String id, eventSlug, question, direction;
  final double threshold;
  final DateTime? triggeredAt;
  final double? triggeredProbability;

  PmAlert.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        eventSlug = j['event_slug'] as String,
        question = j['question'] as String,
        direction = j['direction'] as String,
        threshold = (j['threshold'] as num).toDouble(),
        triggeredAt = j['triggered_at'] == null
            ? null
            : DateTime.parse(j['triggered_at'] as String).toLocal(),
        triggeredProbability = j['triggered_probability'] == null
            ? null
            : (j['triggered_probability'] as num).toDouble();
}

final pmAlertsProvider = FutureProvider<List<PmAlert>>((ref) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return const [];
  final rows = await Supabase.instance.client
      .from('prediction_market_alerts')
      .select()
      .eq('active', true)
      .order('created_at', ascending: false)
      .limit(100);
  return (rows as List)
      .map((r) => PmAlert.fromJson(r as Map<String, dynamic>))
      .toList();
});

/// One market row: probability bar, tap to expand into the history sparkline
/// and alert controls.
class _PmRow extends ConsumerStatefulWidget {
  final PredictionMarket market;
  const _PmRow({required this.market});

  @override
  ConsumerState<_PmRow> createState() => _PmRowState();
}

class _PmRowState extends ConsumerState<_PmRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.market;
    final alerts = ref.watch(pmAlertsProvider).valueOrNull ?? const <PmAlert>[];
    final myAlerts = alerts.where((a) => a.question == m.question).toList();
    final triggered = myAlerts.where((a) => a.triggeredAt != null).toList();

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (triggered.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.notifications_active,
                    size: 14, color: theme.colorScheme.error),
              )
            else if (myAlerts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.notifications_none,
                    size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
              ),
            Expanded(
              child: Text(PredictionMarketsCard._shorten(m.question),
                  style: theme.textTheme.bodySmall),
            ),
            SizedBox(
              width: 60,
              child: LayoutBuilder(builder: (context, box) {
                final p = (m.yesProbability ?? 0).clamp(0.0, 1.0);
                return Container(
                  height: 8,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Container(
                    width: box.maxWidth * p,
                    decoration: BoxDecoration(
                      color: p >= 0.5
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                );
              }),
            ),
            SizedBox(
              width: 46,
              child: Text(
                m.yesProbability == null
                    ? '—'
                    : '${(m.yesProbability! * 100).toStringAsFixed(m.yesProbability! < 0.10 ? 1 : 0)}%',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          if (_expanded) _PmDetail(market: m, alerts: myAlerts),
        ]),
      ),
    );
  }
}

class _PmDetail extends ConsumerWidget {
  final PredictionMarket market;
  final List<PmAlert> alerts;
  const _PmDetail({required this.market, required this.alerts});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final history = ref.watch(pmHistoryProvider(market.question));

    return Padding(
      padding: const EdgeInsets.only(left: 18, top: 6, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        history.when(
          loading: () => const SizedBox(
              height: 40, child: Center(child: CircularProgressIndicator())),
          error: (e, _) =>
              Text('history unavailable: $e', style: theme.textTheme.labelSmall),
          data: (pts) => pts.length < 2
              ? Text(
                  'History accumulates daily — ${pts.length} snapshot so far. '
                  'The chart appears from the second day.',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.55)))
              : SizedBox(
                  height: 48,
                  child: CustomPaint(
                    size: const Size(double.infinity, 48),
                    painter: _SparklinePainter(
                      points: pts,
                      lineColor: theme.colorScheme.primary,
                      gridColor:
                          theme.colorScheme.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          for (final a in alerts)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                label: Text(
                  '${a.direction == "above" ? "≥" : "≤"} ${(a.threshold * 100).toStringAsFixed(0)}%'
                  '${a.triggeredAt != null ? " · FIRED ${(a.triggeredProbability! * 100).toStringAsFixed(0)}%" : ""}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: a.triggeredAt != null
                          ? theme.colorScheme.error
                          : null),
                ),
                onDeleted: () async {
                  await Supabase.instance.client
                      .from('prediction_market_alerts')
                      .delete()
                      .eq('id', a.id);
                  ref.invalidate(pmAlertsProvider);
                },
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add_alert, size: 14),
            label: Text('Alert', style: theme.textTheme.labelSmall),
            onPressed: () async {
              final user = Supabase.instance.client.auth.currentUser;
              if (user == null) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Sign in to create alerts')));
                }
                return;
              }
              final result = await showDialog<(String, double)>(
                context: context,
                builder: (_) => _AlertDialog(
                    question: market.question,
                    current: market.yesProbability),
              );
              if (result == null) return;
              await Supabase.instance.client
                  .from('prediction_market_alerts')
                  .insert({
                'user_id': user.id,
                'event_slug': market.eventSlug,
                'question': market.question,
                'direction': result.$1,
                'threshold': result.$2,
              });
              ref.invalidate(pmAlertsProvider);
            },
          ),
        ]),
      ]),
    );
  }
}

class _AlertDialog extends StatefulWidget {
  final String question;
  final double? current;
  const _AlertDialog({required this.question, this.current});

  @override
  State<_AlertDialog> createState() => _AlertDialogState();
}

class _AlertDialogState extends State<_AlertDialog> {
  String _direction = 'above';
  late double _thresholdPct =
      ((widget.current ?? 0.5) * 100).clamp(1.0, 99.0).roundToDouble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Alert on this market', style: theme.textTheme.titleSmall),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.question, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'above', label: Text('Rises above')),
            ButtonSegment(value: 'below', label: Text('Falls below')),
          ],
          selected: {_direction},
          onSelectionChanged: (s) => setState(() => _direction = s.first),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Slider(
              value: _thresholdPct,
              min: 1,
              max: 99,
              divisions: 98,
              label: '${_thresholdPct.toStringAsFixed(0)}%',
              onChanged: (v) => setState(() => _thresholdPct = v),
            ),
          ),
          SizedBox(
              width: 40,
              child: Text('${_thresholdPct.toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall)),
        ]),
        Text(
          'Checked once per trading day at the 21:10 UTC snapshot.',
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (_direction, _thresholdPct / 100)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<(DateTime, double)> points;
  final Color lineColor, gridColor;
  _SparklinePainter(
      {required this.points, required this.lineColor, required this.gridColor});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    // 0%, 50%, 100% reference lines
    for (final f in [0.0, 0.5, 1.0]) {
      final y = size.height - f * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (points.length < 2) return;
    final t0 = points.first.$1.millisecondsSinceEpoch.toDouble();
    final t1 = points.last.$1.millisecondsSinceEpoch.toDouble();
    final span = (t1 - t0) == 0 ? 1.0 : (t1 - t0);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = (points[i].$1.millisecondsSinceEpoch - t0) / span * size.width;
      final y = size.height - points[i].$2.clamp(0.0, 1.0) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = lineColor
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
    final last = points.last;
    canvas.drawCircle(
        Offset(size.width, size.height - last.$2.clamp(0.0, 1.0) * size.height),
        3,
        Paint()..color = lineColor);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.points != points || old.lineColor != lineColor;
}

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
              const SizedBox(height: 8),
              const _AboutCard(),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.history_edu_outlined),
                  title: const Text('The Evidence — 13 crises, 1873–2022',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                      'Full case files: lead-ups, triggers, warnings, and '
                      'which of their signals are firing today'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const CrisisHistoryScreen()),
                  ),
                ),
              ),
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
              const PredictionMarketsCard(
                slugFilter: 'fed',
                footnote:
                    'A hike materializing flips the Fed-tightening catalyst '
                    '(signal preceded 8 of 10 crises) while structural '
                    'conditions are lit — the ledger\'s classic pre-break '
                    'configuration.',
              ),
              const SizedBox(height: 16),
              _SectionHeader('Structural conditions (slow variables)'),
              ..._structuralRows(s),
              const SizedBox(height: 16),
              _SectionHeader('Cyclical catalysts (fast variables)'),
              ..._catalystRows(s),
              const SizedBox(height: 16),
              _SectionHeader('Household · banks · global (monitors)'),
              _MonitorRow(
                name: 'Consumer stress',
                reading:
                    'CC delinquency ${_fmt(s.ccDelinqPct)}% · all loans ${_fmt(s.loanDelinqPct)}%',
                context:
                    'Fed quarterly. Card delinquency peaked ~6.8% in 2009; rising trend = the household piece cracking.',
              ),
              _MonitorRow(
                name: 'Bank balance sheets (H.8)',
                reading:
                    'Deposits ${_fmt(s.bankDepositsYoyPct)}% YoY · bank credit ${_fmt(s.bankCreditYoyPct)}% YoY',
                context:
                    'Weekly. Deposit contraction was the March-2023 tell; credit contraction preceded past recessions.',
              ),
              _MonitorRow(
                name: 'Dollar (global funding)',
                reading:
                    'Broad index ${_fmt(s.dollarIdx)} (${_fmt(s.dollar20dPct)}% /20d)',
                context:
                    'Sharp USD spikes = global dollar-funding stress (2008, 2020, 2022).',
              ),
              _MonitorRow(
                name: 'Yen carry',
                reading: 'USD/JPY ${_fmt(s.jpyusd20dPct)}% /20d',
                context:
                    'Sharply negative = yen strengthening fast = carry unwinding (Aug-2024 signature).',
              ),
              _MonitorRow(
                name: 'China (traded proxy)',
                reading: 'FXI ${_fmt(s.fxi20dPct)}% /20d',
                context:
                    '1873 started in Vienna — this is the Vienna feed. ETF proxy until better data exists.',
              ),
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
          eduWhat:
              'Distance of SPY from its 52-week high. Crashes start from strength: '
              'in 9 of the 10 index-era crises the market stood at or within weeks '
              'of an all-time high when the break began (the exception, 1907, was '
              'already down 25%).',
          eduWatch:
              'This signal alone means nothing — it is the arming condition for '
              'everything below. A market far from its highs cannot "top."',
        ),
        _SignalRow(
          name: 'Valuation (CAPE)',
          verdict: s.verdicts['v_valuation']!,
          reading: 'CAPE ${_fmt(s.cape)}',
          precedent: "1929: 32.6 · 2000: 44.2 · 2022: 38.6",
          eduWhat:
              'Shiller cyclically-adjusted P/E: price against 10-year average real '
              'earnings. Every reading above 35 in history clusters around 1929, '
              '1999-2000, 2021, and now. High CAPE never times a top — it crossed '
              'its 1929 record in 1997, three years early — but it sets the size '
              'of the eventual repricing.',
          eduWatch:
              'Updated monthly by manual reseed (no free daily source). Fires ≥35, '
              'partial ≥30.',
        ),
        _SignalRow(
          name: 'Leverage (margin debt)',
          verdict: s.verdicts['v_leverage']!,
          reading:
              '\$${_fmt(s.marginDebtBn, 0)}B · ${_fmt(s.marginDebtYoyPct, 0)}% YoY',
          precedent: 'Records marked the 1929, 2000, 2007, 2021 tops',
          eduWhat:
              'FINRA investor margin debt, year-over-year growth. Record leverage '
              'marked all four great tops, and it is why those declines fed on '
              'themselves: borrowed positions become forced sellers. The growth '
              'rate matters more than the level — fast borrowing = late-cycle '
              'conviction.',
          eduWatch:
              'Monthly FINRA release, manually reseeded. Fires ≥25% YoY, partial '
              '≥10%.',
        ),
        _SignalRow(
          name: 'Speculative tier',
          verdict: s.verdicts['v_spec_tier']!,
          reading: 'Spec basket ${_fmt(s.specOffHighPct)}% off high',
          precedent: "Trusts '29 · Nifty '72 · dot-coms '00 · ARKK '21 — peaked first",
          eduWhat:
              "Each cycle's parabolic basket (currently the memory pair) measured "
              'against its own high while the index holds near highs. In every '
              'mania on record the speculative class topped before the index: '
              "investment trusts in 1929, go-go funds in '68, the Nifty Fifty in "
              "'72, profitless dot-coms in early 2000, ARKK/memes in Feb 2021 — "
              'that one 11 months before the S&P.',
          eduWatch:
              'Fires when the basket is −20% off its high while SPY sits within '
              '5% of its own. Firing = the canary died; the question becomes '
              'absorption (rotation) vs contagion.',
        ),
      ];

  List<Widget> _catalystRows(CrisisSnapshot s) => [
        _SignalRow(
          name: 'Fed tightening',
          verdict: s.verdicts['v_fed']!,
          reading:
              'Fed funds ${_fmt(s.fedFundsPct)}% · ${_fmt(s.fedFunds90dChgBps, 0)} bps / 90d',
          precedent: 'Tightening preceded 8 of 10 crises',
          eduWhat:
              '90-day change in the effective fed funds rate. Monetary tightening '
              'into the peak preceded 8 of 10 index-era crises — 1929, 1937, '
              "1969, 1973, 1987, 2000, 2007, 2022. The two exceptions were a pure "
              'valuation break (1962) and a pandemic (2020).',
          eduWatch:
              'Fires at +50bp/90d. A hiking resumption while the structural '
              'conditions above stay lit is the ledger\'s classic pre-break '
              'configuration.',
        ),
        _SignalRow(
          name: 'Yield curve',
          verdict: s.verdicts['v_curve']!,
          reading: '10y–2y ${_fmt(s.t10y2yBps, 0)} bps',
          precedent: 'Inverted before 6 of 10',
          eduWhat:
              '10-year minus 2-year Treasury yield. Inversion preceded 6 of 10 '
              'crises and every recession since 1955 with one false positive '
              '(1966). Lead times run 6–24 months — it warns of the regime, '
              'not the week.',
          eduWatch:
              'Fires on inversion (≤0), partial when flat (≤25bp). Level-based: '
              'a curve flickering around zero reads calmer here than it is.',
        ),
        _SignalRow(
          name: 'Public credit',
          verdict: s.verdicts['v_public_credit']!,
          reading:
              'HY ${_fmt(s.hyOasBps, 0)} bps (${_fmt(s.hyOas20dChgBps, 0)} 20d) · IG ${_fmt(s.igOasBps, 0)} · '
              'traded: HYG/IEF ${_fmt(s.hygIef20dPct)}%, LQD/IEF ${_fmt(s.lqdIef20dPct)}%, TLT ${_fmt(s.tlt20dPct)}% /20d',
          precedent: 'Jun-2007: record tights, then the turn',
          eduWhat:
              'High-yield option-adjusted spread over Treasuries: the public '
              "market's price of default risk. The level never warned — spreads "
              'sat at record tights in June 2007 — but the TURN off the tights '
              'preceded the equity top by four months. Tight spreads are the '
              'starting point of every credit cycle ending, not evidence of '
              'safety.',
          eduWatch:
              'Fires above 400bp or on +50bp in 20 days — the turn, not the '
              'level.',
        ),
        _SignalRow(
          name: 'Private credit',
          verdict: s.verdicts['v_private_credit']!,
          reading:
              'BDCs ${_fmt(s.bdcOffHighPct)}% / managers ${_fmt(s.mgrOffHighPct)}% off high',
          precedent: 'Financials topped Feb-07 — 8 months before the index',
          eduWhat:
              'Listed BDCs (which hold private loans, so their shares price the '
              'quarterly-marked books daily) and alternative-credit managers, '
              'each vs their 52-week highs. Opaque credit is where this cycle\'s '
              'buildout debt lives — the seat railroad bonds held in 1873 and '
              'securitized mortgages in 2007, when credit-adjacent equities '
              'topped 8 months before the index while spreads stayed serene.',
          eduWatch:
              'Fires when the weaker composite is −15% off its high and still '
              'falling over 20 days. The escalation to watch: stress reaching '
              'the funding system (2007) vs staying contained in one asset '
              'class (1998).',
        ),
        _SignalRow(
          name: 'Breadth',
          verdict: s.verdicts['v_breadth']!,
          reading:
              'RSP/SPY ${_fmt(s.rspSpyOffHighPct)}% · IWM/SPY ${_fmt(s.iwmSpyOffHighPct)}% off ratio high',
          precedent: "A/D line peaked 2 yrs before the 2000 top",
          eduWhat:
              'Whether the average stock confirms the index: equal-weight S&P '
              '(RSP) and small caps (IWM) against cap-weighted SPY. The NYSE '
              'advance/decline line peaked in April 1998 — two years before the '
              '2000 top; financials led 2007 down by months. But 1987 and 2020 '
              'broke with clean breadth, so clean is necessary comfort, never '
              'sufficient.',
          eduWatch:
              'Fires when RSP\'s own high goes 60+ sessions staler than SPY\'s '
              '(partial at 20). The first tell if "absorption" of a sector '
              'unwind is failing.',
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

/// Data-first monitor row: no verdict yet — these accumulate history until
/// thresholds can be calibrated, but the readings surface immediately.
class _MonitorRow extends StatelessWidget {
  final String name, reading, context;
  const _MonitorRow(
      {required this.name, required this.reading, required this.context});

  @override
  Widget build(BuildContext buildContext) {
    final theme = Theme.of(buildContext);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('MONITOR',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(reading, style: theme.textTheme.bodySmall),
            Text(context,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic)),
          ]),
        ),
      ]),
    );
  }
}

/// Signal row with tap-to-expand education: what the signal measures, why it
/// earned a place in the checklist, and what would change its verdict.
class _SignalRow extends StatefulWidget {
  final String name, verdict, reading, precedent, eduWhat, eduWatch;
  const _SignalRow({
    required this.name,
    required this.verdict,
    required this.reading,
    required this.precedent,
    required this.eduWhat,
    required this.eduWatch,
  });

  @override
  State<_SignalRow> createState() => _SignalRowState();
}

class _SignalRowState extends State<_SignalRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label) = switch (widget.verdict) {
      'firing' => (theme.colorScheme.error, 'FIRING'),
      'partial' => (const Color(0xFFB8860B), 'PARTIAL'),
      'clean' => (const Color(0xFF2E7D52), 'CLEAN'),
      _ => (theme.colorScheme.onSurface.withValues(alpha: 0.4), 'UNKNOWN'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(widget.reading, style: theme.textTheme.bodySmall),
                Text(widget.precedent,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.55),
                        fontStyle: FontStyle.italic)),
              ]),
            ),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
          ]),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 84, top: 8, right: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.eduWhat, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Text('Watch: ${widget.eduWatch}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w500)),
                  ]),
            ),
        ]),
      ),
    );
  }
}

/// Expandable primer: how to read the screen, the conditions/catalysts
/// framework, the two historical resolutions, and the base rates.
class _AboutCard extends StatefulWidget {
  const _AboutCard();

  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  bool _expanded = false;

  static const _sections = <(String, String)>[
    (
      'Conditions vs catalysts',
      'Structural conditions (valuation, leverage, index posture, speculative '
          'excess) are slow variables: they tell you which regime you are in, '
          'and they can stay lit for years — CAPE first crossed its 1929 record '
          'in 1997, three years before the top. Catalysts (Fed, curve, credit, '
          'breadth) are fast variables: they tell you the ending has started. '
          'Age never killed a bull in the record; catalysts did. The dangerous '
          'configuration is a catalyst flipping while conditions stay lit.',
    ),
    (
      'The two historical resolutions',
      'When a periphery cracks while the core stays serene, history offers two '
          'branches. 1998: peripheral credit stress (LTCM/Asia) was absorbed, '
          'and the finale was a melt-up into March 2000. 2007: the periphery '
          '(financials, down from February) WAS the core, discovered late; the '
          'index made its last high in October. The distinguishing variable was '
          'whether credit stress reached the funding system or stayed contained '
          'in one asset class.',
    ),
    (
      'Base rates (post-war S&P)',
      'Bear market: −33% average over ~13 months. Recovery to the prior peak: '
          '~1–2 years without a recession (1962, 1987, 2022), 5–25 years with '
          'one (2008: 5.5y; 2000: 7+; 1929: 25). Regime matters for hedging: '
          'in deflationary/demand busts (1929, 2000, 2008, 2020) Treasuries '
          'rallied; in inflationary bears (1973, 2022) bonds fell with stocks '
          'and nothing hedged.',
    ),
    (
      'Reading the gauges',
      'Grey markers show where prior bubbles peaked; the red marker is today. '
          'The gauges compare levels — but note that for credit the historical '
          'signal was always the TURN off the tights, never the level itself. '
          'Verdicts: FIRING = the historical pre-crisis condition is present; '
          'PARTIAL = approaching; CLEAN = absent; UNKNOWN = awaiting data '
          '(CAPE and margin debt reseed monthly). Tap any signal for its '
          'history.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.school_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('How to read this screen',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
            ]),
            if (_expanded) ...[
              const SizedBox(height: 10),
              for (final (title, body) in _sections) ...[
                Text(title,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(body, style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
              ],
              Text(
                'Calibration: thresholds derived from 13 U.S. market crises, '
                '1873–2022. This screen reports historical pattern-matches — '
                'it does not predict. Every signal has produced false positives '
                'measured in years.',
                style: theme.textTheme.labelSmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
