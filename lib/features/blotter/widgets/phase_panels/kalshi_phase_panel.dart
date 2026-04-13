// =============================================================================
// features/blotter/widgets/phase_panels/kalshi_phase_panel.dart
// =============================================================================
// Phase 5 of 5 — Kalshi (Prediction Market) Gate
//
// Three-tier event filter:
//   Tier 1 — Ticker-specific  (event title contains the stock symbol)
//   Tier 1b — Sector-specific (oil → WTI/crude, gold → gold/dollar,
//                               SPY → S&P/FOMC/CPI, tech → Nasdaq/FOMC,
//                               financials → rate/FOMC, consumer → retail)
//   Tier 2 — Any macro event closing before the option's expiry date
//   Tier 3 — Catch-all context: all remaining events + highest probability
//
// Pass/Warn/Fail:
//   PASS  No tier 1/1b/2 events in window
//   WARN  Any tier 1/1b event OR any tier 2 event with 40–65% YES prob
//   FAIL  Tier 2 event ≥ 65% YES prob, OR multiple tier 2 events ≥ 50%,
//         OR tier 1 event ≥ 65% (direct price binary)
//
// Each event card explains in plain English:
//   • What the event is
//   • Why it matters to this specific trade (sector context)
//   • What the probability level means for risk
//   • Vol implication (high prob = priced in; uncertain = spike risk)
//
// Providers consumed:
//   kalshiMacroEventsProvider               — all open macro events
//   kalshiEventsForExpirationProvider(date) — tier 2 DTE-filtered
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme.dart';
import '../../../../services/kalshi/kalshi_models.dart';
import '../../../../services/kalshi/kalshi_providers.dart';
import '../../models/phase_result.dart';

// ── Sector classification ─────────────────────────────────────────────────────

enum _K5Sector { oil, gold, broadIndex, ratesSensitive, tech, consumer, other }

_K5Sector _classifySector(String ticker) {
  final t = ticker.toUpperCase();
  const oil = {'XOM','CVX','OXY','COP','SLB','HAL','USO','XLE','UCO','OIH',
      'DVN','MRO','VLO','PSX','MPC','FANG','EOG','HES','PXD','APA','BKR'};
  const gold = {'GLD','IAU','GOLD','NEM','AEM','RGLD','WPM','AGI','KGC',
      'FNV','GDX','GDXJ','SLV','PSLV','AG'};
  const index = {'SPY','SPX','IWM','DIA','MDY','VXX','VIXY','UVXY','SVXY'};
  const rates = {'JPM','BAC','GS','MS','WFC','C','USB','PNC','TFC','BRK','BRKB',
      'KRE','XLF','TLT','IEF','SHY','XLU','O','AMT','SCHW','BX','KKR'};
  const tech = {'AAPL','MSFT','GOOGL','GOOG','META','NVDA','AMD','TSM','AVGO',
      'ORCL','CRM','ADBE','QCOM','QQQ','XLK','SMH','SOXX','INTC','MU','AMAT'};
  const consumer = {'AMZN','WMT','TGT','COST','HD','LOW','XRT','XLP','XLY',
      'MCD','SBUX','NKE','TJX','ROST','DG','DLTR','LULU'};

  if (oil.contains(t))      return _K5Sector.oil;
  if (gold.contains(t))     return _K5Sector.gold;
  if (index.contains(t))    return _K5Sector.broadIndex;
  if (rates.contains(t))    return _K5Sector.ratesSensitive;
  if (tech.contains(t))     return _K5Sector.tech;
  if (consumer.contains(t)) return _K5Sector.consumer;
  return _K5Sector.other;
}

// ── Sector keyword sets for event matching ────────────────────────────────────

