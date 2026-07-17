// features/economy/widgets/ai_cycle_tab.dart — AI Cycle tab
//
// Renders sector_fundamentals (written weekly by api/jobs/fundamentals_pull.py
// from SEC EDGAR XBRL): hyperscaler aggregate capex — the dollars funding the
// buildout — plus per-name revenue/capex for the semiconductor supply chain.
// The railroad-dashboard framing: hyperscaler capex is "traffic," supply-chain
// revenue growth is the estimate treadmill; deceleration in either is the
// signal price data cannot give you.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crisis_ledger_tab.dart' show PredictionMarketsCard, SourceLink;

class SectorFact {
  final String ticker, universe, metric, unit;
  final DateTime periodEnd;
  final double value;

  SectorFact.fromJson(Map<String, dynamic> j)
      : ticker = j['ticker'] as String,
        universe = j['universe'] as String,
        metric = j['metric'] as String,
        unit = (j['unit'] as String?) ?? 'USD',
        periodEnd = DateTime.parse(j['period_end'] as String),
        value = (j['value'] as num).toDouble();
}

final sectorFundamentalsProvider =
    FutureProvider<List<SectorFact>>((ref) async {
  final rows = await Supabase.instance.client
      .from('sector_fundamentals')
      .select('ticker,universe,metric,period_end,value,unit')
      .eq('period_type', 'Q')
      .order('period_end', ascending: false)
      .limit(900);
  return (rows as List)
      .map((r) => SectorFact.fromJson(r as Map<String, dynamic>))
      .toList();
});

class AiCycleTab extends ConsumerWidget {
  const AiCycleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sectorFundamentalsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(sectorFundamentalsProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [
          Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Failed to load fundamentals: $e')),
        ]),
        data: (facts) {
          if (facts.isEmpty) {
            return ListView(children: const [
              Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No fundamentals yet — run the fundamentals-pull job once '
                    'to seed sector_fundamentals from EDGAR.'),
              ),
            ]);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _HyperscalerCapexCard(facts: facts),
              const SizedBox(height: 16),
              const PredictionMarketsCard(
                slugFilter: 'moratorium',
                footnote:
                    'Regulatory risk on the buildout, priced by real money — '
                    'the 1887 ICC moment arriving as a tradeable probability.',
              ),
              const SizedBox(height: 16),
              _UniverseTable(
                title: 'Supply — semiconductor complex',
                subtitle:
                    'Latest reported quarter · revenue YoY is the estimate '
                    'treadmill; watch for deceleration',
                facts: facts,
                universe: 'supply',
              ),
              const SizedBox(height: 16),
              _UniverseTable(
                title: 'Demand — hyperscaler capex',
                subtitle:
                    'The checkbook funding the buildout. This aggregate '
                    'decelerating is the cycle-turn signal price data can\'t '
                    'show',
                facts: facts,
                universe: 'demand',
              ),
              const SizedBox(height: 12),
              Text(
                'Source: SEC EDGAR XBRL (companyconcept), polled weekly. '
                'Values as reported; foreign filers (TSM, ASML) may report in '
                'native currency and are excluded from USD aggregates. '
                'Filings lag quarter-end by 2–6 weeks — same data the '
                'institutional models run on.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SourceLink(
                  url: 'https://www.sec.gov/edgar/search/',
                  label: 'SEC EDGAR (filings)'),
              const SourceLink(
                  url: 'https://www.census.gov/construction/c30/c30index.html',
                  label: 'Census construction spending (data centers)'),
            ],
          );
        },
      ),
    );
  }
}

// ─── Hyperscaler aggregate ────────────────────────────────────────────────

class _HyperscalerCapexCard extends StatelessWidget {
  final List<SectorFact> facts;
  const _HyperscalerCapexCard({required this.facts});

