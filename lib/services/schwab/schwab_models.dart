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
//  SchwabQuote  →  .toStockQuote() → StockQuote
//    Edge fn: get-schwab-quotes  (Schwab GET /marketdata/v1/quotes)
//    Response shape: { "SPY": { quote: {lastPrice,...}, realtime: bool } }
//    → SchwabService.getQuotes → quotesProvider
//    → EconomyPulseScreen (Market Snapshot), TradeDetailScreen (_LiveQuoteCard)
//
//  SchwabOptionsChain  (contains SchwabExpiration[] → SchwabOptionContract[])
//    Edge fn: get-schwab-chains  (Schwab GET /marketdata/v1/chains)
//    → SchwabService.getOptionsChain → schwabOptionsChainProvider (family by symbol)
//    → OptionsChainScreen (calls + puts tables, expiration picker)
//    → OptionDecisionWizard
//
//  SchwabMover
//    Edge fn: get-schwab-movers  (Schwab GET /marketdata/v1/movers/{symbol_id})
//    → SchwabService.getMovers → moversProvider (family by MoversParams)
// =============================================================================

// ── Movers ────────────────────────────────────────────────────────────────────

class SchwabMover {
  final String symbol;
  final String description;
  final double last;         // last quoted price
  final double change;       // percent change (default) or value change
  final String direction;    // "up" | "down"
  final int    totalVolume;

  const SchwabMover({
    required this.symbol,
    required this.description,
    required this.last,
    required this.change,
    required this.direction,
    required this.totalVolume,
  });

  bool get isUp => direction == 'up';

  factory SchwabMover.fromJson(Map<String, dynamic> j) => SchwabMover(
        symbol:      j['symbol']      as String? ?? '',
        description: j['description'] as String? ?? '',
        last:        (j['last']        as num? ?? 0).toDouble(),
        change:      (j['change']      as num? ?? 0).toDouble(),
        direction:   j['direction']    as String? ?? '',
        totalVolume: (j['totalVolume'] as num? ?? 0).toInt(),
      );
}

// ── Shared quote model used by all quote providers and UI widgets ─────────────

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
  final int    volume;
  final double dividendYield; // percent, e.g. 1.35 means 1.35%

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
    this.dividendYield = 0.0,
  });

  bool get isPositive => change >= 0;
}

// ── Economic indicator data point (used by economy_storage_service) ───────────

class EconomicIndicatorPoint {
  final String   identifier;
  final DateTime date;
  final double   value;

  const EconomicIndicatorPoint({
    required this.identifier,
    required this.date,
    required this.value,
  });
}

// ── Earnings date (from Schwab fundamentals) ──────────────────────────────────

class EarningsDate {
  final DateTime  date;
  final String    time;           // 'bmo' | 'amc' | '' — Schwab does not provide this
  final double?   epsEstimated;   // null — Schwab does not provide this
  final DateTime? lastEarningsDate;

  const EarningsDate({required this.date, this.time = '', this.epsEstimated, this.lastEarningsDate});

  String get timeLabel => switch (time) {
    'bmo' => 'Before market open',
    'amc' => 'After market close',
    _     => '',
  };
}

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
// Full FundamentalInst from Schwab. Dates returned as "2026-07-24 00:00:00.000"
// or "" when unknown. Volume keys exist under two names in Schwab's spec
// (e.g. vol10DayAvg / avg10DaysVolume) — fromJson tries both.

class SchwabFundamentals {
  // ── Price range ──────────────────────────────────────────────────────────────
  final double    high52;
  final double    low52;

  // ── Valuation ────────────────────────────────────────────────────────────────
  final double    peRatio;
  final double    pegRatio;
  final double    pbRatio;
  final double    prRatio;           // price/revenue
  final double    pcfRatio;          // price/cash-flow

  // ── Profitability ────────────────────────────────────────────────────────────
  final double    grossMarginTTM;
  final double    grossMarginMRQ;
  final double    netProfitMarginTTM;
  final double    netProfitMarginMRQ;
  final double    operatingMarginTTM;
  final double    operatingMarginMRQ;
  final double    returnOnEquity;
  final double    returnOnAssets;
  final double    returnOnInvestment;

  // ── Liquidity / leverage ─────────────────────────────────────────────────────
  final double    quickRatio;
  final double    currentRatio;
  final double    interestCoverage;
  final double    totalDebtToCapital;
  final double    ltDebtToEquity;
  final double    totalDebtToEquity;

  // ── EPS / growth ─────────────────────────────────────────────────────────────
  final double    eps;
  final double    epsTTM;
  final double    epsChangePercentTTM;
  final double    epsChangeYear;
  final double    epsChange;
  final double    revChangeYear;
  final double    revChangeTTM;
  final double    revChangeIn;

