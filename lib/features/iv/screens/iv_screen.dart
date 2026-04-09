// =============================================================================
// features/iv/screens/iv_screen.dart
// =============================================================================
// IV Analytics screen — per-ticker view with:
//   • IV Rank gauge (IVR + IVP + 52w range)
//   • IV History chart (ATM IV, skew, GEX trend over time)
//   • Volatility skew curve
//   • Gamma Exposure (GEX) bar chart + gamma wall
//   • Vanna / Charm / Volga dealer positioning
//   • Strategy context card
//   • Greek glossary (plain-English definitions + profit decision guide)
//
// Route: /ticker/:symbol/iv
// Pushed from OptionsChainScreen analytics button.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_providers.dart';
import '../widgets/gex_chart.dart';
import '../widgets/iv_history_chart.dart';
import '../widgets/iv_rank_gauge.dart';
import '../widgets/skew_chart.dart';
import '../widgets/vanna_charm_chart.dart';

class IvScreen extends ConsumerWidget {
  final String symbol;
  const IvScreen({super.key, required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final analysisAsync = ref.watch(ivAnalysisProvider(symbol));
    final historyAsync  = ref.watch(ivHistoryProvider(symbol));

    return Scaffold(
      appBar: AppBar(
        title: Text('$symbol — IV Analytics'),
        actions: [
          IconButton(
            icon:    const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(ivAnalysisProvider(symbol));
              ref.invalidate(ivHistoryProvider(symbol));
            },
          ),
        ],
      ),
      body: analysisAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => _ErrorView(symbol: symbol, error: e, ref: ref),
        data:    (analysis) => RefreshIndicator(
          color:     AppTheme.profitColor,
          onRefresh: () async {
            ref.invalidate(ivAnalysisProvider(symbol));
            ref.invalidate(ivHistoryProvider(symbol));
            await ref.read(ivAnalysisProvider(symbol).future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              // ── IV Rank gauge ────────────────────────────────────────────
              IvRankGauge(analysis: analysis),
              const SizedBox(height: 16),

              // ── IV History (snapshots over time) ─────────────────────────
              historyAsync.when(
                loading: () => const SizedBox.shrink(),
                error:   (_, _) => const SizedBox.shrink(),
                data: (history) => history.isNotEmpty
                    ? Column(children: [
                        IvHistoryChart(
                            history: history, ticker: symbol),
                        const SizedBox(height: 16),
                      ])
                    : const SizedBox.shrink(),
              ),

              // ── Skew curve ───────────────────────────────────────────────
              SkewChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── GEX chart ────────────────────────────────────────────────
              GexChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── Vanna / Charm / Volga ────────────────────────────────────
              VannaCharmChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── Strategy context ─────────────────────────────────────────
              _SummaryCard(analysis: analysis),
              const SizedBox(height: 16),

              // ── Greek glossary ───────────────────────────────────────────
              const _GreekGlossary(),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String symbol;
  final Object error;
  final WidgetRef ref;
  const _ErrorView({
    required this.symbol,
    required this.error,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart_rounded,
                size: 48, color: AppTheme.neutralColor),
            const SizedBox(height: 16),
            Text(
              'Could not load IV data for $symbol',
              style: const TextStyle(color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text('$error',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon:      const Icon(Icons.refresh_rounded, size: 16),
              label:     const Text('Retry'),
              onPressed: () => ref.invalidate(ivAnalysisProvider(symbol)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Trader summary card ────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final dynamic analysis; // IvAnalysis
  const _SummaryCard({required this.analysis});

  @override
  Widget build(BuildContext context) {
    // Build a concise strategy suggestion based on IVR + skew + GEX
    final ivr   = analysis.ivRank as double?;
    final skew  = analysis.skew  as double?;
    final gex   = analysis.totalGex as double?;

    final bullets = <String>[];

    // IV-based suggestion
    if (ivr != null) {
      if (ivr >= 80) {
        bullets.add('IV is extremely elevated (IVR ${ivr.toStringAsFixed(0)}%) — '
            'premium selling strategies favored: iron condors, short strangles, credit spreads.');
      } else if (ivr >= 50) {
        bullets.add('IV above average (IVR ${ivr.toStringAsFixed(0)}%) — '
            'consider vertical spreads to limit vega exposure.');
      } else if (ivr >= 25) {
        bullets.add('IV near fair value (IVR ${ivr.toStringAsFixed(0)}%) — '
            'neutral conditions; directional debit or credit spreads both viable.');
      } else {
        bullets.add('IV compressed (IVR ${ivr.toStringAsFixed(0)}%) — '
            'long premium strategies favored: debit spreads, calendars, LEAPS.');
      }
    }

    // Skew-based suggestion
    if (skew != null) {
      if (skew > 8) {
        bullets.add('Steep put skew signals elevated tail fear — '
            'put spreads offer better risk/reward than naked puts.');
      } else if (skew < 1) {
        bullets.add('Flat/inverted skew — calls relatively cheap; '
            'call spreads may offer better value than puts.');
      }
    }

    // GEX-based suggestion
    if (gex != null) {
      if (gex > 0) {
        bullets.add('Positive GEX environment — '
            'price likely to revert to the gamma wall. '
            'Range-bound strategies (iron condors) perform well.');
      } else {
        bullets.add('Negative GEX environment — '
            'directional moves can accelerate. '
            'Favor directional spreads with defined risk.');
      }
    }

    if (bullets.isEmpty) {
      bullets.add('Load an options chain for this ticker to generate strategy suggestions.');
    }

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
          const Text(
            'STRATEGY CONTEXT',
            style: TextStyle(
              color:      AppTheme.neutralColor,
              fontSize:   11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          ...bullets.map((b) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 5, height: 5,
                  decoration: const BoxDecoration(
                    color:  AppTheme.profitColor,
                    shape:  BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(b,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

// ── Greek Glossary ────────────────────────────────────────────────────────────
// Plain-English definitions of every metric on this screen, plus a clear
// "what to do" decision guide for each so traders can act immediately.

class _GreekGlossary extends StatefulWidget {
  const _GreekGlossary();

  @override
  State<_GreekGlossary> createState() => _GreekGlossaryState();
}

class _GreekGlossaryState extends State<_GreekGlossary> {
  bool _expanded = false;

  static const _entries = [
    _GlossaryEntry(
      term:   'IV Rank (IVR)',
      emoji:  '📊',
      what:   'Where today\'s IV sits inside its own 52-week high/low range. '
              '0% = at the yearly low, 100% = at the yearly high.',
      decide: 'IVR < 25% → options are CHEAP. Buy debit spreads, calendars, or LEAPS. '
              'IVR > 50% → options are EXPENSIVE. Sell premium: credit spreads, iron condors, covered calls. '
              'IVR > 80% → EXTREME. Best environment for selling strangles or straddles.',
      color:  Color(0xFF60A5FA),
    ),
    _GlossaryEntry(
      term:   'IV Percentile (IVP)',
      emoji:  '📈',
      what:   'The % of days in the past year where IV was LOWER than today. '
              'IVP 80% means IV was lower on 80% of days — so today is relatively expensive.',
      decide: 'More reliable than IVR when one large spike skews the range. '
              'Use IVP > 60% as confirmation that IV is elevated before selling premium. '
              'IVP < 30% confirms IV is genuinely compressed — safe to buy options.',
      color:  Color(0xFF60A5FA),
    ),
    _GlossaryEntry(
      term:   'Volatility Skew',
      emoji:  '📉',
      what:   'The difference between OTM put IV and OTM call IV. '
              'Positive = puts cost more than calls (fear premium). '
              'Flat/negative = calls are bid up (bullish sentiment or squeeze risk).',
      decide: 'Steep skew (>8pp) → put spreads are expensive, avoid buying naked puts. '
              'Consider call spreads or put ratio spreads instead. '
              'Flat/inverted skew → call spreads are cheap, watch for squeeze setups. '
              'Rising skew over time → fear is building; reduce long delta exposure.',
      color:  Color(0xFFFF6B8A),
    ),
    _GlossaryEntry(
      term:   'GEX — Gamma Exposure',
      emoji:  '🧲',
      what:   'The net dollar gamma held by market-makers (dealers). '
              'Positive GEX = dealers are long gamma (bought options from the market). '
              'Negative GEX = dealers are short gamma (sold options to the market).',
      decide: 'Positive GEX → price will mean-revert. Sell the extremes, buy the dips. '
              'Iron condors and range-bound strategies thrive. '
              'Negative GEX → moves accelerate. Dealers must hedge in the direction of price. '
              'Favor directional spreads with defined risk. '
              'Gamma Wall = the strike with the highest GEX is major support/resistance.',
      color:  Color(0xFF4ADE80),
    ),
    _GlossaryEntry(
      term:   'Vanna (VEX)',
      emoji:  '⚡',
      what:   'How much dealer delta changes when IV changes. '
              'Positive VEX = when IV FALLS, dealers accumulate long delta (buy the stock). '
              'Negative VEX = when IV falls, dealers shed delta (sell the stock).',
      decide: 'Positive VEX + IV falling (e.g. post-earnings vol crush) → '
              'expect a dealer-driven RALLY as they buy delta back. This is the "vol crush rally." '
              'Negative VEX + IV falling → beware — dealers will sell into any bounce. '
              'Max VEX strike = the price level where dealer delta-hedging pressure is strongest.',
      color:  Color(0xFFFBBF24),
    ),
    _GlossaryEntry(
      term:   'Charm (CEX)',
      emoji:  '⏱️',
      what:   'How dealer delta hedges decay each day as time passes. '
              'Positive CEX = dealers accumulate long delta as each day passes. '
              'Negative CEX = dealers shed delta as each day passes.',
      decide: 'Positive CEX → expect intraday buy drift, especially near market close '
              'as dealers un-hedge. Bullish AM setups common. '
              'Negative CEX → expect selling pressure to build through the session; '
              'end-of-day weakness as hedges roll off. '
              'Strongest on days with many short-dated contracts near expiration.',
      color:  Color(0xFFFBBF24),
    ),
    _GlossaryEntry(
      term:   'Volga (Vomma)',
      emoji:  '🌊',
      what:   'How sensitive vega is to changes in IV — the "vol of vol" Greek. '
              'High Volga = options pricing is very sensitive to changes in IV itself. '
              'This drives the "smile" effect — OTM options bid up relative to ATM.',
      decide: 'Positive dealer Volga → dealers are short vol convexity. '
              'They will bid up wings (OTM options) to hedge → skew steepens around catalysts. '
              'Buy OTM options before known catalysts in high-Volga regimes. '
              'Negative dealer Volga → wings stay cheap. '
              'Sell OTM options / use credit spreads in this environment.',
      color:  Color(0xFF60A5FA),
    ),
    _GlossaryEntry(
      term:   'Put/Call OI Ratio',
      emoji:  '⚖️',
      what:   'Total put open interest divided by total call open interest across all strikes. '
              'Above 1.0 = more puts outstanding than calls. Below 1.0 = calls dominate.',
      decide: 'P/C > 1.3 → heavy put loading — either bearish bets or institutional hedging. '
              'If IV is also high, the hedging is real; if IV is low, it may be cheap protection. '
              'P/C < 0.7 → call-heavy OI — watch for gamma squeezes if price moves up. '
              'P/C near 1.0 → balanced — no strong directional signal from positioning.',
      color:  Color(0xFFA09FC8),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text(
                    'GREEK GLOSSARY & DECISION GUIDE',
                    style: TextStyle(
                      color:      AppTheme.neutralColor,
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AppTheme.neutralColor,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: AppTheme.borderColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: _entries.map((e) => _EntryCard(entry: e)).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GlossaryEntry {
  final String term;
  final String emoji;
  final String what;
  final String decide;
  final Color  color;
  const _GlossaryEntry({
    required this.term,
    required this.emoji,
    required this.what,
    required this.decide,
    required this.color,
  });
}

class _EntryCard extends StatelessWidget {
  final _GlossaryEntry entry;
  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(entry.emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(
                entry.term,
                style: TextStyle(
                  color:      entry.color,
                  fontSize:   13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _block(
            icon:  Icons.info_outline_rounded,
            label: 'What it means',
            text:  entry.what,
            color: AppTheme.neutralColor,
          ),
          const SizedBox(height: 6),
          _block(
            icon:  Icons.bolt_rounded,
            label: 'How to use it',
            text:  entry.decide,
            color: entry.color,
          ),
          const SizedBox(height: 4),
          const Divider(color: AppTheme.borderColor, height: 16),
        ],
      ),
    );
  }

  Widget _block({
    required IconData icon,
    required String   label,
    required String   text,
    required Color    color,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: TextStyle(
                      color:      color,
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text:  text,
                    style: const TextStyle(
                      color:   AppTheme.neutralColor,
                      fontSize: 11,
                      height:   1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}
