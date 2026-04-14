// =============================================================================
// services/schwab/schwab_models.dart
// =============================================================================
// All Schwab calls go through Supabase Edge Functions — never direct to Schwab.
// Edge functions handle OAuth token refresh and key secrecy.
//
// Model → Edge Function → Provider → Widget map:
//
//  SchwabInstrument
//    Edge fn: get-schwab-instruments  (Schwab GET /marketdata/v1/instruments)
//    → SchwabService.searchTicker → schwabTickerSearchProvider
//    → TickerDashboardScreen (search bar autocomplete)
//
//  SchwabQuote  →  .toStockQuote() → StockQuote (fmp_models.dart)
//    Edge fn: get-schwab-quotes  (Schwab GET /marketdata/v1/quotes)
//    Response shape: { "SPY": { quote: {lastPrice,...}, realtime: bool } }
//    → SchwabService.getQuotes → schwabQuotesProvider
//    → EconomyPulseScreen (Market Snapshot), TradeDetailScreen (_LiveQuoteCard)
//
//  SchwabOptionsChain  (contains SchwabExpiration[] → SchwabOptionContract[])
//    Edge fn: get-schwab-chains  (Schwab GET /marketdata/v1/chains)
//    → SchwabService.getOptionsChain → schwabOptionsChainProvider (family by symbol)
//    → OptionsChainScreen (calls + puts tables, expiration picker)
//    → OptionDecisionWizard
// =============================================================================
import '../fmp/fmp_models.dart';

// ── Instrument search result ──────────────────────────────────────────────────

class SchwabInstrument {
  final String symbol;
  final String name;
  final String exchange;
   final double price;
  final double change;
  final double changePercent;
  final double open;
  final double dayHigh;
  final double dayLow;
  final double previousClose;
  final int volume;

  const SchwabInstrument({
    required this.symbol,
    required this.name,
    required this.exchange,
    required this.price,
    required this.change,
    required this.changePercent,
    required this.open,
    required this.dayHigh,
    required this.dayLow,
    required this.previousClose,
    required this.volume,
  });

  factory SchwabInstrument.fromJson(Map<String, dynamic> json) =>
      SchwabInstrument(
        symbol:   json['symbol']   as String? ?? '',
        name:     json['name']     as String? ?? '',
        exchange: json['exchange'] as String? ?? '',
        price:    (json['price'] as num?)?.toDouble() ?? 0,
        change:   (json['change'] as num?)?.toDouble() ?? 0,
        changePercent: (json['changePercent'] as num?)?.toDouble()
            ?? (json['changePercentage'] as num?)?.toDouble() ?? 0,
        open:     (json['open'] as num?)?.toDouble() ?? 0,
        dayHigh:  (json['dayHigh'] as num?)?.toDouble() ?? 0,
        dayLow:   (json['dayLow'] as num?)?.toDouble() ?? 0,
        previousClose: (json['previousClose'] as num?)?.toDouble() ?? 0,
        volume:   (json['volume'] as num?)?.toInt() ?? 0,
      );
}

// ── Fundamentals (from fields=fundamental on quotes endpoint) ─────────────────
// Schwab returns nextEarningsDate as "2025-07-24 00:00:00.000" or "".

class SchwabFundamentals {
  final DateTime? nextEarningsDate;
  final double    peRatio;
  final double    eps;
  final double    beta;
  final double    marketCap;       // in dollars
  final double    dividendYield;   // percent
  final double    high52;
  final double    low52;
  final double    vol10DayAvg;
  final double    vol3MonthAvg;

  const SchwabFundamentals({
    this.nextEarningsDate,
    required this.peRatio,
    required this.eps,
    required this.beta,
    required this.marketCap,
    required this.dividendYield,
    required this.high52,
    required this.low52,
    required this.vol10DayAvg,
    required this.vol3MonthAvg,
  });

  factory SchwabFundamentals.fromJson(Map<String, dynamic> f) {
    // Schwab format: "2025-07-24 00:00:00.000" — replace space with T to parse
    DateTime? earningsDate;
    final raw = f['nextEarningsDate'] as String? ?? '';
    if (raw.isNotEmpty && raw != '0001-01-01 00:00:00.000') {
      earningsDate = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    }
    return SchwabFundamentals(
      nextEarningsDate: earningsDate,
      peRatio:      (f['peRatio']      as num? ?? 0).toDouble(),
      eps:          (f['eps']          as num? ?? 0).toDouble(),
      beta:         (f['beta']         as num? ?? 0).toDouble(),
      marketCap:    (f['marketCap']    as num? ?? 0).toDouble(),
      dividendYield:(f['dividendYield']as num? ?? 0).toDouble(),
      high52:       (f['high52']       as num? ?? 0).toDouble(),
      low52:        (f['low52']        as num? ?? 0).toDouble(),
      vol10DayAvg:  (f['vol10DayAvg']  as num? ?? 0).toDouble(),
      vol3MonthAvg: (f['vol3MonthAvg'] as num? ?? 0).toDouble(),
    );
  }
}

