// =============================================================================
// services/kalshi/kalshi_models.dart
// =============================================================================

// ── Series ────────────────────────────────────────────────────────────────────

class KalshiSeries {
  final String ticker;
  final String title;
  final String? category;
  final List<String> tags;

  const KalshiSeries({
    required this.ticker,
    required this.title,
    this.category,
    this.tags = const [],
  });

  factory KalshiSeries.fromJson(Map<String, dynamic> j) => KalshiSeries(
        ticker:   j['ticker']?.toString() ?? '',
        title:    j['title']?.toString() ?? '',
        category: j['category']?.toString(),
        tags:     (j['tags'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

// ── Market ────────────────────────────────────────────────────────────────────

class KalshiMarket {
  final String ticker;
  final String title;
  final String status;
  final String? subtitle;
  final double? yesAsk;
  final double? yesBid;
  final double? noAsk;
  final double? noBid;
  final double? lastPrice;
  final int? volume;
  final int? openInterest;
  final String? expirationTime;
  final String? closeTime;

  const KalshiMarket({
    required this.ticker,
    required this.title,
    required this.status,
    this.subtitle,
    this.yesAsk,
    this.yesBid,
    this.noAsk,
    this.noBid,
    this.lastPrice,
    this.volume,
    this.openInterest,
    this.expirationTime,
    this.closeTime,
  });

  factory KalshiMarket.fromJson(Map<String, dynamic> j) => KalshiMarket(
        ticker:         j['ticker']?.toString() ?? '',
        title:          j['title']?.toString() ?? '',
        status:         j['status']?.toString() ?? '',
        subtitle:       (j['yes_sub_title'] ?? j['subtitle'])?.toString(),
        // API returns prices as dollar strings in 0.0–1.0 range ("yes_ask_dollars")
        yesAsk:         _toDouble(j['yes_ask_dollars']),
        yesBid:         _toDouble(j['yes_bid_dollars']),
        noAsk:          _toDouble(j['no_ask_dollars']),
        noBid:          _toDouble(j['no_bid_dollars']),
        lastPrice:      _toDouble(j['last_price_dollars']),
        // Volume and OI come as float strings ("volume_fp", "open_interest_fp")
        volume:         _toDouble(j['volume_fp'])?.toInt(),
        openInterest:   _toDouble(j['open_interest_fp'])?.toInt(),
        expirationTime: j['expiration_time']?.toString(),
        closeTime:      j['close_time']?.toString(),
      );

  static double? _toDouble(dynamic v) =>
      v == null ? null : double.tryParse(v.toString());

  // Prices are already 0.0–1.0 (dollar value where $1.00 = 100% probability)
  double? get yesProbability => lastPrice;

  // Best available yes price (ask when buying yes)
  double? get yesBestPrice => yesAsk ?? lastPrice;
}

// ── Orderbook ─────────────────────────────────────────────────────────────────

class KalshiOrderbook {
  final String ticker;
  final List<KalshiOrderbookLevel> yesBids;
  final List<KalshiOrderbookLevel> yesSells;

  const KalshiOrderbook({
    required this.ticker,
    required this.yesBids,
    required this.yesSells,
  });

  factory KalshiOrderbook.fromJson(String ticker, Map<String, dynamic> j) {
    final ob = j['orderbook'] as Map<String, dynamic>? ?? {};
    List<KalshiOrderbookLevel> parseLevels(String key) {
      final raw = ob[key] as List? ?? [];
      return raw.map((e) {
        final row = e as List;
        return KalshiOrderbookLevel(
            price: row[0] as int, quantity: row[1] as int);
      }).toList();
    }

    return KalshiOrderbook(
      ticker:    ticker,
      yesBids:   parseLevels('yes'),
      yesSells:  parseLevels('no'),
    );
  }
}

class KalshiOrderbookLevel {
  final int price;     // cents
  final int quantity;

  const KalshiOrderbookLevel({required this.price, required this.quantity});
}

// ── Event ─────────────────────────────────────────────────────────────────────

class KalshiEvent {
  final String eventTicker;
  final String title;
  final String status;
  final String? closeTime;       // ISO-8601; null for events without a set close
  final String? seriesTicker;
  final String? category;
  final List<KalshiMarket> markets;

  const KalshiEvent({
    required this.eventTicker,
    required this.title,
    required this.status,
    this.closeTime,
    this.seriesTicker,
    this.category,
    this.markets = const [],
  });

  factory KalshiEvent.fromJson(Map<String, dynamic> j) => KalshiEvent(
        eventTicker:  j['event_ticker']?.toString() ?? '',
        title:        j['title']?.toString() ?? '',
        status:       j['status']?.toString() ?? '',
        closeTime:    j['close_time']?.toString(),
        seriesTicker: j['series_ticker']?.toString(),
        category:     j['category']?.toString(),
        markets: ((j['markets']) as List? ?? [])
            .map((e) => KalshiMarket.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Returns the market with the highest yes probability (most likely outcome).
  KalshiMarket? get leadingMarket {
    if (markets.isEmpty) return null;
    return markets.reduce((a, b) =>
        (a.yesProbability ?? 0) >= (b.yesProbability ?? 0) ? a : b);
  }

  /// Parses closeTime into a DateTime (UTC). Returns null if unparseable.
  DateTime? get closeDateTime {
    if (closeTime == null) return null;
    return DateTime.tryParse(closeTime!);
  }

  /// True when this event's close time is before [expirationDate].
  bool closesBeforeExpiration(DateTime expirationDate) {
    final dt = closeDateTime;
    if (dt == null) return false;
    return dt.isBefore(expirationDate);
  }
}

// ── Trade ─────────────────────────────────────────────────────────────────────

class KalshiTrade {
  final String tradeId;
  final String ticker;
  final String side;
  final int price;
  final int count;
  final String createdTime;

  const KalshiTrade({
    required this.tradeId,
    required this.ticker,
    required this.side,
    required this.price,
    required this.count,
    required this.createdTime,
  });

  factory KalshiTrade.fromJson(Map<String, dynamic> j) => KalshiTrade(
        tradeId:     j['trade_id']?.toString() ?? '',
        ticker:      j['ticker']?.toString() ?? '',
        side:        j['taker_side']?.toString() ?? '',
        price:       int.tryParse(j['yes_price']?.toString() ?? '0') ?? 0,
        count:       int.tryParse(j['count']?.toString() ?? '0') ?? 0,
        createdTime: j['created_time']?.toString() ?? '',
      );
}

// ── WebSocket ticker update ───────────────────────────────────────────────────

/// Parsed payload from the Kalshi WS `ticker` channel.
class KalshiTickerUpdate {
  final String marketTicker;
  final double yesProbability;   // 0.0–1.0
  final double? yesAsk;
  final double? yesBid;
  final int? volume;

  const KalshiTickerUpdate({
    required this.marketTicker,
    required this.yesProbability,
    this.yesAsk,
    this.yesBid,
    this.volume,
  });

  factory KalshiTickerUpdate.fromJson(Map<String, dynamic> j) {
    double? cents(dynamic v) =>
        v == null ? null : double.tryParse(v.toString());

    final price = cents(j['yes'] ?? j['yes_price'] ?? j['price']) ?? 0.0;
    return KalshiTickerUpdate(
      marketTicker:   j['market_ticker']?.toString() ?? '',
      yesProbability: price / 100.0,
      yesAsk:         cents(j['yes_ask']),
      yesBid:         cents(j['yes_bid']),
      volume:         int.tryParse(j['volume']?.toString() ?? ''),
    );
  }
}