const _sectorEventKeywords = <_K5Sector, List<String>>{
  _K5Sector.oil: [
    'kxwti', 'wti', 'crude', 'oil', 'brent', 'petroleum',
    'natural gas', 'kxng', 'opec', 'energy', 'gasoline',
  ],
  _K5Sector.gold: [
    'kxgold', 'gold', 'silver', 'precious metal',
    'dxy', 'dollar index', 'dollar strength',
    // Gold is rate-sensitive — match all Fed/inflation events
    'kxfedrate', 'kxfomc', 'kxfedcombo', 'fomc', 'fed rate', 'fed combo',
    'rate hike', 'rate cut', 'dot plot', 'kxdotplot', 'ratecutcount',
    'cpi', 'kxcpi', 'kxcorecpi', 'inflation', 'pce', 'kxpce',
  ],
  _K5Sector.broadIndex: [
    'inxd', 'kxinxw', 'kxinxy', 's&p', 'sp500', 'spx', 'sp 500',
    'kxnasdaq100', 'nasdaq', 'djia', 'dow', 'russell', 'kxrussell',
    // Index reacts to all macro
    'kxfomc', 'kxfedcombo', 'fomc', 'fed combo', 'dot plot', 'kxdotplot',
    'ratecutcount', 'kxcpi', 'cpi', 'kxnfp', 'nfp', 'payroll',
    'kxrecession', 'recession', 'gdp', 'kxgdp',
  ],
  _K5Sector.ratesSensitive: [
    'kxfedrate', 'kxfomc', 'kxfedcombo', 'fomc', 'fed rate', 'fed combo',
    'federal reserve', 'rate hike', 'rate cut', 'monetary policy',
    'basis point', 'dot plot', 'kxdotplot', 'ratecutcount',
    'kxcpi', 'cpi', 'kxcorecpi', 'inflation',
    'kxpce', 'pce', 'yield curve', 'treasury', 'kxjolts',
  ],
  _K5Sector.tech: [
    'kxnasdaq100', 'nasdaq', 'kxinxw',
    'kxfedrate', 'kxfedcombo', 'fomc', 'fed combo',
    'rate cut', 'rate hike', 'dot plot', 'kxdotplot',
    'ai', 'semiconductor', 'chip',
  ],
  _K5Sector.consumer: [
    'kxretail', 'retail', 'consumer spending', 'consumer confidence',
    'kxcpi', 'cpi', 'inflation', 'kxnfp', 'jobs', 'unemployment',
    'kxunemployment', 'personal income', 'credit',
    'kxgdp', 'gdp', // recession risk drives consumer
  ],
  _K5Sector.other: [
    'kxfomc', 'kxfedcombo', 'fomc', 'fed combo', 'dot plot', 'kxdotplot',
    'kxcpi', 'cpi', 'kxnfp', 'nfp', 'kxrecession', 'kxgdp', 'gdp',
  ],
};

// ── Sector impact explanation ─────────────────────────────────────────────────

String _sectorImpact(_K5Sector sector, bool isCall) {
  switch (sector) {
    case _K5Sector.oil:
      return isCall
          ? 'Oil calls benefit when WTI/crude prices rise. OPEC decisions, '
            'EIA inventory surprises, and geopolitical risk directly move energy stocks. '
            'A hawkish Fed (rate hike) typically pressures demand and is bearish oil.'
          : 'Oil puts benefit when crude falls. Dollar strength, demand slowdown '
            '(recession events), or unexpected inventory builds are the primary drivers. '
            'Watch WTI level events closely — they directly gate oil stock direction.';

    case _K5Sector.gold:
      return isCall
          ? 'Gold calls benefit from dollar weakness, falling real rates (inflation UP or rates DOWN), '
            'or geopolitical risk spikes. A Fed rate cut (YES resolves) → real rates fall → gold bullish. '
            'Higher CPI (YES) → real rates compressed → gold bullish.'
          : 'Gold puts benefit from dollar strength or rising real rates. '
            'A Fed hike or rate-hold surprise tightens real rates → gold bearish. '
            'Lower-than-expected CPI → real rates rise → gold under pressure.';

    case _K5Sector.broadIndex:
      return isCall
          ? 'SPY/index calls benefit from risk-on sentiment. FOMC rate cuts, '
            'strong NFP, or below-consensus CPI are SPY bullish. '
            'Binary resolution of high-confidence events removes uncertainty → vol crush → '
            'index can melt up if macro is confirmed positive.'
          : 'SPY/index puts benefit from risk-off events. A surprise rate hike, '
            'hot CPI print, weak GDP, or recession probability spike are the main triggers. '
            'Stacked macro events with uncertain outcomes maximize vol spike potential.';

    case _K5Sector.ratesSensitive:
      return isCall
          ? 'Financials (banks, REITs, utilities) are rate-sensitive. '
            'A rate cut (YES) steepens the yield curve → bank NIM expands → bullish. '
            'FOMC outcomes directly reprice the entire sector in one session.'
          : 'Rate hikes (YES on hike events) compress bank spreads and pressure '
            'rate-sensitive sectors. Watch for unexpected Fed hawkishness — '
            'even a hold vs expected cut is bearish for this sector.';

    case _K5Sector.tech:
      return isCall
          ? 'Tech valuations are duration assets — they benefit from rate cuts. '
            'A Fed cut (YES) → lower discount rates → tech multiple expansion. '
            'Strong Nasdaq events reinforce momentum. '
            'Uncertain FOMC outcomes increase vol and can whipsaw growth stocks.'
          : 'Rate hikes (YES on hike events) compress tech multiples quickly. '
            'Weak macro (recession, weak NFP) can also pressure risk assets. '
            'Tech puts benefit most from rate surprises — biggest single-session risk.';

    case _K5Sector.consumer:
      return isCall
          ? 'Consumer discretionary calls benefit from strong jobs data (NFP), '
            'cooling inflation (lower CPI), and personal income growth. '
            'Positive retail sales events directly confirm consumer health.'
          : 'Consumer puts work when unemployment rises (YES on high unemployment events), '
            'inflation stays hot (eroding purchasing power), or retail misses. '
            'Recession probability events are the most directly correlated to consumer puts.';

    case _K5Sector.other:
      return isCall
          ? 'Watch for FOMC rate decisions and macro data releases within your hold window. '
            'Any binary event with >50% probability is priced into the current IV — '
            'post-resolution vol crush will hurt your long premium position.'
          : 'Binary events with uncertain outcomes can spike realized vol — '
            'potentially beneficial for long put positions. '
            'High-confidence events (>65%) are already priced in and may not deliver the move.';
  }
}

