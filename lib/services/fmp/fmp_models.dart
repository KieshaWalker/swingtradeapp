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
        changePercent: (json['changesPercentage'] as num?)?.toDouble() ?? 0,
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
        exchange: json['exchangeShortName'] as String? ?? '',
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
