// =============================================================================
// services/kalshi/kalshi_providers.dart
// =============================================================================
// Provider map:
//
//  kalshiSeriesProvider
//    FutureProvider<List<KalshiSeries>>
//    Fetches all series on app-load; cache for session.
//    Used by: Global Macro Alert panel (series browser).
//
//  kalshiMacroEventsProvider
//    FutureProvider<List<KalshiEvent>>
//    Active events with nested markets (yes/no prices).
//    Used by: Event Sentiment panel; options-chain overlay.
//
//  kalshiEventsForExpirationProvider
//    FutureProvider.family<List<KalshiEvent>, DateTime>
//    Filters kalshiMacroEventsProvider down to events whose close_time
//    falls before a given option expiration date.
//    Used by: OptionsChainScreen to highlight High Volatility Events.
//
//  kalshiLiveOddsProvider
//    StreamProvider.family<KalshiTickerUpdate, String>
//    Opens a WebSocket to Kalshi and streams real-time price ticks
//    for a single market ticker.
//    Used by: Probability Meter widget on any screen watching one market.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'kalshi_models.dart';
import 'kalshi_service.dart';

// ── Series ────────────────────────────────────────────────────────────────────

/// All Kalshi series (FOMC, CPI, NFP, earnings seasons, sports, etc.).
/// Stable enough to keep for the lifetime of the session.
final kalshiSeriesProvider = FutureProvider<List<KalshiSeries>>((ref) async {
  return KalshiService().getSeries(limit: 200);
});

// ── Macro keyword filter ──────────────────────────────────────────────────────

/// Series tickers and title keywords that are relevant to macro / market traders.
/// Matched case-insensitively against event.seriesTicker and event.title.
const _macroKeywords = [
  // ── Kalshi confirmed series tickers (matched on seriesTicker field) ──────
  // Financials
  'inxd',           // S&P 500 daily
  'kxinxy',         // S&P 500 yearly range
  'kxinxw',         // S&P 500 weekly
  'kxnasdaq100',    // Nasdaq 100
  'kxdjia',         // Dow Jones
  'kxrussell',      // Russell 2000
  'kxwti',          // WTI crude oil
  'kxgold',         // Gold
  'kxbtc',          // Bitcoin
  'kxfedrate',      // Fed funds rate level
  'ratecutcount',   // Number of rate cuts
  // Economics
  'kxcpi',          // CPI
  'kxcorecpi',      // Core CPI
  'kxpce',          // PCE / Core PCE
  'kxnfp',          // Nonfarm payrolls
  'kxunemployment', // Unemployment rate
  'kxjolts',        // JOLTS job openings
  'kxgdp',          // GDP growth
  'kxrecession',    // Recession probability
  'kxfomc',         // FOMC rate decision
  'kxppi',          // PPI
  'kxretail',       // Retail sales
  'kxsilver',       // Silver
  'kxng',           // Natural gas

  // ── Inflation / prices ───────────────────────────────────────────────────
  'cpi', 'pce', 'ppi', 'inflation', 'deflation', 'price index',

  // ── Energy & commodities ─────────────────────────────────────────────────
  'oil', 'crude', 'wti', 'brent', 'natural gas', 'gasoline',
  'gold', 'silver', 'copper', 'wheat', 'corn', 'commodity', 

  // ── Labor market ─────────────────────────────────────────────────────────
  'unemployment', 'jobless', 'payroll', 'nfp', 'non-farm',
  'jolts', 'claims', 'jobs', 'labor', 'wages', 'earnings',
  'participation rate', 'layoff', 'hiring',

  // ── Growth / output ──────────────────────────────────────────────────────
  'gdp', 'gross domestic', 'recession', 'expansion',
  'industrial production', 'capacity utilization',

  // ── Fed & monetary policy ─────────────────────────────────────────────────
  'fomc', 'federal reserve', 'fed funds', 'rate hike', 'rate cut',
  'interest rate', 'quantitative', 'balance sheet', 'powell',
  'monetary policy', 'basis point',
  'kxfedcombo', 'fed combo', 'kxdotplot', 'dot plot', 'median dot',
  'ratecutcount', 'kxfedratemin',

  // ── Housing ───────────────────────────────────────────────────────────────
  'housing', 'home sales', 'home price', 'case-shiller',
  'existing home', 'new home', 'building permit', 'housing start',
  'mortgage', 'real estate', 'rent',

  // ── Retail & consumer ────────────────────────────────────────────────────
  'retail sales', 'consumer spending', 'consumer confidence',
  'consumer sentiment', 'university of michigan', 'conf board',
  'personal income', 'personal spending', 'credit card',

  // ── Manufacturing & services ─────────────────────────────────────────────
  'manufacturing', 'ism', 'pmi', 'factory orders',
  'durable goods', 'industrial', 'services', 'business activity',

  // ── Trade & fiscal ───────────────────────────────────────────────────────
  'trade deficit', 'trade balance', 'tariff', 'import', 'export',
  'current account', 'budget deficit', 'national debt', 'debt ceiling',
  'treasury', 'yield curve', 'inversion',

  // ── Market indices & volatility ──────────────────────────────────────────
  's&p', 's&p 500', 'sp500', 'spx', 'sp 500',
  'nasdaq', 'ndx', 'qqq',
  'dow', 'djia', 'dow jones', 'russell', 'iwm',
  'bitcoin', 'btc', 'crypto',
  'vix', 'volatility', 'stocks', 'equity market', 

  // ── Dollar & forex ───────────────────────────────────────────────────────
  'dollar', 'dxy', 'dollar index', 'euro', 'yen', 'yuan',
  'currency', 'forex', 'exchange rate',

  // ── Credit & financial conditions ────────────────────────────────────────
  'credit spread', 'high yield', 'investment grade', 'junk bond',
  'bank', 'lending', 'loan', 'delinquency', 'default',
];

