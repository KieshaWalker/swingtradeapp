// =============================================================================
// services/fmp/fmp_providers.dart — Riverpod providers for FMP data
// =============================================================================
// Providers & where they are watched:
//
//   fmpServiceProvider        — FmpService singleton; used by all providers below
//
//   quoteProvider(symbol)     → TradeDetailScreen: _LiveQuoteCard (live price card)
//                             → DashboardScreen:   _OpenTradeRow  (price in subtitle)
//
//   quotesProvider(symbols)   → available for batch quote lookups (not used yet)
//
//   tickerSearchProvider(q)   → AddTradeScreen: _TickerAutocomplete
//                               shows symbol/name/exchange dropdown as user types
//
//   stockProfileProvider(sym) → available for sector/industry display (not used yet)
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'fmp_models.dart';
import 'fmp_service.dart';

final fmpServiceProvider = Provider<FmpService>((_) => FmpService());

// Quote for a single symbol
final quoteProvider = FutureProvider.family<StockQuote?, String>((ref, symbol) {
  return ref.watch(fmpServiceProvider).getQuote(symbol);
});

// Quotes for a list of symbols (used on dashboard for open positions)
final quotesProvider =
    FutureProvider.family<List<StockQuote>, List<String>>((ref, symbols) {
  return ref.watch(fmpServiceProvider).getQuotes(symbols);
});

// Ticker search results
final tickerSearchProvider =
    FutureProvider.family<List<TickerSearchResult>, String>((ref, query) async {
  if (query.isEmpty) return [];
  return ref.watch(fmpServiceProvider).searchTicker(query);
});

// Company profile
final stockProfileProvider =
    FutureProvider.family<StockProfile?, String>((ref, symbol) {
  return ref.watch(fmpServiceProvider).getProfile(symbol);
});
