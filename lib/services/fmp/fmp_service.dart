// =============================================================================
// services/fmp/fmp_service.dart — Financial Modeling Prep HTTP client
// =============================================================================
// Singleton service; accessed via fmpServiceProvider (fmp_providers.dart).
//
// Methods & where they are used:
//   • getQuote(symbol)         → quoteProvider    → TradeDetailScreen (_LiveQuoteCard)
//                                                 → DashboardScreen   (_OpenTradeRow)
//   • getQuotes(symbols)       → quotesProvider   → (available for batch lookups)
//   • searchTicker(query)      → tickerSearchProvider → AddTradeScreen (_TickerAutocomplete)
//   • getProfile(symbol)       → stockProfileProvider → (available for future use)
//
// Config: FmpConfig.baseUrl + FmpConfig.apiKey (core/fmp_config.dart)
// Models: StockQuote, TickerSearchResult, StockProfile, FmpHistoricalPrice,
//         FmpEarningsDate (fmp_models.dart)
//
//   • getHistoricalPrices(symbol, {days}) → tickerHistoricalPricesProvider
//                                          → TickerProfileScreen (price chart)
//   • getNextEarnings(symbol)             → tickerNextEarningsProvider
//                                          → TickerProfileScreen (Overview tab)
// =============================================================================
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/fmp_config.dart';
import 'fmp_models.dart';

class FmpService {
  static final FmpService _instance = FmpService._();
  FmpService._();
  factory FmpService() => _instance;

  final _client = http.Client();

  Uri _url(String path, [Map<String, String>? params]) {
    final query = {
      'apikey': FmpConfig.apiKey,
      ...?params,
    };
    return Uri.parse('${FmpConfig.baseUrl}$path').replace(queryParameters: query);
  }

  Future<StockQuote?> getQuote(String symbol) async {
    try {
      final res = await _client.get(_url('/quote', {'symbol': symbol}));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty) {
        return StockQuote.fromJson(data.first as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<StockQuote>> getQuotes(List<String> symbols) async {
    if (symbols.isEmpty) return [];
    try {
      final res = await _client.get(
        _url('/quote', {'symbol': symbols.join(',')}),
      );
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      if (data is List) {
        return data
            .map((e) => StockQuote.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<List<TickerSearchResult>> searchTicker(String query) async {
    if (query.isEmpty) return [];
    try {
      final res = await _client.get(_url('/search-symbol', {'query': query}));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      if (data is List) {
        return data
            .take(8)
            .map((e) => TickerSearchResult.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<StockProfile?> getProfile(String symbol) async {
    try {
      final res = await _client.get(_url('/profile', {'symbol': symbol}));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty) {
        return StockProfile.fromJson(data.first as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Daily OHLCV candles for [symbol] going back [days] calendar days.
  Future<List<FmpHistoricalPrice>> getHistoricalPrices(
    String symbol, {
    int days = 90,
  }) async {
    try {
      final to = DateTime.now();
      final from = to.subtract(Duration(days: days));
      String fmt(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final res = await _client.get(_url(
        '/historical-price-eod/full',
        {'symbol': symbol, 'from': fmt(from), 'to': fmt(to)},
      ));
      if (res.statusCode != 200) return [];
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      final hist = body?['historical'];
      if (hist is List) {
        return hist
            .map((e) => FmpHistoricalPrice.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Next scheduled earnings date for [symbol] (returns first upcoming entry).
  Future<FmpEarningsDate?> getNextEarnings(String symbol) async {
    try {
      final from = DateTime.now();
      final to = from.add(const Duration(days: 180));
      String fmt(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final res = await _client.get(_url(
        '/earnings-calendar',
        {'symbol': symbol, 'from': fmt(from), 'to': fmt(to)},
      ));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty) {
        return FmpEarningsDate.fromJson(data.first as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