  // ── Market / share data ──────────────────────────────────────────────────────
  final double    marketCap;
  final double    marketCapFloat;
  final double    sharesOutstanding;
  final double    bookValuePerShare;
  final double    shortIntToFloat;
  final double    shortIntDayToCover;
  final double    beta;

  // ── Dividends ────────────────────────────────────────────────────────────────
  final double    dividendYield;
  final double    dividendAmount;
  final double    dividendPayAmount;
  final double    divGrowthRate3Year;
  final int       dividendFreq;
  final DateTime? dividendDate;
  final DateTime? dividendPayDate;
  final DateTime? nextDividendDate;
  final DateTime? nextDividendPayDate;
  final DateTime? declarationDate;

  // ── Volume ───────────────────────────────────────────────────────────────────
  final double    vol1DayAvg;
  final double    vol10DayAvg;
  final double    vol3MonthAvg;

  // ── Earnings dates ───────────────────────────────────────────────────────────
  final DateTime? nextEarningsDate;
  final DateTime? lastEarningsDate;

  // ── Fund-specific ────────────────────────────────────────────────────────────
  final double    fundLeverageFactor;
  final String    fundStrategy;

  const SchwabFundamentals({
    this.high52                = 0,
    this.low52                 = 0,
    this.peRatio               = 0,
    this.pegRatio              = 0,
    this.pbRatio               = 0,
    this.prRatio               = 0,
    this.pcfRatio              = 0,
    this.grossMarginTTM        = 0,
    this.grossMarginMRQ        = 0,
    this.netProfitMarginTTM    = 0,
    this.netProfitMarginMRQ    = 0,
    this.operatingMarginTTM    = 0,
    this.operatingMarginMRQ    = 0,
    this.returnOnEquity        = 0,
    this.returnOnAssets        = 0,
    this.returnOnInvestment    = 0,
    this.quickRatio            = 0,
    this.currentRatio          = 0,
    this.interestCoverage      = 0,
    this.totalDebtToCapital    = 0,
    this.ltDebtToEquity        = 0,
    this.totalDebtToEquity     = 0,
    this.eps                   = 0,
    this.epsTTM                = 0,
    this.epsChangePercentTTM   = 0,
    this.epsChangeYear         = 0,
    this.epsChange             = 0,
    this.revChangeYear         = 0,
    this.revChangeTTM          = 0,
    this.revChangeIn           = 0,
    this.marketCap             = 0,
    this.marketCapFloat        = 0,
    this.sharesOutstanding     = 0,
    this.bookValuePerShare     = 0,
    this.shortIntToFloat       = 0,
    this.shortIntDayToCover    = 0,
    this.beta                  = 0,
    this.dividendYield         = 0,
    this.dividendAmount        = 0,
    this.dividendPayAmount     = 0,
    this.divGrowthRate3Year    = 0,
    this.dividendFreq          = 0,
    this.dividendDate,
    this.dividendPayDate,
    this.nextDividendDate,
    this.nextDividendPayDate,
    this.declarationDate,
    this.vol1DayAvg            = 0,
    this.vol10DayAvg           = 0,
    this.vol3MonthAvg          = 0,
    this.nextEarningsDate,
    this.lastEarningsDate,
    this.fundLeverageFactor    = 0,
    this.fundStrategy          = '',
  });

