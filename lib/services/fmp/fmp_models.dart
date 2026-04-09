// =============================================================================
// services/fmp/fmp_models.dart — FMP API response models
// =============================================================================
// Endpoint base: https://financialmodelingprep.com/stable
// Auth: apikey= query param via FMP_API_KEY dart-define
//
// Model → Endpoint → Widget map:
//
//  StockQuote
//    GET /quote?symbol={symbol}         (single or comma-separated)
//    Fields returned: symbol, name, price, changePercentage, change,
//                     volume, dayLow, dayHigh, open, previousClose
//    → FmpService.getQuote / getQuotes
//    → quotesProvider / schwabOptionsChainProvider (via SchwabService fallback)
//    → TradeDetailScreen (_LiveQuoteCard), EconomyPulseScreen (Market Snapshot tiles)
//
//  TickerSearchResult
//    GET /search-symbol?query={q}
//    Fields returned: symbol, name, currency, exchangeFullName, exchange
//    → FmpService.searchTicker → tickerSearchProvider
//    → AddTradeScreen (_TickerAutocomplete dropdown)
//
//  StockProfile
//    GET /profile?symbol={symbol}
//    → FmpService.getProfile  (not yet wired to a provider/widget)
//
//  EconomicIndicatorPoint
//    GET /economic-indicators?name={name}&limit={n}
//    Fields returned: name, date, value
//    → FmpService.getEconomicIndicator / getEconomicIndicatorHistory
//    → economyPulseProvider → EconomyPulseScreen (all indicator tiles)
//    → economy_charts_tab.dart (historical chart cards)
//
//  TreasuryRates
//    GET /treasury-rates?limit=1
//    Fields returned: date, month1..year30
//    → FmpService.getLatestTreasuryRates → economyPulseProvider
//    → EconomyPulseScreen (Interest Rates section)
//
//  EconomyPulseData
//    Aggregated result of getEconomyPulse() — combines quotes + indicators
//    → economyPulseProvider → EconomyPulseScreen (_PulseBody)
//
//  FmpHistoricalPrice
//    GET /historical-price-eod/full?symbol={symbol}&from={}&to={}
//    NOTE: stable API returns a bare list [], NOT { historical: [] }
//    Fields returned: symbol, date, open, high, low, close, volume, change, changePercent, vwap
//    → FmpService.getHistoricalPrices → tickerHistoricalPricesProvider
//    → TickerProfileScreen (price history chart)
//
//  FmpEarningsDate
//    GET /earnings-calendar?symbol={symbol}&from={}&to={}
//    NOTE: requires paid FMP plan — returns empty on free tier
//    → FmpService.getNextEarnings → tickerNextEarningsProvider
//    → TickerProfileScreen (Overview tab earnings card)
//
//   StockProfile
//     Fields: symbol, companyName, sector, industry, beta, mktCap
//     Used in: available for future features (not rendered yet)
// =============================================================================
class StockQuote {
  final String symbol;
  final String name;
  final double price;
  final double change;
  final double changePercent;
  final double open;
  final double dayHigh;
  final double dayLow;
  final double previousClose;
  final int volume;

  const StockQuote({
    required this.symbol,
    required this.name,
    required this.price,
    required this.change,
    required this.changePercent,
    required this.open,
    required this.dayHigh,
    required this.dayLow,
    required this.previousClose,
    required this.volume,
  });

  bool get isPositive => change >= 0;

  factory StockQuote.fromJson(Map<String, dynamic> json) => StockQuote(
    symbol: json['symbol'] as String? ?? '',
    name: json['name'] as String? ?? '',
    price: (json['price'] as num?)?.toDouble() ?? 0,
    change: (json['change'] as num?)?.toDouble() ?? 0,
    changePercent:
        (json['changePercentage'] as num?)?.toDouble() ??
        (json['changesPercentage'] as num?)?.toDouble() ??
        0,
    open: (json['open'] as num?)?.toDouble() ?? 0,
    dayHigh: (json['dayHigh'] as num?)?.toDouble() ?? 0,
    dayLow: (json['dayLow'] as num?)?.toDouble() ?? 0,
    previousClose: (json['previousClose'] as num?)?.toDouble() ?? 0,
    volume: (json['volume'] as num?)?.toInt() ?? 0,
  );
}

class TickerSearchResult {
  final String symbol;
  final String name;
  final String exchange;

