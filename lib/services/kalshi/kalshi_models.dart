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
        ticker: j['ticker']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        status: j['status']?.toString() ?? '',
        subtitle: j['subtitle']?.toString(),
        yesAsk: _toDouble(j['yes_ask']),
        yesBid: _toDouble(j['yes_bid']),
        noAsk: _toDouble(j['no_ask']),
        noBid: _toDouble(j['no_bid']),
        lastPrice: _toDouble(j['last_price']),
        volume: int.tryParse(j['volume']?.toString() ?? ''),
        openInterest: int.tryParse(j['open_interest']?.toString() ?? ''),
        expirationTime: j['expiration_time']?.toString(),
        closeTime: j['close_time']?.toString(),
      );

  static double? _toDouble(dynamic v) =>
      v == null ? null : double.tryParse(v.toString());

  // Kalshi prices are in cents (0–99); convert to probability
  double? get yesProbability => lastPrice != null ? lastPrice! / 100.0 : null;
}

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
        return KalshiOrderbookLevel(price: row[0] as int, quantity: row[1] as int);
      }).toList();
    }

    return KalshiOrderbook(
      ticker: ticker,
      yesBids: parseLevels('yes'),
      yesSells: parseLevels('no'),
    );
  }
}

class KalshiOrderbookLevel {
  final int price;     // cents
  final int quantity;

  const KalshiOrderbookLevel({required this.price, required this.quantity});
}

class KalshiEvent {
  final String eventTicker;
  final String title;
  final String status;
  final List<KalshiMarket> markets;

  const KalshiEvent({
    required this.eventTicker,
    required this.title,
    required this.status,
    required this.markets,
  });

  factory KalshiEvent.fromJson(Map<String, dynamic> j) => KalshiEvent(
        eventTicker: j['event_ticker']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        status: j['status']?.toString() ?? '',
        markets: ((j['markets']) as List? ?? [])
            .map((e) => KalshiMarket.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

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
        tradeId: j['trade_id']?.toString() ?? '',
        ticker: j['ticker']?.toString() ?? '',
        side: j['taker_side']?.toString() ?? '',
        price: int.tryParse(j['yes_price']?.toString() ?? '0') ?? 0,
        count: int.tryParse(j['count']?.toString() ?? '0') ?? 0,
        createdTime: j['created_time']?.toString() ?? '',
      );
}