// ── Quote ─────────────────────────────────────────────────────────────────────

class SchwabQuote {
  final String              symbol;
  final double              lastPrice;
  final double              bidPrice;
  final double              askPrice;
  final double              openPrice;
  final double              highPrice;
  final double              lowPrice;
  final double              closePrice;
  final double              netChange;
  final double              netPercentChange;
  final int                 totalVolume;
  final bool                realtime;
  final SchwabFundamentals? fundamentals;

  const SchwabQuote({
    required this.symbol,
    required this.lastPrice,
    required this.bidPrice,
    required this.askPrice,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.closePrice,
    required this.netChange,
    required this.netPercentChange,
    required this.totalVolume,
    required this.realtime,
    this.fundamentals,
  });

  /// Next earnings date, if Schwab returned it.
  DateTime? get nextEarningsDate => fundamentals?.nextEarningsDate;

  factory SchwabQuote.fromJson(String symbol, Map<String, dynamic> json) {
    final q = json['quote']       as Map<String, dynamic>? ?? {};
    final f = json['fundamental'] as Map<String, dynamic>?;
    return SchwabQuote(
      symbol:           symbol,
      lastPrice:        (q['lastPrice']         as num? ?? 0).toDouble(),
      bidPrice:         (q['bidPrice']          as num? ?? 0).toDouble(),
      askPrice:         (q['askPrice']          as num? ?? 0).toDouble(),
      openPrice:        (q['openPrice']         as num? ?? 0).toDouble(),
      highPrice:        (q['highPrice']         as num? ?? 0).toDouble(),
      lowPrice:         (q['lowPrice']          as num? ?? 0).toDouble(),
      closePrice:       (q['closePrice']        as num? ?? 0).toDouble(),
      netChange:        (q['netChange']         as num? ?? 0).toDouble(),
      netPercentChange: (q['netPercentChange']  as num? ?? 0).toDouble(),
      totalVolume:      (q['totalVolume']       as num? ?? 0).toInt(),
      realtime:         json['realtime']        as bool? ?? false,
      fundamentals:     f != null ? SchwabFundamentals.fromJson(f) : null,
    );
  }

  /// Adapter — converts to the StockQuote type all existing UI widgets expect.
  StockQuote toStockQuote() => StockQuote(
        symbol:        symbol,
        name:          symbol,
        price:         lastPrice,
        change:        netChange,
        changePercent: netPercentChange,
        open:          openPrice,
        dayHigh:       highPrice,
        dayLow:        lowPrice,
        previousClose: closePrice,
        volume:        totalVolume,
      );
}

// ── Options chain ─────────────────────────────────────────────────────────────

class SchwabOptionContract {
  final String  symbol;
  final double  strikePrice;
  final double  bid;
  final double  ask;
  final double  last;
  final double  markPrice;       // Schwab mark = (bid+ask)/2
  final int     bidSize;
  final int     askSize;
  final double  highPrice;       // daily high for this contract
  final double  lowPrice;        // daily low for this contract
  final double  delta;
  final double  gamma;
  final double  theta;
  final double  vega;
  final double  rho;
  final double  impliedVolatility;
  final int     totalVolume;
  final int     openInterest;
  final int     daysToExpiration;
  final bool    inTheMoney;
  final double  intrinsicValue;
  final double  timeValue;       // extrinsic value
  final double  theoreticalOptionValue;
  final String  expirationDate;

  const SchwabOptionContract({
    required this.symbol,
    required this.strikePrice,
    required this.bid,
    required this.ask,
    required this.last,
    required this.markPrice,
    required this.bidSize,
    required this.askSize,
    required this.highPrice,
    required this.lowPrice,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.rho,
    required this.impliedVolatility,
    required this.totalVolume,
    required this.openInterest,
    required this.daysToExpiration,
    required this.inTheMoney,
    required this.intrinsicValue,
    required this.timeValue,
    required this.theoreticalOptionValue,
    required this.expirationDate,
  });

