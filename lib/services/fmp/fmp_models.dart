// =============================================================================
// services/fmp/fmp_models.dart — FMP API response models
// =============================================================================
// Classes & where they surface in the UI:
//
//   StockQuote
//     Fields: symbol, name, price, change, changePercent, open, dayHigh,
//             dayLow, previousClose, volume
//     Getter: isPositive — drives green/red color in _LiveQuoteCard & _OpenTradeRow
//     Used in: TradeDetailScreen (_LiveQuoteCard)
//              DashboardScreen   (_OpenTradeRow subtitle)
//
//   TickerSearchResult
//     Fields: symbol, name, exchange
//     Used in: AddTradeScreen (_TickerAutocomplete dropdown rows)
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
        changePercent: (json['changePercentage'] as num?)?.toDouble()
            ?? (json['changesPercentage'] as num?)?.toDouble() ?? 0,
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

  factory TickerSearchResult.fromJson(Map<String, dynamic> json) =>
      TickerSearchResult(
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
      Map<String, dynamic> json, String identifier) =>
      EconomicIndicatorPoint(
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
  final StockQuote? hyg;    // High Yield Bond ETF — credit risk proxy
  final StockQuote? lqd;    // IG Bond ETF — investment grade credit
  final StockQuote? copx;   // Copper Miners ETF — growth/expansion proxy

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
