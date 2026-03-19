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