  String _bucket(DateTime d) {
    final q = ((d.month - 1) ~/ 3) + 1;
    return '${d.year} Q$q';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Aggregate demand-universe USD capex by calendar quarter of period_end
    final byQ = <String, double>{};
    for (final f in facts) {
      if (f.universe != 'demand' || f.metric != 'capex' || f.unit != 'USD') {
        continue;
      }
      byQ.update(_bucket(f.periodEnd), (v) => v + f.value,
          ifAbsent: () => f.value);
    }
    final keys = byQ.keys.toList()..sort();
    // Drop the newest bucket if it's obviously partial (not all 5 filed yet):
    // compare reporter count implicitly via value vs prior — keep simple and
    // show it flagged instead.
    final show = keys.length > 8 ? keys.sublist(keys.length - 8) : keys;
    final maxV =
        show.isEmpty ? 1.0 : show.map((k) => byQ[k]!).reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hyperscaler capex — the buildout, in dollars',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text('MSFT + GOOGL + AMZN + META + ORCL, by calendar quarter',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
          const SizedBox(height: 12),
          for (final k in show) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(
                    width: 64,
                    child: Text(k, style: theme.textTheme.labelSmall)),
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    final yoyKey = _yoyKey(k);
                    final yoy = byQ.containsKey(yoyKey) && byQ[yoyKey]! > 0
                        ? (byQ[k]! / byQ[yoyKey]! - 1) * 100
                        : null;
                    final w = (byQ[k]! / maxV) * box.maxWidth;
                    return Stack(children: [
                      Container(
                        height: 16,
                        width: w.clamp(2.0, box.maxWidth),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Positioned(
                        left: (w + 6).clamp(6.0, box.maxWidth - 90),
                        top: 1,
                        child: Text(
                          '\$${(byQ[k]! / 1e9).toStringAsFixed(0)}B'
                          '${yoy != null ? "  ${yoy >= 0 ? "+" : ""}${yoy.toStringAsFixed(0)}% y/y" : ""}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ]);
                  }),
                ),
              ]),
            ),
          ],
          if (show.isNotEmpty)
            Text(
              'Newest quarter may be partial until all five have filed.',
              style: theme.textTheme.labelSmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
            ),
        ]),
      ),
    );
  }

  String _yoyKey(String k) {
    final parts = k.split(' ');
    return '${int.parse(parts[0]) - 1} ${parts[1]}';
  }
}

// ─── Per-name table ───────────────────────────────────────────────────────

class _UniverseTable extends StatelessWidget {
  final String title, subtitle, universe;
  final List<SectorFact> facts;
  const _UniverseTable({
    required this.title,
    required this.subtitle,
    required this.facts,
    required this.universe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metric = universe == 'demand' ? 'capex' : 'revenue';
    final tickers = facts
        .where((f) => f.universe == universe)
        .map((f) => f.ticker)
        .toSet()
        .toList()
      ..sort();

    final rows = <_NameRow>[];
    for (final t in tickers) {
      final series = facts
          .where((f) =>
              f.ticker == t && f.metric == metric && f.universe == universe)
          .toList()
        ..sort((a, b) => b.periodEnd.compareTo(a.periodEnd));
      if (series.isEmpty) continue;
      final latest = series.first;
      // YoY: the entry ~4 quarters back (330–405 days earlier)
      SectorFact? prior;
      for (final f in series.skip(1)) {
        final d = latest.periodEnd.difference(f.periodEnd).inDays;
        if (d >= 330 && d <= 405) {
          prior = f;
          break;
        }
      }
      rows.add(_NameRow(
        ticker: t,
        latest: latest,
        yoyPct: prior != null && prior.value > 0
            ? (latest.value / prior.value - 1) * 100
            : null,
      ));
    }
    rows.sort((a, b) => (b.yoyPct ?? -999).compareTo(a.yoyPct ?? -999));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(subtitle,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
          const SizedBox(height: 10),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(
                    width: 56,
                    child: Text(r.ticker,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w700))),
                SizedBox(
                  width: 110,
                  child: Text(
                    r.latest.unit == 'USD'
                        ? '\$${(r.latest.value / 1e9).toStringAsFixed(1)}B'
                        : '${(r.latest.value / 1e9).toStringAsFixed(1)}B ${r.latest.unit}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    r.yoyPct == null
                        ? '—'
                        : '${r.yoyPct! >= 0 ? "+" : ""}${r.yoyPct!.toStringAsFixed(0)}% y/y',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: r.yoyPct == null
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                          : r.yoyPct! >= 0
                              ? const Color(0xFF2E7D52)
                              : theme.colorScheme.error,
                    ),
                  ),
                ),
                Text(
                  '${r.latest.periodEnd.year}-${r.latest.periodEnd.month.toString().padLeft(2, "0")}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _NameRow {
  final String ticker;
  final SectorFact latest;
  final double? yoyPct;
  _NameRow({required this.ticker, required this.latest, this.yoyPct});
}