// ── Event impact text per event type ─────────────────────────────────────────

String _eventImpact(KalshiEvent event, _K5Sector sector, bool isCall) {
  final haystack = '${event.title} ${event.seriesTicker ?? ''}'.toLowerCase();

  if (haystack.contains('fomc') || haystack.contains('fed rate') ||
      haystack.contains('federal reserve') || haystack.contains('rate cut') ||
      haystack.contains('rate hike') || haystack.contains('kxfedrate') ||
      haystack.contains('kxfomc') || haystack.contains('kxfedcombo') ||
      haystack.contains('fed combo')) {
    return isCall
        ? 'Fed rate cut (YES) → lower discount rates → bullish risk assets. '
          'Hold (NO) → status quo — market may be disappointed if cut was expected.'
        : 'Rate hike or hawkish hold (NO on cut) → higher real rates → risk assets pressured. '
          'Unexpected tightening is the biggest single-session risk for puts in this cycle.';
  }

  if (haystack.contains('dot plot') || haystack.contains('kxdotplot') ||
      haystack.contains('median dot')) {
    return isCall
        ? 'Dot plot shows projected rate path. Fewer cuts projected (hawkish shift) → '
          'higher long-term rates → risk assets pressured. More cuts (dovish shift) → bullish. '
          'Dot plot surprises are often more impactful than the rate decision itself.'
        : 'A hawkish dot plot revision (fewer cuts) raises the long-end of the yield curve → '
          'rate-sensitive sectors reprice down. This is one of the most underappreciated '
          'vol catalysts — often triggers multi-day repricing across asset classes.';
  }

  if (haystack.contains('cpi') || haystack.contains('inflation') ||
      haystack.contains('pce') || haystack.contains('price index')) {
    return (sector == _K5Sector.gold)
        ? 'Hot CPI (YES) → real rates fall → gold/commodities bullish. '
          'Cool CPI (NO) → real rates rise → gold pressured.'
        : isCall
            ? 'Below-consensus CPI (NO on hot inflation) → risk assets rally. '
              'Hot print (YES) → forces Fed hawkishness → risk-off.'
            : 'Hot CPI (YES) → Fed hawks → risk assets sell. '
              'Cool print → removes put thesis. Direction depends on consensus vs actual.';
  }

  if (haystack.contains('nfp') || haystack.contains('payroll') ||
      haystack.contains('jobs') || haystack.contains('unemployment')) {
    return isCall
        ? 'Strong jobs (YES on high NFP) → soft landing confirmed → risk-on, SPY bullish. '
          'Weak jobs → fear of recession → flight to quality.'
        : 'Weak jobs (NO on strong NFP) → recession fear → puts benefit. '
          'But a too-hot jobs report can be hawkish → also bearish for risk assets.';
  }

  if (haystack.contains('wti') || haystack.contains('crude') ||
      haystack.contains('oil') || haystack.contains('brent')) {
    return isCall
        ? 'WTI above level (YES) → oil/energy stocks rally. '
          'Watch whether this resolves before your expiry — it directly gates oil stock direction.'
        : 'WTI below level (NO on bull event) → oil/energy stocks decline. '
          'Inventory builds or demand destruction are the typical triggers.';
  }

  if (haystack.contains('gold') || haystack.contains('kxgold')) {
    return isCall
        ? 'Gold above level (YES) → precious metal and miner stocks rally. '
          'Gold is driven by real rates and dollar — watch FOMC as the secondary driver.'
        : 'Gold below level (NO) → dollar strengthening or rate expectations hawkish. '
          'Miners amplify gold moves with operating leverage.';
  }

  if (haystack.contains('s&p') || haystack.contains('sp500') ||
      haystack.contains('inxd') || haystack.contains('nasdaq')) {
    return isCall
        ? 'Index above level (YES) → direct confirmation of your bull thesis. '
          'This binary resolves the market direction question explicitly.'
        : 'Index below level (NO on bull event) → direct support for puts. '
          'These level events are the most direct Kalshi signal for directional trades.';
  }

  if (haystack.contains('recession') || haystack.contains('gdp')) {
    return isCall
        ? 'Recession probability rising (YES) → risk assets sell across the board. '
          'This is a tail-risk event — even moderate probability warrants caution on calls.'
        : 'Recession (YES) → puts benefit broadly. '
          'GDP contraction events have the largest cross-asset impact.';
  }

  // Generic
  return 'This event resolves a macro variable that can reprice risk assets. '
      'High probability (>65%) means the market has already moved to price it in — '
      'post-resolution vol crush is the primary risk to long premium.';
}