  static DateTime? _parseDate(Map<String, dynamic> f, String key) {
    final raw = f[key] as String? ?? '';
    if (raw.isEmpty || raw.startsWith('0001-01-01')) return null;
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  static double _d(Map<String, dynamic> f, String key, [String? altKey]) {
    final v = f[key] ?? (altKey != null ? f[altKey] : null);
    return (v as num? ?? 0).toDouble();
  }

  factory SchwabFundamentals.fromJson(Map<String, dynamic> f) => SchwabFundamentals(
        high52:                _d(f, 'high52'),
        low52:                 _d(f, 'low52'),
        peRatio:               _d(f, 'peRatio'),
        pegRatio:              _d(f, 'pegRatio'),
        pbRatio:               _d(f, 'pbRatio'),
        prRatio:               _d(f, 'prRatio'),
        pcfRatio:              _d(f, 'pcfRatio'),
        grossMarginTTM:        _d(f, 'grossMarginTTM'),
        grossMarginMRQ:        _d(f, 'grossMarginMRQ'),
        netProfitMarginTTM:    _d(f, 'netProfitMarginTTM'),
        netProfitMarginMRQ:    _d(f, 'netProfitMarginMRQ'),
        operatingMarginTTM:    _d(f, 'operatingMarginTTM'),
        operatingMarginMRQ:    _d(f, 'operatingMarginMRQ'),
        returnOnEquity:        _d(f, 'returnOnEquity'),
        returnOnAssets:        _d(f, 'returnOnAssets'),
        returnOnInvestment:    _d(f, 'returnOnInvestment'),
        quickRatio:            _d(f, 'quickRatio'),
        currentRatio:          _d(f, 'currentRatio'),
        interestCoverage:      _d(f, 'interestCoverage'),
        totalDebtToCapital:    _d(f, 'totalDebtToCapital'),
        ltDebtToEquity:        _d(f, 'ltDebtToEquity'),
        totalDebtToEquity:     _d(f, 'totalDebtToEquity'),
        eps:                   _d(f, 'eps'),
        epsTTM:                _d(f, 'epsTTM'),
        epsChangePercentTTM:   _d(f, 'epsChangePercentTTM'),
        epsChangeYear:         _d(f, 'epsChangeYear'),
        epsChange:             _d(f, 'epsChange'),
        revChangeYear:         _d(f, 'revChangeYear'),
        revChangeTTM:          _d(f, 'revChangeTTM'),
        revChangeIn:           _d(f, 'revChangeIn'),
        marketCap:             _d(f, 'marketCap'),
        marketCapFloat:        _d(f, 'marketCapFloat'),
        sharesOutstanding:     _d(f, 'sharesOutstanding'),
        bookValuePerShare:     _d(f, 'bookValuePerShare'),
        shortIntToFloat:       _d(f, 'shortIntToFloat'),
        shortIntDayToCover:    _d(f, 'shortIntDayToCover'),
        beta:                  _d(f, 'beta'),
        dividendYield:         _d(f, 'dividendYield'),
        dividendAmount:        _d(f, 'dividendAmount'),
        dividendPayAmount:     _d(f, 'dividendPayAmount'),
        divGrowthRate3Year:    _d(f, 'divGrowthRate3Year'),
        dividendFreq:          (f['dividendFreq'] as num? ?? 0).toInt(),
        dividendDate:          _parseDate(f, 'dividendDate'),
        dividendPayDate:       _parseDate(f, 'dividendPayDate'),
        nextDividendDate:      _parseDate(f, 'nextDividendDate'),
        nextDividendPayDate:   _parseDate(f, 'nextDividendPayDate'),
        declarationDate:       _parseDate(f, 'declarationDate'),
        // Schwab exposes volume under two key names depending on context
        vol1DayAvg:            _d(f, 'vol1DayAvg',   'avg1DayVolume'),
        vol10DayAvg:           _d(f, 'vol10DayAvg',  'avg10DaysVolume'),
        vol3MonthAvg:          _d(f, 'vol3MonthAvg', 'avg3MonthVolume'),
        nextEarningsDate:      _parseDate(f, 'nextEarningsDate'),
        lastEarningsDate:      _parseDate(f, 'lastEarningsDate'),
        fundLeverageFactor:    _d(f, 'fundLeverageFactor'),
        fundStrategy:          f['fundStrategy'] as String? ?? '',
      );
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
        dividendYield: fundamentals?.dividendYield ?? 0.0,
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

  Map<String, dynamic> toJson() => {
    'symbol':                 symbol,
    'strikePrice':            strikePrice,
    'bid':                    bid,
    'ask':                    ask,
    'last':                   last,
    'mark':                   markPrice,
    'bidSize':                bidSize,
    'askSize':                askSize,
    'highPrice':              highPrice,
    'lowPrice':               lowPrice,
    'delta':                  delta,
    'gamma':                  gamma,
    'theta':                  theta,
    'vega':                   vega,
    'rho':                    rho,
    'volatility':             impliedVolatility,
    'totalVolume':            totalVolume,
    'openInterest':           openInterest,
    'daysToExpiration':       daysToExpiration,
    'inTheMoney':             inTheMoney,
    'intrinsicValue':         intrinsicValue,
    'timeValue':              timeValue,
    'theoreticalOptionValue': theoreticalOptionValue,
    'expirationDate':         expirationDate,
  };
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
  final Map<String, dynamic>            rawJson;

  const SchwabOptionsChain({
    required this.symbol,
    required this.underlyingPrice,
    required this.volatility,
    required this.expirations,
    this.rawJson = const {},
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
      symbol:          json['symbol'] as String? ?? '',
      underlyingPrice: underlyingPrice,
      volatility:      volatility,
      expirations:     expirations,
      rawJson:         json,
    );
  }
}
