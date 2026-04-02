// =============================================================================
// services/fmp/fmp_providers.dart — Riverpod providers for FMP data
// =============================================================================
// All providers below call Financial Modeling Prep (FMP) REST API.
// Base URL : https://financialmodelingprep.com/stable  (FmpConfig.baseUrl)
// Auth     : ?apikey=  query param                     (FmpConfig.apiKey)
// Docs     : https://site.financialmodelingprep.com/developer/docs
//
//   fmpServiceProvider                — FmpService singleton
//
//   quoteProvider(symbol)             GET /quote?symbol=
//     → TickerDashboardScreen         live price + change% on each ticker card
//     → TickerProfileScreen AppBar    price subtitle
//     → TradeDetailScreen             _LiveQuoteCard
//     → DashboardScreen               _OpenTradeRow subtitle
//
//   quotesProvider(symbols)           GET /quote?symbol=A,B,C  (batch)
//     → available for future batch lookups
//
//   tickerSearchProvider(query)       GET /search-symbol?query=
//     → AddTradeScreen                _TickerAutocomplete dropdown
//     → TickerDashboardScreen         _TickerSearchDialog
//
//   stockProfileProvider(symbol)      GET /profile?symbol=
//     → available for sector/industry display (not rendered yet)
//
//   tickerHistoricalPricesProvider(s) GET /historical-price-eod/full?symbol=&from=&to=
//     → TickerProfileScreen           price history chart (not yet rendered)
//
//   tickerNextEarningsProvider(s)     GET /earnings-calendar?symbol=&from=&to=
//     → TickerProfileScreen           Overview tab — next earnings date card
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
//final tickerSearchProvider =
//    FutureProvider.family<List<TickerSearchResult>, String>((ref, query) async {
//  if (query.isEmpty) return [];
//  return ref.watch(fmpServiceProvider).searchTicker(query);
//});

// Company profile
final stockProfileProvider =
    FutureProvider.family<StockProfile?, String>((ref, symbol) {
  return ref.watch(fmpServiceProvider).getProfile(symbol);
});

// Daily OHLCV candles — TickerProfileScreen price history chart
final tickerHistoricalPricesProvider =
    FutureProvider.family<List<FmpHistoricalPrice>, String>((ref, symbol) {
  return ref.watch(fmpServiceProvider).getHistoricalPrices(symbol);
});

// All economy pulse data — EconomyPulseScreen
final economyPulseProvider = FutureProvider<EconomyPulseData>((ref) {
  return ref.watch(fmpServiceProvider).getEconomyPulse();
});

// Next scheduled earnings date — TickerProfileScreen Overview tab
final tickerNextEarningsProvider =
    FutureProvider.family<FmpEarningsDate?, String>((ref, symbol) {
  return ref.watch(fmpServiceProvider).getNextEarnings(symbol);
});