  const TickerSearchResult({
    required this.symbol,
    required this.name,
    required this.exchange,
  });

  factory TickerSearchResult.fromJson(
    Map<String, dynamic> json,
  ) => TickerSearchResult(
    symbol: json['symbol'] as String? ?? '',
    name: json['name'] as String? ?? '',
    // Stable API /search-symbol returns 'exchange' (short name e.g. "NASDAQ")
    exchange: json['exchange'] as String? ?? '',
  );
}

class StockProfile {
  final String symbol;
  final String companyName;
  final String sector;
  final String industry;
  final double beta;
  final double mktCap;

  const StockProfile({
    required this.symbol,
    required this.companyName,
    required this.sector,
    required this.industry,
    required this.beta,
    required this.mktCap,
  });

  factory StockProfile.fromJson(Map<String, dynamic> json) => StockProfile(
    symbol: json['symbol'] as String? ?? '',
    companyName: json['companyName'] as String? ?? '',
    sector: json['sector'] as String? ?? '',
    industry: json['industry'] as String? ?? '',
    beta: (json['beta'] as num?)?.toDouble() ?? 0,
    mktCap: (json['mktCap'] as num?)?.toDouble() ?? 0,
  );
}

// ─── Economy Pulse additions ──────────────────────────────────────────────

// Single data point from FMP /economic-indicators
class EconomicIndicatorPoint {
  final String identifier;
  final DateTime date;
  final double value;

  const EconomicIndicatorPoint({
    required this.identifier,
    required this.date,
    required this.value,
  });

  factory EconomicIndicatorPoint.fromJson(
    Map<String, dynamic> json,
    String identifier,
  ) => EconomicIndicatorPoint(
    identifier: identifier,
    date: DateTime.parse(json['date'] as String),
    value: (json['value'] as num?)?.toDouble() ?? 0,
  );
}

// Latest treasury yield curve from FMP /treasury-rates
class TreasuryRates {
  final DateTime date;
  final double? year1;
  final double? year2;
  final double? year5;
  final double? year10;
  final double? year20;
  final double? year30;

  const TreasuryRates({
    required this.date,
    this.year1,
    this.year2,
    this.year5,
    this.year10,
    this.year20,
    this.year30,
  });

  factory TreasuryRates.fromJson(Map<String, dynamic> json) => TreasuryRates(
    date: DateTime.parse(json['date'] as String),
    year1: (json['year1'] as num?)?.toDouble(),
    year2: (json['year2'] as num?)?.toDouble(),
    year5: (json['year5'] as num?)?.toDouble(),
    year10: (json['year10'] as num?)?.toDouble(),
    year20: (json['year20'] as num?)?.toDouble(),
    year30: (json['year30'] as num?)?.toDouble(),
  );
}

// Aggregated data model for the Economy Pulse screen
class EconomyPulseData {
  // Market snapshot (live quotes)
  final StockQuote? sp500;
  final StockQuote? nasdaq;
  final StockQuote? vix;
  final StockQuote? dxy;

  // Commodities (live quotes)
  final StockQuote? gold;
  final StockQuote? silver;
  final StockQuote? wtiCrude;
  final StockQuote? natGas;

  // Macro score additions
  final StockQuote? hyg; // High Yield Bond ETF — credit risk proxy
  final StockQuote? lqd; // IG Bond ETF — investment grade credit
  final StockQuote? copx; // Copper Miners ETF — growth/expansion proxy

  // Treasury yield curve
  final TreasuryRates? treasury;

  // Economic indicators (lagging, from /economic-indicators)
  final EconomicIndicatorPoint? fedFunds;
  final EconomicIndicatorPoint? unemployment;
  final EconomicIndicatorPoint? nfp;
  final EconomicIndicatorPoint? initialClaims;
  final EconomicIndicatorPoint? cpi;
  final EconomicIndicatorPoint? gdp;
  final EconomicIndicatorPoint? retailSales;
  final EconomicIndicatorPoint? consumerSentiment;
  final EconomicIndicatorPoint? mortgageRate;
  final EconomicIndicatorPoint? housingStarts;
  final EconomicIndicatorPoint? recessionProb;

  final DateTime fetchedAt;

