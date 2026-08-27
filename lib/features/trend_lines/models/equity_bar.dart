// =============================================================================
// features/trend_lines/models/equity_bar.dart
// =============================================================================
// One daily OHLC bar, read straight from equity_bars for chart rendering.
// Purely a display model — nothing here computes anything the backend hasn't
// already computed; equity_bars_pull.py is the one writer.
// =============================================================================

class EquityBar {
  final DateTime date;
  final double open;
  final double high;
  final double low;
  final double close;

  const EquityBar({
    required this.date,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  bool get isUp => close >= open;

  factory EquityBar.fromJson(Map<String, dynamic> j) => EquityBar(
        // Plain date column — never shifted between zones.
        date: DateTime.parse(j['bar_date'] as String),
        open: (j['open'] as num).toDouble(),
        high: (j['high'] as num).toDouble(),
        low: (j['low'] as num).toDouble(),
        close: (j['close'] as num).toDouble(),
      );
}