  factory SchwabOptionContract.fromJson(Map<String, dynamic> j) =>
      SchwabOptionContract(
        symbol:                  j['symbol']                  as String? ?? '',
        strikePrice:             (j['strikePrice']             as num? ?? 0).toDouble(),
        bid:                     (j['bid']                     as num? ?? 0).toDouble(),
        ask:                     (j['ask']                     as num? ?? 0).toDouble(),
        last:                    (j['last']                    as num? ?? 0).toDouble(),
        markPrice:               (j['mark']                    as num? ?? 0).toDouble(),
        bidSize:                 (j['bidSize']                 as num? ?? 0).toInt(),
        askSize:                 (j['askSize']                 as num? ?? 0).toInt(),
        highPrice:               (j['highPrice']               as num? ?? 0).toDouble(),
        lowPrice:                (j['lowPrice']                as num? ?? 0).toDouble(),
        delta:                   (j['delta']                   as num? ?? 0).toDouble(),
        gamma:                   (j['gamma']                   as num? ?? 0).toDouble(),
        theta:                   (j['theta']                   as num? ?? 0).toDouble(),
        vega:                    (j['vega']                    as num? ?? 0).toDouble(),
        rho:                     (j['rho']                     as num? ?? 0).toDouble(),
        impliedVolatility:       (j['volatility']              as num? ?? 0).toDouble(),
        totalVolume:             (j['totalVolume']             as num? ?? 0).toInt(),
        openInterest:            (j['openInterest']            as num? ?? 0).toInt(),
        daysToExpiration:        (j['daysToExpiration']        as num? ?? 0).toInt(),
        inTheMoney:              j['inTheMoney']               as bool? ?? false,
        intrinsicValue:          (j['intrinsicValue']          as num? ?? 0).toDouble(),
        timeValue:               (j['timeValue']               as num? ?? 0).toDouble(),
        theoreticalOptionValue:  (j['theoreticalOptionValue']  as num? ?? 0).toDouble(),
        expirationDate:          j['expirationDate']           as String? ?? '',
      );

  double get midpoint => (bid + ask) / 2;
  double get spreadPct => midpoint == 0 ? 1 : (ask - bid) / midpoint;
}

class SchwabOptionsExpiration {
  final String                      expirationDate;
  final int                         dte;
  final List<SchwabOptionContract>  calls;
  final List<SchwabOptionContract>  puts;

  const SchwabOptionsExpiration({
    required this.expirationDate,
    required this.dte,
    required this.calls,
    required this.puts,
  });
}

class SchwabOptionsChain {
  final String                          symbol;
  final double                          underlyingPrice;
  final double                          volatility;
  final List<SchwabOptionsExpiration>   expirations;

  const SchwabOptionsChain({
    required this.symbol,
    required this.underlyingPrice,
    required this.volatility,
    required this.expirations,
  });

  factory SchwabOptionsChain.fromJson(Map<String, dynamic> json) {
    final underlying = json['underlying'] as Map<String, dynamic>? ?? {};
    final underlyingPrice =
        (underlying['last'] as num? ?? json['underlyingPrice'] as num? ?? 0)
            .toDouble();
    final volatility = (json['volatility'] as num? ?? 0).toDouble();

    // Parse callExpDateMap and putExpDateMap
    // Structure: { "2025-04-11:9": { "550.0": [contractJson, ...] } }
    final callMap = json['callExpDateMap'] as Map<String, dynamic>? ?? {};
    final putMap  = json['putExpDateMap']  as Map<String, dynamic>? ?? {};

    final Map<String, List<SchwabOptionContract>> callsByExp = {};
    final Map<String, List<SchwabOptionContract>> putsByExp  = {};

    for (final entry in callMap.entries) {
      final expKey = entry.key.split(':').first; // "2025-04-11"
      final strikes = entry.value as Map<String, dynamic>;
      callsByExp[expKey] = strikes.values
          .expand((v) => (v as List).map(
              (c) => SchwabOptionContract.fromJson(c as Map<String, dynamic>)))
          .toList();
    }

    for (final entry in putMap.entries) {
      final expKey = entry.key.split(':').first;
      final strikes = entry.value as Map<String, dynamic>;
      putsByExp[expKey] = strikes.values
          .expand((v) => (v as List).map(
              (c) => SchwabOptionContract.fromJson(c as Map<String, dynamic>)))
          .toList();
    }

    final allDates = {...callsByExp.keys, ...putsByExp.keys}.toList()..sort();

    final expirations = allDates.map((date) {
      final calls = callsByExp[date] ?? [];
      final dte   = calls.isNotEmpty
          ? calls.first.daysToExpiration
          : (putsByExp[date]?.isNotEmpty == true
              ? putsByExp[date]!.first.daysToExpiration
              : 0);
      return SchwabOptionsExpiration(
        expirationDate: date,
        dte:            dte,
        calls:          calls..sort((a, b) => a.strikePrice.compareTo(b.strikePrice)),
        puts:           (putsByExp[date] ?? [])
            ..sort((a, b) => a.strikePrice.compareTo(b.strikePrice)),
      );
    }).toList();

    return SchwabOptionsChain(
      symbol:         json['symbol'] as String? ?? '',
      underlyingPrice: underlyingPrice,
      volatility:     volatility,
      expirations:    expirations,
    );
  }
}