bool _isMacroEvent(KalshiEvent e) {
  final haystack =
      '${e.seriesTicker ?? ''} ${e.title} ${e.category ?? ''}'.toLowerCase();
  return _macroKeywords.any((kw) => haystack.contains(kw));
}

// ── Known financial series tickers ────────────────────────────────────────────
// Queried in parallel rather than relying on the bulk /events endpoint.
// The Kalshi API sorts bulk events by internal ID (long-term events like
// "Elon Mars 2099" appear first), so a limit:200 bulk fetch reliably misses
// near-term macro events.  Querying specific series fixes this.

const _macroSeriesTickers = [
  // ── Economic indicators ────────────────────────────────────────────────────
  'KXCPI',          // CPI monthly
  'KXCORECPI',      // Core CPI
  'KXPCE',          // PCE / Core PCE
  'KXPPI',          // PPI
  'KXNFP',          // Nonfarm Payrolls
  'KXUNEMPLOYMENT', // Unemployment rate
  'KXJOLTS',        // JOLTS job openings
  'KXRETAIL',       // Retail sales
  'KXGDP',          // US GDP growth
  'KXRECESSION',    // Recession probability
  'KXQRECESS',      // Recession start
  // ── Fed / rates ────────────────────────────────────────────────────────────
  'KXFEDRATE',      // Fed funds rate level
  'KXFEDCOMBO',     // Fed combo (rate + statement)
  'KXDOTPLOT',      // Fed dot plot
  'KXFEDRATEMIN',   // How low will the Fed rate go
  'RATECUTCOUNT',   // Number of rate cuts
  // ── Commodities ────────────────────────────────────────────────────────────
  'KXWTI',          // WTI crude oil price
  'KXGOLD',         // Gold price
  'KXSILVER',       // Silver price
  'KXNG',           // Natural gas
  'KXWTIMIN',         // WTI yearly low
  'KXSPRLVL',       // Strategic Petroleum Reserve level
  'KXBRENTMON',    // Brent monthly (nearest contract, not the front-month futures) 
  // ── Equity indices ─────────────────────────────────────────────────────────
  'INXD',           // S&P 500 daily
  'KXINXW',         // S&P 500 weekly range
  'KXINXY',         // S&P 500 yearly range
  'KXNASDAQ100',    // Nasdaq 100 range
  'KXDJIA',         // Dow Jones
  'KXRUSSELL',      // Russell 2000
  // ── Crypto ─────────────────────────────────────────────────────────────────
  'KXBTC',          // Bitcoin range
];

// ── Events (with nested markets) ──────────────────────────────────────────────