// ── Probability helpers ───────────────────────────────────────────────────────

String _probLabel(double p) {
  if (p >= 0.75) return 'Very High Confidence';
  if (p >= 0.65) return 'High Confidence';
  if (p >= 0.50) return 'Likely YES';
  if (p >= 0.40) return 'Uncertain (coin flip)';
  if (p >= 0.25) return 'Leaning NO';
  return 'Very Low YES Probability';
}

String _probRisk(double p, bool isCall) {
  if (p >= 0.65) {
    return 'Market has conviction (${(p * 100).toStringAsFixed(0)}%). '
        'The event outcome is largely priced in — post-resolution vol crush will compress premium. '
        'Avoid buying premium that depends on this catalyst to move the underlying.';
  }
  if (p >= 0.40) {
    return 'Uncertain outcome (${(p * 100).toStringAsFixed(0)}%). '
        'Either resolution is plausible — the event can spike vol in either direction. '
        'Position sizing should be reduced, or use defined-risk structure.';
  }
  return 'Low YES probability (${(p * 100).toStringAsFixed(0)}%). '
      'Market expects NO — surprise YES would be the shock scenario. '
      'Low but non-zero tail risk.';
}

// ── Filtered event groups ─────────────────────────────────────────────────────

class _FilteredEvents {
  final List<KalshiEvent> tier1Ticker;   // event title contains stock symbol
  final List<KalshiEvent> tier1bSector;  // sector-matched keywords in DTE window
  final List<KalshiEvent> tier2Macro;    // any macro event in DTE window (deduped)
  final int               tier3Count;
  final KalshiEvent?      tier3Top;

  const _FilteredEvents({
    required this.tier1Ticker,
    required this.tier1bSector,
    required this.tier2Macro,
    required this.tier3Count,
    this.tier3Top,
  });

  bool get hasRelevant =>
      tier1Ticker.isNotEmpty || tier1bSector.isNotEmpty || tier2Macro.isNotEmpty;
}

_FilteredEvents _filterEvents({
  required List<KalshiEvent> all,       // kalshiMacroEventsProvider
  required List<KalshiEvent> inWindow,  // kalshiEventsForExpirationProvider
  required String ticker,
  required _K5Sector sector,
}) {
  final t = ticker.toUpperCase();

  // Tier 1: title contains the stock ticker
  final tier1 = all.where((e) {
    final h = e.title.toUpperCase();
    return h.contains(t) || h.contains(_tickerToName(t));
  }).toList();

  // Sector keywords
  final sectorKws = _sectorEventKeywords[sector] ?? [];

  // Tier 1b: sector-specific events in window
  final tier1bIds = <String>{};
  final tier1b = inWindow.where((e) {
    final h = '${e.title} ${e.seriesTicker ?? ''} ${e.category ?? ''}'
        .toLowerCase();
    final match = sectorKws.any((kw) => h.contains(kw));
    if (match) tier1bIds.add(e.eventTicker);
    return match;
  }).toList();

  // Tier 2: remaining macro events in window (not already in tier 1b)
  final tier2 = inWindow
      .where((e) => !tier1bIds.contains(e.eventTicker))
      .toList();

  // Sort by probability desc
  tier1b.sort((a, b) => (b.leadingMarket?.yesProbability ?? 0)
      .compareTo(a.leadingMarket?.yesProbability ?? 0));
  tier2.sort((a, b) => (b.leadingMarket?.yesProbability ?? 0)
      .compareTo(a.leadingMarket?.yesProbability ?? 0));

  // Tier 3: all events not in window, find the highest probability one
  final inWindowIds = inWindow.map((e) => e.eventTicker).toSet();
  final tier3Events = all
      .where((e) => !inWindowIds.contains(e.eventTicker))
      .toList()
    ..sort((a, b) => (b.leadingMarket?.yesProbability ?? 0)
        .compareTo(a.leadingMarket?.yesProbability ?? 0));

  return _FilteredEvents(
    tier1Ticker:  tier1,
    tier1bSector: tier1b,
    tier2Macro:   tier2,
    tier3Count:   tier3Events.length,
    tier3Top:     tier3Events.firstOrNull,
  );
}