  const EconomyPulseData({
    this.sp500,
    this.nasdaq,
    this.vix,
    this.dxy,
    this.gold,
    this.silver,
    this.wtiCrude,
    this.natGas,
    this.hyg,
    this.lqd,
    this.copx,
    this.treasury,
    this.fedFunds,
    this.unemployment,
    this.nfp,
    this.initialClaims,
    this.cpi,
    this.gdp,
    this.retailSales,
    this.consumerSentiment,
    this.mortgageRate,
    this.housingStarts,
    this.recessionProb,
    required this.fetchedAt,
  });
}

// ─── Ticker Profile additions ─────────────────────────────────────────────

// Daily OHLCV candle — used in TickerProfileScreen price history chart.
// Fetched via FmpService.getHistoricalPrices() → /historical-price-eod/full
class FmpHistoricalPrice {
  final DateTime date;
  final double open;
  final double high;
  final double low;
  final double close;
  final int volume;

  const FmpHistoricalPrice({
    required this.date,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory FmpHistoricalPrice.fromJson(Map<String, dynamic> json) =>
      FmpHistoricalPrice(
        date: DateTime.parse(json['date'] as String),
        open: (json['open'] as num?)?.toDouble() ?? 0,
        high: (json['high'] as num?)?.toDouble() ?? 0,
        low: (json['low'] as num?)?.toDouble() ?? 0,
        close: (json['close'] as num?)?.toDouble() ?? 0,
        volume: (json['volume'] as num?)?.toInt() ?? 0,
      );
}

// Next scheduled earnings date — used in the Overview tab Earnings card.
// Fetched via FmpService.getNextEarnings() → /earnings-calendar
class FmpEarningsDate {
  final DateTime date;
  final String symbol;
  final double? epsEstimated;
  final double? revenueEstimated;
  final String? fiscalDateEnding;
  final String? time; // 'bmo' (before market open) | 'amc' (after market close)

  const FmpEarningsDate({
    required this.date,
    required this.symbol,
    this.epsEstimated,
    this.revenueEstimated,
    this.fiscalDateEnding,
    this.time,
  });

  String get timeLabel => switch (time) {
    'bmo' => 'Before Open',
    'amc' => 'After Close',
    _ => '',
  };

  factory FmpEarningsDate.fromJson(Map<String, dynamic> json) =>
      FmpEarningsDate(
        date: DateTime.parse(json['date'] as String),
        symbol: json['symbol'] as String? ?? '',
        epsEstimated: (json['epsEstimated'] as num?)?.toDouble(),
        revenueEstimated: (json['revenueEstimated'] as num?)?.toDouble(),
        fiscalDateEnding: json['fiscalDateEnding'] as String?,
        time: json['time'] as String?,
      );
}

// ── Dividend info ─────────────────────────────────────────────────────────────
// FMP /stock-dividend response — next ex-dividend date and annual yield.
// Used by LiveGreeksService to compute the dividend-adjusted forward price
// F = S·e^{(r−q)T} in the BS d1/d2 formula.

class FmpDividendInfo {
  final String symbol;

  /// Next ex-dividend date (null if no upcoming dividend).
  final DateTime? exDividendDate;

  /// Annual dividend yield as a decimal (e.g. 0.015 for 1.5%).
  final double annualYield;

  /// Next cash dividend per share.
  final double nextDividend;

  const FmpDividendInfo({
    required this.symbol,
    required this.exDividendDate,
    required this.annualYield,
    required this.nextDividend,
  });

  factory FmpDividendInfo.fromJson(Map<String, dynamic> json) {
    // FMP returns yield as a decimal for stock-dividend; guard against
    // edge cases where it might come back as a percentage (> 1.0).
    final rawYield = (json['dividendYield'] as num?)?.toDouble() ?? 0.0;
    final adjYield = rawYield > 1.0 ? rawYield / 100.0 : rawYield;

    final exDateStr = json['exDividendDate'] as String?
        ?? json['date'] as String?;
    final exDate = exDateStr != null ? DateTime.tryParse(exDateStr) : null;

    return FmpDividendInfo(
      symbol: json['symbol'] as String? ?? '',
      exDividendDate: exDate,
      annualYield: adjYield,
      nextDividend: (json['dividend'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// True when the ex-dividend date falls within [dte] calendar days.
  bool exDivWithinDte(int dte) {
    if (exDividendDate == null) return false;
    final daysToExDiv = exDividendDate!.difference(DateTime.now()).inDays;
    return daysToExDiv >= 0 && daysToExDiv <= dte;
  }
}
