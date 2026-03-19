import 'package:intl/intl.dart';

enum OptionType { call, put }

enum TradeStrategy {
  longCall,
  longPut,
  bullCallSpread,
  bearPutSpread,
  bullPutSpread,
  bearCallSpread,
  ironCondor,
  other,
}

enum TradeStatus { open, closed, expired }

extension TradeStrategyExt on TradeStrategy {
  String get label => switch (this) {
        TradeStrategy.longCall => 'Long Call',
        TradeStrategy.longPut => 'Long Put',
        TradeStrategy.bullCallSpread => 'Bull Call Spread',
        TradeStrategy.bearPutSpread => 'Bear Put Spread',
        TradeStrategy.bullPutSpread => 'Bull Put Spread',
        TradeStrategy.bearCallSpread => 'Bear Call Spread',
        TradeStrategy.ironCondor => 'Iron Condor',
        TradeStrategy.other => 'Other',
      };

  String get dbValue => switch (this) {
        TradeStrategy.longCall => 'long_call',
        TradeStrategy.longPut => 'long_put',
        TradeStrategy.bullCallSpread => 'bull_call_spread',
        TradeStrategy.bearPutSpread => 'bear_put_spread',
        TradeStrategy.bullPutSpread => 'bull_put_spread',
        TradeStrategy.bearCallSpread => 'bear_call_spread',
        TradeStrategy.ironCondor => 'iron_condor',
        TradeStrategy.other => 'other',
      };

  static TradeStrategy fromDb(String v) => switch (v) {
        'long_call' => TradeStrategy.longCall,
        'long_put' => TradeStrategy.longPut,
        'bull_call_spread' => TradeStrategy.bullCallSpread,
        'bear_put_spread' => TradeStrategy.bearPutSpread,
        'bull_put_spread' => TradeStrategy.bullPutSpread,
        'bear_call_spread' => TradeStrategy.bearCallSpread,
        'iron_condor' => TradeStrategy.ironCondor,
        _ => TradeStrategy.other,
      };
}

class Trade {
  final String id;
  final String userId;
  final String ticker;
  final OptionType optionType;
  final TradeStrategy strategy;
  final double strike;
  final DateTime expiration;
  final int? dteAtEntry;
  final int contracts;
  final double entryPrice;
  final double? exitPrice;
  final TradeStatus status;
  final double? ivRank;
  final double? delta;
  final String? notes;
  final DateTime openedAt;
  final DateTime? closedAt;

  const Trade({
    required this.id,
    required this.userId,
    required this.ticker,
    required this.optionType,
    required this.strategy,
    required this.strike,
    required this.expiration,
    this.dteAtEntry,
    required this.contracts,
    required this.entryPrice,
    this.exitPrice,
    required this.status,
    this.ivRank,
    this.delta,
    this.notes,
    required this.openedAt,
    this.closedAt,
  });

  double get costBasis => entryPrice * contracts * 100;

  double? get realizedPnl {
    if (exitPrice == null) return null;
    return (exitPrice! - entryPrice) * contracts * 100;
  }

  double? get pnlPercent {
    if (realizedPnl == null) return null;
    return (realizedPnl! / costBasis) * 100;
  }

  bool get isProfitable => (realizedPnl ?? 0) > 0;

  factory Trade.fromJson(Map<String, dynamic> json) => Trade(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ticker: json['ticker'] as String,
        optionType: json['option_type'] == 'call' ? OptionType.call : OptionType.put,
        strategy: TradeStrategyExt.fromDb(json['strategy'] as String),
        strike: (json['strike'] as num).toDouble(),
        expiration: DateTime.parse(json['expiration'] as String),
        dteAtEntry: json['dte_at_entry'] as int?,
        contracts: json['contracts'] as int,
        entryPrice: (json['entry_price'] as num).toDouble(),
        exitPrice: json['exit_price'] != null
            ? (json['exit_price'] as num).toDouble()
            : null,
        status: switch (json['status'] as String) {
          'closed' => TradeStatus.closed,
          'expired' => TradeStatus.expired,
          _ => TradeStatus.open,
        },
        ivRank: json['iv_rank'] != null ? (json['iv_rank'] as num).toDouble() : null,
        delta: json['delta'] != null ? (json['delta'] as num).toDouble() : null,
        notes: json['notes'] as String?,
        openedAt: DateTime.parse(json['opened_at'] as String),
        closedAt: json['closed_at'] != null
            ? DateTime.parse(json['closed_at'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'option_type': optionType.name,
        'strategy': strategy.dbValue,
        'strike': strike,
        'expiration': DateFormat('yyyy-MM-dd').format(expiration),
        'dte_at_entry': dteAtEntry,
        'contracts': contracts,
        'entry_price': entryPrice,
        'exit_price': exitPrice,
        'status': status.name,
        'iv_rank': ivRank,
        'delta': delta,
        'notes': notes,
      };
}