String _tickerToName(String t) {
  const names = {
    'AAPL': 'APPLE', 'MSFT': 'MICROSOFT', 'GOOGL': 'GOOGLE', 'GOOG': 'GOOGLE',
    'AMZN': 'AMAZON', 'META': 'META', 'NVDA': 'NVIDIA', 'TSLA': 'TESLA',
    'JPM': 'JPMORGAN', 'BAC': 'BANK OF AMERICA', 'GS': 'GOLDMAN',
    'XOM': 'EXXON', 'CVX': 'CHEVRON', 'OXY': 'OCCIDENTAL',
  };
  return names[t] ?? t;
}

// ── Phase result ──────────────────────────────────────────────────────────────

PhaseResult _toPhaseResult(_FilteredEvents f, _K5Sector sector, bool isCall) {
  final signals  = <String>[];
  final warnings = <String>[];

  if (!f.hasRelevant) {
    return PhaseResult(
      status:   PhaseStatus.pass,
      headline: 'Pass — no binary events in DTE window',
      signals:  [
        'No Kalshi events (tier 1, sector, or macro) resolve within your hold period.',
        'Prediction markets show no high-confidence binary risk for this trade.',
        if (f.tier3Count > 0)
          '${f.tier3Count} open events outside your window — no direct DTE overlap.',
      ],
      reviewed: false,
    );
  }

  // Count high-conviction events
  final allRelevant = [...f.tier1Ticker, ...f.tier1bSector, ...f.tier2Macro];
  final highConf  = allRelevant.where(
      (e) => (e.leadingMarket?.yesProbability ?? 0) >= 0.65).toList();
  final uncertain = allRelevant.where(
      (e) {
        final p = e.leadingMarket?.yesProbability ?? 0;
        return p >= 0.40 && p < 0.65;
      }).toList();

  if (f.tier1Ticker.isNotEmpty) {
    warnings.add('Ticker-specific event found — prediction market is pricing a direct '
        'outcome for ${f.tier1Ticker.first.title.split(' ').first}');
  }

  for (final e in f.tier1bSector.take(3)) {
    final p = e.leadingMarket?.yesProbability;
    if (p != null) {
      signals.add('${e.title}  ·  ${(p * 100).toStringAsFixed(0)}% YES  '
          '[${_probLabel(p)}]');
    }
  }
  for (final e in f.tier2Macro.take(3)) {
    final p = e.leadingMarket?.yesProbability;
    if (p != null) {
      signals.add('${e.title}  ·  ${(p * 100).toStringAsFixed(0)}% YES  '
          '[${_probLabel(p)}]');
    }
  }

  // Status
  final PhaseStatus status;
  final String headline;
  final bool stackedRisk = uncertain.length >= 2 || highConf.length >= 2;

  if (highConf.isNotEmpty || stackedRisk) {
    status   = PhaseStatus.fail;
    headline = highConf.isNotEmpty
        ? 'Fail — ${highConf.first.title.split(' ').take(5).join(' ')} '
          '${((highConf.first.leadingMarket?.yesProbability ?? 0) * 100).toStringAsFixed(0)}% — '
          'high-confidence binary in window'
        : 'Fail — ${uncertain.length} stacked uncertain events in window';
  } else if (f.tier1Ticker.isNotEmpty || uncertain.isNotEmpty) {
    status   = PhaseStatus.warn;
    headline = f.tier1Ticker.isNotEmpty
        ? 'Warn — ticker-specific event in window'
        : 'Warn — ${uncertain.length} uncertain binary event${uncertain.length > 1 ? 's' : ''} in window';
  } else {
    status   = PhaseStatus.pass;
    headline = 'Pass — events present but low probability (< 40%)';
  }

  return PhaseResult(
    status:   status,
    headline: headline,
    signals:  [...signals, ...warnings.map((w) => '⚠ $w')],
    reviewed: false,
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Public widget
// ═══════════════════════════════════════════════════════════════════════════════

class KalshiPhasePanel extends ConsumerStatefulWidget {
  final String   ticker;
  final DateTime expiryDate;
  final bool     isCall;
  final void Function(PhaseResult) onResult;

  const KalshiPhasePanel({
    super.key,
    required this.ticker,
    required this.expiryDate,
    required this.isCall,
    required this.onResult,
  });

  @override
  ConsumerState<KalshiPhasePanel> createState() => _KalshiPhasePanelState();
}

class _KalshiPhasePanelState extends ConsumerState<KalshiPhasePanel> {
  PhaseResult? _last;

  void _notifyIfChanged(PhaseResult r) {
    if (_last?.status == r.status && _last?.headline == r.headline) return;
    _last = r;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onResult(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final allAsync    = ref.watch(kalshiMacroEventsProvider);
    final windowAsync = ref.watch(
        kalshiEventsForExpirationProvider(widget.expiryDate));

    final sector = _classifySector(widget.ticker);

    // Show loading if either is loading
    if (allAsync.isLoading || windowAsync.isLoading) {
      _notifyIfChanged(PhaseResult.none);
      return const _LoadingTile();
    }

    if (allAsync.hasError) {
      final r = PhaseResult(
        status: PhaseStatus.warn,
        headline: 'Kalshi data unavailable',
        signals: ['Check API key — ${allAsync.error}'],
        reviewed: false,
      );
      _notifyIfChanged(r);
      return _ErrorTile(message: allAsync.error.toString());
    }

    final all      = allAsync.valueOrNull ?? [];
    final inWindow = windowAsync.valueOrNull ?? [];

    final filtered = _filterEvents(
      all:      all,
      inWindow: inWindow,
      ticker:   widget.ticker,
      sector:   sector,
    );

    final result = _toPhaseResult(filtered, sector, widget.isCall);
    _notifyIfChanged(result);

    return _PanelBody(
      filtered: filtered,
      result:   result,
      ticker:   widget.ticker,
      sector:   sector,
      isCall:   widget.isCall,
      dte:      widget.expiryDate.difference(DateTime.now()).inDays,
    );
  }
}

// ── Loading / error tiles ─────────────────────────────────────────────────────

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
  );
}

class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Kalshi unavailable',
            style: TextStyle(color: Color(0xFFFBBF24), fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(message,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 10),
        const Text(
          'Prediction market data requires a valid Kalshi API key. '
          'This phase will be marked WARN (unreviewed) until data is available.',
          style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4)),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Panel body
// ═══════════════════════════════════════════════════════════════════════════════

class _PanelBody extends StatelessWidget {
  final _FilteredEvents filtered;
  final PhaseResult     result;
  final String          ticker;
  final _K5Sector       sector;
  final bool            isCall;
  final int             dte;

  const _PanelBody({
    required this.filtered,
    required this.result,
    required this.ticker,
    required this.sector,
    required this.isCall,
    required this.dte,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Status header ─────────────────────────────────────────────────
          _StatusHeader(result: result),
          const SizedBox(height: 12),

          // ── Sector context ────────────────────────────────────────────────
          _SectorContextCard(
            ticker: ticker,
            sector: sector,
            isCall: isCall,
          ),
          const SizedBox(height: 14),

          // ── Tier 1: ticker-specific events ────────────────────────────────
          if (filtered.tier1Ticker.isNotEmpty) ...[
            _SectionLabel('Ticker Events  ($ticker)'),
            const SizedBox(height: 6),
            ...filtered.tier1Ticker.map((e) => _EventCard(
              event:  e,
              badge:  'TICKER',
              color:  AppTheme.lossColor,
              impact: _eventImpact(e, sector, isCall),
              probRisk: _probRisk(
                  e.leadingMarket?.yesProbability ?? 0, isCall),
            )),
            const SizedBox(height: 14),
          ],

          // ── Tier 1b: sector-specific events ───────────────────────────────
          if (filtered.tier1bSector.isNotEmpty) ...[
            _SectionLabel(_sectorLabel(sector)),
            const SizedBox(height: 6),
            ...filtered.tier1bSector.take(4).map((e) => _EventCard(
              event:  e,
              badge:  'SECTOR',
              color:  const Color(0xFFFBBF24),
              impact: _eventImpact(e, sector, isCall),
              probRisk: _probRisk(
                  e.leadingMarket?.yesProbability ?? 0, isCall),
            )),
            const SizedBox(height: 14),
          ],

          // ── Tier 2: remaining macro events in window ──────────────────────
          if (filtered.tier2Macro.isNotEmpty) ...[
            _SectionLabel('Other Macro in Window'),
            const SizedBox(height: 6),
            ...filtered.tier2Macro.take(3).map((e) => _EventCard(
              event:  e,
              badge:  'MACRO',
              color:  AppTheme.neutralColor,
              impact: _eventImpact(e, sector, isCall),
              probRisk: _probRisk(
                  e.leadingMarket?.yesProbability ?? 0, isCall),
            )),
            const SizedBox(height: 14),
          ],

          // ── No relevant events ────────────────────────────────────────────
          if (!filtered.hasRelevant) ...[
            _PassCard(tier3Count: filtered.tier3Count, top: filtered.tier3Top),
            const SizedBox(height: 14),
          ],

          // ── Tier 3 catch-all ──────────────────────────────────────────────
          if (filtered.tier3Count > 0 && filtered.hasRelevant)
            _Tier3Summary(count: filtered.tier3Count, top: filtered.tier3Top),

          const SizedBox(height: 8),

          // ── Deep link ─────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/economy'),
              icon:  const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('Full Kalshi Screen →',
                  style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.neutralColor,
                side:            const BorderSide(color: AppTheme.borderColor),
                minimumSize:     const Size.fromHeight(38),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sectorLabel(_K5Sector s) {
    switch (s) {
      case _K5Sector.oil:            return 'Oil & Energy Events in Window';
      case _K5Sector.gold:           return 'Gold / Rate Events in Window';
      case _K5Sector.broadIndex:     return 'Index & Macro Events in Window';
      case _K5Sector.ratesSensitive: return 'Rate / Fed Events in Window';
      case _K5Sector.tech:           return 'Tech / Rate Events in Window';
      case _K5Sector.consumer:       return 'Consumer / Jobs Events in Window';
      case _K5Sector.other:          return 'Relevant Macro Events in Window';
    }
  }
}

// ── Status header ─────────────────────────────────────────────────────────────

class _StatusHeader extends StatelessWidget {
  final PhaseResult result;
  const _StatusHeader({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.status.color;
    return Row(
      children: [
        Icon(result.status.icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(result.headline,
              style: TextStyle(color: color, fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:        color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(result.status.label.toUpperCase(),
              style: TextStyle(color: color, fontSize: 10,
                  fontWeight: FontWeight.w800, letterSpacing: 0.8)),
        ),
      ],
    );
  }
}

// ── Sector context card ───────────────────────────────────────────────────────

class _SectorContextCard extends StatelessWidget {
  final String    ticker;
  final _K5Sector sector;
  final bool      isCall;
  const _SectorContextCard({
    required this.ticker,
    required this.sector,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 13, color: AppTheme.neutralColor),
              const SizedBox(width: 6),
              Text(
                '${_sectorName(sector)} ·  ${isCall ? 'Long Call' : 'Long Put'}',
                style: const TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _sectorImpact(sector, isCall),
            style: const TextStyle(
                color: Colors.white60, fontSize: 11, height: 1.45),
          ),
        ],
      ),
    );
  }

  String _sectorName(_K5Sector s) => switch (s) {
    _K5Sector.oil            => 'Oil & Energy',
    _K5Sector.gold           => 'Gold & Precious Metals',
    _K5Sector.broadIndex     => 'Broad Index',
    _K5Sector.ratesSensitive => 'Rate-Sensitive',
    _K5Sector.tech           => 'Technology',
    _K5Sector.consumer       => 'Consumer',
    _K5Sector.other          => 'General',
  };
}

// ── Event card ────────────────────────────────────────────────────────────────

class _EventCard extends StatefulWidget {
  final KalshiEvent event;
  final String      badge;
  final Color       color;
  final String      impact;
  final String      probRisk;

  const _EventCard({
    required this.event,
    required this.badge,
    required this.color,
    required this.impact,
    required this.probRisk,
  });

  @override
  State<_EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<_EventCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e       = widget.event;
    final market  = e.leadingMarket;
    final prob    = market?.yesProbability;
    final closeDate = e.closeDateTime;

    final Color probColor;
    if (prob == null) {
      probColor = AppTheme.neutralColor;
    } else if (prob >= 0.65) {
      probColor = AppTheme.lossColor;
    } else if (prob >= 0.40) {
      probColor = const Color(0xFFFBBF24);
    } else {
      probColor = AppTheme.profitColor;
    }

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(9),
          border:       Border.all(
              color: prob != null && prob >= 0.65
                  ? widget.color.withValues(alpha: 0.35)
                  : AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top row ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: widget.color.withValues(alpha: 0.4)),
                    ),
                    child: Text(widget.badge,
                        style: TextStyle(
                            color: widget.color, fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(e.title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.3)),
                  ),
                ],
              ),
            ),

            // ── Leading market title ──────────────────────────────────────
            if (market != null && market.title.isNotEmpty &&
                market.title != e.title)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 3, 12, 0),
                child: Text(
                  '"${market.title}"',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11,
                      fontStyle: FontStyle.italic),
                ),
              ),

            // ── Probability bar ───────────────────────────────────────────
            if (prob != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _ProbBar(prob: prob, color: probColor),
              ),
            ],

            // ── Stats row ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: _StatsRow(
                event:     e,
                market:    market,
                closeDate: closeDate,
                probColor: probColor,
              ),
            ),

            // ── Expandable detail ─────────────────────────────────────────
            AnimatedCrossFade(
              firstChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Row(
                  children: [
                    Text(
                      _expanded ? 'Less' : 'What does this mean? ↓',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailBlock(
                      title: 'Impact on your trade',
                      text:  widget.impact,
                      color: AppTheme.neutralColor,
                    ),
                    const SizedBox(height: 8),
                    _DetailBlock(
                      title: 'Probability risk',
                      text:  widget.probRisk,
                      color: probColor,
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = false),
                      child: const Text('← Less',
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 11)),
                    ),
                  ],
                ),
              ),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProbBar extends StatelessWidget {
  final double prob;
  final Color  color;
  const _ProbBar({required this.prob, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value:           prob.clamp(0.0, 1.0),
            minHeight:       7,
            backgroundColor: AppTheme.elevatedColor,
            valueColor:      AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text(
              '${(prob * 100).toStringAsFixed(0)}%  YES',
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace'),
            ),
            const SizedBox(width: 8),
            Text(
              _probLabel(prob),
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  final KalshiEvent  event;
  final KalshiMarket? market;
  final DateTime?    closeDate;
  final Color        probColor;
  const _StatsRow({
    required this.event,
    required this.market,
    required this.closeDate,
    required this.probColor,
  });

  @override
  Widget build(BuildContext context) {
    final yesAsk = market?.yesAsk;
    final noAsk  = market?.noAsk;
    final vol    = market?.volume;

    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        if (closeDate != null)
          _Stat(
            icon:  Icons.event_outlined,
            label: 'closes ${closeDate!.month}/${closeDate!.day}',
            color: AppTheme.neutralColor,
          ),
        if (yesAsk != null)
          _Stat(
            icon:  Icons.check_circle_outline_rounded,
            label: 'YES \$${yesAsk.toStringAsFixed(2)}',
            color: probColor,
          ),
        if (noAsk != null)
          _Stat(
            icon:  Icons.cancel_outlined,
            label: 'NO \$${noAsk.toStringAsFixed(2)}',
            color: AppTheme.neutralColor,
          ),
        if (vol != null)
          _Stat(
            icon:  Icons.bar_chart_rounded,
            label: 'vol ${_fmtK(vol)}',
            color: AppTheme.neutralColor,
          ),
        if (event.category != null)
          _Stat(
            icon:  Icons.category_outlined,
            label: event.category!,
            color: AppTheme.neutralColor,
          ),
      ],
    );
  }

  static String _fmtK(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(0)}K';
    return '$v';
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _Stat({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 3),
      Text(label,
          style: TextStyle(color: color, fontSize: 10,
              fontFamily: 'monospace')),
    ],
  );
}

