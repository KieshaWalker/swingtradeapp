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
      final decoded = jsonDecode(res.body);
      // FMP stable API returns a bare list: [{symbol,date,open,high,low,close,volume,...}]
      // Legacy v3 returned { historical: [...] } — handle both for safety.
      final hist = decoded is List
          ? decoded
          : (decoded as Map<String, dynamic>?)?['historical'] as List?;
      if (hist == null) return [];
      return hist
          .map((e) => FmpHistoricalPrice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Historical monthly data points for an economic indicator.
  /// Endpoint: GET /economic-indicators?name={name}&limit={months}
  /// Returns oldest-first for charting.
  Future<List<EconomicIndicatorPoint>> getEconomicIndicatorHistory(
    String name, {
    int months = 24,
  }) async {
    try {
      final res = await _client.get(
          _url('/economic-indicators', {'name': name, 'limit': '$months'}));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      if (data is List) {
        final points = data
            .map((e) => EconomicIndicatorPoint.fromJson(
                e as Map<String, dynamic>, name))
            .toList();
        // FMP returns newest-first; reverse so chart reads left→right
        return points.reversed.toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Latest value for an economic indicator by FMP identifier name.
  /// Endpoint: GET /economic-indicators?name={name}&limit=1
  Future<EconomicIndicatorPoint?> getEconomicIndicator(String name) async {
    try {
      final res = await _client
          .get(_url('/economic-indicators', {'name': name, 'limit': '1'}));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty) {
        return EconomicIndicatorPoint.fromJson(
            data.first as Map<String, dynamic>, name);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Latest treasury yield curve snapshot.
  /// Endpoint: GET /treasury-rates?limit=1
  Future<TreasuryRates?> getLatestTreasuryRates() async {
    try {
      final res =
          await _client.get(_url('/treasury-rates', {'limit': '1'}));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty) {
        return TreasuryRates.fromJson(data.first as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches ONLY economic indicators (treasury + FRED-style macro data).
  /// Market quotes are now sourced from Schwab via [economyPulseProvider].
  Future<({
    TreasuryRates? treasury,
    EconomicIndicatorPoint? fedFunds,
    EconomicIndicatorPoint? unemployment,
    EconomicIndicatorPoint? nfp,
    EconomicIndicatorPoint? initialClaims,
    EconomicIndicatorPoint? cpi,
    EconomicIndicatorPoint? gdp,
    EconomicIndicatorPoint? retailSales,
    EconomicIndicatorPoint? consumerSentiment,
    EconomicIndicatorPoint? mortgageRate,
    EconomicIndicatorPoint? housingStarts,
    EconomicIndicatorPoint? recessionProb,
  })> getEconomyIndicators() async {
    final treasuryFuture = getLatestTreasuryRates();
    final fedFuture      = getEconomicIndicator('federalFunds');
    final unempFuture    = getEconomicIndicator('unemploymentRate');
    final nfpFuture      = getEconomicIndicator('totalNonfarmPayrolls');
    final claimsFuture   = getEconomicIndicator('initialJoblessClaims');
    final cpiFuture      = getEconomicIndicator('CPI');

    final treasury = await treasuryFuture;
    final fed      = await fedFuture;
    final unemp    = await unempFuture;
    final nfp      = await nfpFuture;
    final claims   = await claimsFuture;
    final cpi      = await cpiFuture;

    await Future.delayed(const Duration(milliseconds: 400));

    final r2 = await Future.wait([
      getEconomicIndicator('realGDP'),
      getEconomicIndicator('retailSales'),
      getEconomicIndicator('consumerSentiment'),
      getEconomicIndicator('30YearFixedRateMortgageAverage'),
      getEconomicIndicator('newPrivatelyOwnedHousingUnitsStartedTotalUnits'),
      getEconomicIndicator('smoothedUSRecessionProbabilities'),
    ]);

    return (
      treasury:          treasury,
      fedFunds:          fed,
      unemployment:      unemp,
      nfp:               nfp,
      initialClaims:     claims,
      cpi:               cpi,
      gdp:               r2[0],
      retailSales:       r2[1],
      consumerSentiment: r2[2],
      mortgageRate:      r2[3],
      housingStarts:     r2[4],
      recessionProb:     r2[5],
    );
  }

  /// Fetches all data needed for the Economy Pulse screen.
  /// Quotes are batched into 1 request; indicators are split into 2 staggered
  /// batches to stay well under the FMP rate limit.
  Future<EconomyPulseData> getEconomyPulse() async {
    // 1 request for all 11 asset quotes
    final quotesFuture = getQuotes(
      ['SPY', 'QQQ', 'VIXY', 'UUP', 'GC=F', 'SI=F', 'CL=F', 'NG=F', 'HYG', 'LQD', 'COPX'],
    );

    // Treasury + first 5 indicators in parallel with quotes
    final treasuryFuture   = getLatestTreasuryRates();
    final fedFuture        = getEconomicIndicator('federalFunds');
    final unempFuture      = getEconomicIndicator('unemploymentRate');
    final nfpFuture        = getEconomicIndicator('totalNonfarmPayrolls');
    final claimsFuture     = getEconomicIndicator('initialJoblessClaims');
    final cpiFuture        = getEconomicIndicator('CPI');

    // Await first batch before firing second batch
    final quotes    = await quotesFuture;
    final treasury  = await treasuryFuture;
    final fed       = await fedFuture;
    final unemp     = await unempFuture;
    final nfp       = await nfpFuture;
    final claims    = await claimsFuture;
    final cpi       = await cpiFuture;

    await Future.delayed(const Duration(milliseconds: 400));

    // Second batch of 6 indicators
    final results2 = await Future.wait([
      getEconomicIndicator('realGDP'),
      getEconomicIndicator('retailSales'),
      getEconomicIndicator('consumerSentiment'),
      getEconomicIndicator('30YearFixedRateMortgageAverage'),
      getEconomicIndicator('newPrivatelyOwnedHousingUnitsStartedTotalUnits'),
      getEconomicIndicator('smoothedUSRecessionProbabilities'),
    ]);

    StockQuote? q(String sym) {
      try { return quotes.firstWhere((s) => s.symbol == sym); }
      catch (_) { return null; }
    }

    return EconomyPulseData(
      sp500: q('SPY'),
      nasdaq: q('QQQ'),
      vix: q('VIXY'),
      dxy: q('UUP'),
      gold: q('GC=F'),
      silver: q('SI=F'),
      wtiCrude: q('CL=F'),
      natGas: q('NG=F'),
      hyg: q('HYG'),
      lqd: q('LQD'),
      copx: q('COPX'),
      treasury: treasury,
      fedFunds: fed,
      unemployment: unemp,
      nfp: nfp,
      initialClaims: claims,
      cpi: cpi,
      gdp: results2[0],
      retailSales: results2[1],
      consumerSentiment: results2[2],
      mortgageRate: results2[3],
      housingStarts: results2[4],
      recessionProb: results2[5],
      fetchedAt: DateTime.now(),
    );
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

  /// Fetches the next ex-dividend date and annual yield for [symbol].
  /// Endpoint: GET /stock-dividend?symbol={symbol}&limit=2
  /// Returns null when the symbol pays no dividend or data is unavailable.
  Future<FmpDividendInfo?> getDividendInfo(String symbol) async {
    try {
      final res = await _client
          .get(_url('/stock-dividend', {'symbol': symbol, 'limit': '2'}));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is! List || data.isEmpty) return null;
      return FmpDividendInfo.fromJson(data.first as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