/// Active macro events with yes/no market prices nested inside.
///
/// Queries each known financial series in parallel rather than using the
/// bulk /events endpoint (which sorts by internal ID and puts long-dated
/// "Elon Mars 2099" events before near-term CPI/WTI events).
///
/// Falls back to keyword-filtered bulk fetch to catch any series not in
/// the static list.
final kalshiMacroEventsProvider =
    FutureProvider<List<KalshiEvent>>((ref) async {
  final svc = KalshiService();

  // 1. Parallel per-series queries for known macro series
  final seriesResults = await Future.wait(
    _macroSeriesTickers.map((ticker) async {
      try {
        return await svc.getEvents(
          seriesTicker:      ticker,
          status:            'open',
          withNestedMarkets: true,
          limit:             20, // each series rarely has >10 open events
        );
      } catch (_) {
        return <KalshiEvent>[];
      }
    }),
  );

  // 2. Keyword-filtered bulk fetch as a catch-all (first page only)
  List<KalshiEvent> bulkEvents = [];
  try {
    final all = await svc.getEvents(
      status:            'open',
      withNestedMarkets: true,
      limit:             200,
    );
    bulkEvents = all.where(_isMacroEvent).toList();
  } catch (_) {}

  // 3. Merge, deduplicate by eventTicker
  final seen   = <String>{};
  final merged = <KalshiEvent>[];

  for (final event in [...seriesResults.expand((b) => b), ...bulkEvents]) {
    if (seen.add(event.eventTicker)) {
      merged.add(event);
    }
  }

  // Sort by close_time ascending so nearest events appear first
  merged.sort((a, b) {
    final ca = a.closeDateTime;
    final cb = b.closeDateTime;
    if (ca == null && cb == null) return 0;
    if (ca == null) return 1;
    if (cb == null) return -1;
    return ca.compareTo(cb);
  });

  return merged;
});

// ── Events filtered by option expiration ──────────────────────────────────────

/// Returns events whose close_time falls before [expirationDate].
/// Keyed by the expiration DateTime so each expiration tab gets its own cache.
final kalshiEventsForExpirationProvider =
    FutureProvider.family<List<KalshiEvent>, DateTime>(
        (ref, expirationDate) async {
  final events = await ref.watch(kalshiMacroEventsProvider.future);
  return events
      .where((e) => e.closesBeforeExpiration(expirationDate))
      .toList();
});

// ── Live odds — WebSocket StreamProvider ──────────────────────────────────────

/// Streams real-time KalshiTickerUpdate for [marketTicker] via the
/// Kalshi WebSocket feed at wss://ws.kalshi.com/v2/websocket.
///
/// The stream reconnects automatically when the provider is re-watched.
/// Dispose is handled by Riverpod when no listeners remain.
final kalshiLiveOddsProvider =
    StreamProvider.family<KalshiTickerUpdate, String>((ref, marketTicker) {
  final controller = StreamController<KalshiTickerUpdate>();

  final uri = Uri.parse('wss://api.elections.kalshi.com/trade-api/v2/websocket');
  final channel = WebSocketChannel.connect(
    uri,
    protocols: null,
  );

  // Authenticate + subscribe after connection is established.
  // Kalshi WS auth is done via a subscribe message that includes the API key.
  channel.sink.add(jsonEncode({
    'id': 1,
    'cmd': 'subscribe',
    'params': {
      'channels': ['ticker'],
      'market_tickers': [marketTicker],
    },
  }));

  final sub = channel.stream.listen(
    (raw) {
      try {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        // Kalshi sends { type: "subscribed" } on success and
        // { type: "ticker", msg: { market_ticker, yes, ... } } for updates.
        if (msg['type'] == 'ticker') {
          final inner = msg['msg'] as Map<String, dynamic>? ?? msg;
          final update = KalshiTickerUpdate.fromJson(inner);
          if (update.marketTicker.isNotEmpty) {
            controller.add(update);
          }
        }
      } catch (_) {
        // Silently ignore unparseable frames.
      }
    },
    onError: controller.addError,
    onDone: controller.close,
    cancelOnError: false,
  );

  ref.onDispose(() {
    sub.cancel();
    channel.sink.close();
    controller.close();
  });

  return controller.stream;
});
