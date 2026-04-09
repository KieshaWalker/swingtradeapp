// =============================================================================
// features/trades/models/trade.dart — Core trade data model
// =============================================================================
// Enums:
//   OptionType      { call, put }
//   TradeStrategy   { longCall, longPut, bullCallSpread, bearPutSpread,
//                     bullPutSpread, bearCallSpread, ironCondor, other }
//   TradeStatus     { open, closed, expired }
//   EntryPointType  { atm, itm, otm }
//
// Trade (class):
//   Computed getters:
//     costBasis   — entryPrice × contracts × 100
//     realizedPnl — (exitPrice - entryPrice) × contracts × 100
//     pnlPercent  — realizedPnl / costBasis × 100
//     isProfitable— realizedPnl > 0
//
//   New option-specific fields (from CSV journal):
//     priceRangeHigh, priceRangeLow   — underlying price range at entry
//     impliedVolEntry, impliedVolExit  — IV snapshot at entry/exit
//     intradaySupport, intradayResistance
//     dailyBreakoutLevel, dailyBreakdownLevel
//     entryPointType                   — ATM / ITM / OTM selection
//     maxLoss                          — max dollar risk for this trade
//     timeOfEntry, timeOfExit          — HH:mm strings
// =============================================================================
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

enum EntryPointType { atm, itm, otm }

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

extension EntryPointTypeExt on EntryPointType {
  String get label => switch (this) {
        EntryPointType.atm => 'ATM',
        EntryPointType.itm => 'ITM',
        EntryPointType.otm => 'OTM',
      };

  static EntryPointType fromDb(String v) => switch (v.toLowerCase()) {
        'itm' => EntryPointType.itm,
        'otm' => EntryPointType.otm,
        _ => EntryPointType.atm,
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

  // New option-specific setup fields
  final double? priceRangeHigh;
  final double? priceRangeLow;
  final double? impliedVolEntry;
  final double? impliedVolExit;
  final double? intradaySupport;
  final double? intradayResistance;
  final double? dailyBreakoutLevel;
  final double? dailyBreakdownLevel;
  final EntryPointType? entryPointType;
  final double? maxLoss;
  final String? timeOfEntry;
  final String? timeOfExit;

  // Risk management levels (migration 013)
  final double? stopLoss;
  final double? takeProfit;

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
    this.priceRangeHigh,
    this.priceRangeLow,
    this.impliedVolEntry,
    this.impliedVolExit,
    this.intradaySupport,
    this.intradayResistance,
    this.dailyBreakoutLevel,
    this.dailyBreakdownLevel,
    this.entryPointType,
    this.maxLoss,
    this.timeOfEntry,
    this.timeOfExit,
    this.stopLoss,
    this.takeProfit,
  });

  double get costBasis => entryPrice * contracts * 100;

  /// Unrealized P&L using a live mark price (transient — not stored in DB).
  double unrealizedPnl(double currentMark) =>
      (currentMark - entryPrice) * contracts * 100;

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
        priceRangeHigh: json['price_range_high'] != null
            ? (json['price_range_high'] as num).toDouble()
            : null,
        priceRangeLow: json['price_range_low'] != null
            ? (json['price_range_low'] as num).toDouble()
            : null,
        impliedVolEntry: json['implied_vol_entry'] != null
            ? (json['implied_vol_entry'] as num).toDouble()
            : null,
        impliedVolExit: json['implied_vol_exit'] != null
            ? (json['implied_vol_exit'] as num).toDouble()
            : null,
        intradaySupport: json['intraday_support'] != null
            ? (json['intraday_support'] as num).toDouble()
            : null,
        intradayResistance: json['intraday_resistance'] != null
            ? (json['intraday_resistance'] as num).toDouble()
            : null,
        dailyBreakoutLevel: json['daily_breakout_level'] != null
            ? (json['daily_breakout_level'] as num).toDouble()
            : null,
        dailyBreakdownLevel: json['daily_breakdown_level'] != null
            ? (json['daily_breakdown_level'] as num).toDouble()
            : null,
        entryPointType: json['entry_point_type'] != null
            ? EntryPointTypeExt.fromDb(json['entry_point_type'] as String)
            : null,
        maxLoss: json['max_loss'] != null
            ? (json['max_loss'] as num).toDouble()
            : null,
        timeOfEntry: json['time_of_entry'] as String?,
        timeOfExit: json['time_of_exit'] as String?,
        stopLoss: json['stop_loss'] != null
            ? (json['stop_loss'] as num).toDouble()
            : null,
        takeProfit: json['take_profit'] != null
            ? (json['take_profit'] as num).toDouble()
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
        'price_range_high': priceRangeHigh,
        'price_range_low': priceRangeLow,
        'implied_vol_entry': impliedVolEntry,
        'implied_vol_exit': impliedVolExit,
        'intraday_support': intradaySupport,
        'intraday_resistance': intradayResistance,
        'daily_breakout_level': dailyBreakoutLevel,
        'daily_breakdown_level': dailyBreakdownLevel,
        'entry_point_type': entryPointType?.name,
        'max_loss': maxLoss,
        'time_of_entry': timeOfEntry,
        'time_of_exit': timeOfExit,
        'stop_loss': stopLoss,
        'take_profit': takeProfit,
      };
}
