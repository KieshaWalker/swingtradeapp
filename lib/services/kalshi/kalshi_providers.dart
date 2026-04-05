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
  // Inflation / prices
  'cpi', 'pce', 'ppi', 'inflation', 'deflation', 'price index',

  // Energy & commodities
  'oil', 'crude', 'wti', 'brent', 'natural gas', 'gasoline',
  'gold', 'silver', 'copper', 'wheat', 'corn', 'commodity',

  // Labor market
  'unemployment', 'jobless', 'payroll', 'nfp', 'non-farm',
  'jolts', 'claims', 'jobs', 'labor', 'wages', 'earnings',
  'participation rate', 'layoff', 'hiring',

  // Growth / output
  'gdp', 'gross domestic', 'recession', 'expansion',
  'industrial production', 'capacity utilization',

  // Fed & monetary policy
  'fomc', 'federal reserve', 'fed funds', 'rate hike', 'rate cut',
  'interest rate', 'quantitative', 'balance sheet', 'powell',
  'monetary policy', 'basis point',

  // Housing
  'housing', 'home sales', 'home price', 'case-shiller',
  'existing home', 'new home', 'building permit', 'housing start',
  'mortgage', 'real estate', 'rent',

  // Retail & consumer
  'retail sales', 'consumer spending', 'consumer confidence',
  'consumer sentiment', 'university of michigan', 'conf board',
  'personal income', 'personal spending', 'credit card',

  // Manufacturing & services
  'manufacturing', 'ism', 'pmi', 'factory orders',
  'durable goods', 'industrial', 'services', 'business activity',

  // Trade & fiscal
  'trade deficit', 'trade balance', 'tariff', 'import', 'export',
  'current account', 'budget deficit', 'national debt', 'debt ceiling',
  'treasury', 'yield curve', 'inversion',

  // Market indices & volatility
  's&p', 'sp500', 'nasdaq', 'dow jones', 'russell',
  'vix', 'volatility', 'stocks', 'equity market',

  // Dollar & forex
  'dollar', 'dxy', 'dollar index', 'euro', 'yen', 'yuan',
  'currency', 'forex', 'exchange rate',

  // Credit & financial conditions
  'credit spread', 'high yield', 'investment grade', 'junk bond',
  'bank', 'lending', 'loan', 'delinquency', 'default',
];

bool _isMacroEvent(KalshiEvent e) {
  final haystack =
      '${e.seriesTicker ?? ''} ${e.title} ${e.category ?? ''}'.toLowerCase();
  return _macroKeywords.any((kw) => haystack.contains(kw));
}

// ── Events (with nested markets) ──────────────────────────────────────────────

/// Active macro events with yes/no market prices nested inside.
/// Filtered to CPI, gold, oil, unemployment, FOMC, GDP, etc.
/// This is the primary data source for sentiment and option overlays.
final kalshiMacroEventsProvider =
    FutureProvider<List<KalshiEvent>>((ref) async {
  final all = await KalshiService().getEvents(
    status: 'open',
    withNestedMarkets: true,
    limit: 200,
  );
  return all.where(_isMacroEvent).toList();
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