class _DetailBlock extends StatelessWidget {
  final String title;
  final String text;
  final Color  color;
  const _DetailBlock({
    required this.title,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title.toUpperCase(),
          style: TextStyle(
              color:         color,
              fontSize:      9,
              fontWeight:    FontWeight.w700,
              letterSpacing: 0.8)),
      const SizedBox(height: 3),
      Text(text,
          style: const TextStyle(
              color: Colors.white60, fontSize: 11, height: 1.45)),
    ],
  );
}

// ── Pass card (no relevant events) ───────────────────────────────────────────

class _PassCard extends StatelessWidget {
  final int          tier3Count;
  final KalshiEvent? top;
  const _PassCard({required this.tier3Count, this.top});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(9),
        border:       Border.all(
            color: AppTheme.profitColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppTheme.profitColor),
              const SizedBox(width: 8),
              const Text('No binary events in your DTE window',
                  style: TextStyle(
                      color: AppTheme.profitColor,
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Prediction markets show no high-confidence binary events '
            'resolving before your option expires. '
            'There is no catalyst risk from Kalshi for this hold period.',
            style: TextStyle(
                color: Colors.white54, fontSize: 11, height: 1.4)),
          if (tier3Count > 0 && top != null) ...[
            const SizedBox(height: 8),
            Text(
              '$tier3Count open events outside window — '
              'highest probability: "${top!.title}" '
              '(${((top!.leadingMarket?.yesProbability ?? 0) * 100).toStringAsFixed(0)}% YES)',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10,
                  height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Tier 3 catch-all summary ──────────────────────────────────────────────────

class _Tier3Summary extends StatelessWidget {
  final int          count;
  final KalshiEvent? top;
  const _Tier3Summary({required this.count, this.top});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(7),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          const Icon(Icons.public_rounded,
              size: 13, color: AppTheme.neutralColor),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '$count other open events outside window'
              '${top != null ? ' · highest: "${top!.title}" '
                  '${((top!.leadingMarket?.yesProbability ?? 0) * 100).toStringAsFixed(0)}%' : ''}',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10,
                  height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
        color: AppTheme.neutralColor, fontSize: 10,
        fontWeight: FontWeight.w700, letterSpacing: 1.1),
  );
}
