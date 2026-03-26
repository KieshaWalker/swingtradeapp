// =============================================================================
// features/ticker_profile/models/ticker_profile_models.dart
// =============================================================================
// All data models for the Ticker Profile feature.
//
// Stored models (Supabase-backed):
//   TickerProfileNote       — timestamped free-text observations
//   SupportResistanceLevel  — price levels with lifecycle tracking
//   TickerInsiderBuy        — curated Form 4 buy events
//   TickerEarningsReaction  — post-earnings move data per quarter
//
// Computed models (pure Dart, derived from trades table):
//   StrategyStats           — per-strategy trade performance
//   TickerTradeAnalytics    — full "when I trade it best" analysis
//
// Timeline model:
//   TickerTimelineEvent     — unified event for the merged feed
// =============================================================================

import '../../trades/models/trade.dart';
import '../../../services/sec/sec_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TICKER PROFILE NOTE
// ─────────────────────────────────────────────────────────────────────────────

class TickerProfileNote {
  final String id;
  final String userId;
  final String ticker;
  final String body;
  final List<String> tags;
  final DateTime createdAt;

  const TickerProfileNote({
    required this.id,
    required this.userId,
    required this.ticker,
    required this.body,
    required this.tags,
    required this.createdAt,
  });

  factory TickerProfileNote.fromJson(Map<String, dynamic> json) =>
      TickerProfileNote(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ticker: json['ticker'] as String,
        body: json['body'] as String,
        tags: json['tags'] != null
            ? List<String>.from(json['tags'] as List)
            : [],
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'body': body,
        'tags': tags,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// SUPPORT / RESISTANCE LEVEL
// ─────────────────────────────────────────────────────────────────────────────

enum SRLevelType { support, resistance }

enum SRTimeframe { intraday, daily, weekly, monthly }

extension SRTimeframeExt on SRTimeframe {
  String get label => switch (this) {
        SRTimeframe.intraday => 'Intraday',
        SRTimeframe.daily => 'Daily',
        SRTimeframe.weekly => 'Weekly',
        SRTimeframe.monthly => 'Monthly',
      };
}

class SupportResistanceLevel {
  final String id;
  final String userId;
  final String ticker;
  final SRLevelType levelType;
  final double price;
  final String? label;
  final SRTimeframe? timeframe;
  final DateTime notedAt;
  final DateTime? invalidatedAt;
  final String? invalidationNote;

  const SupportResistanceLevel({
    required this.id,
    required this.userId,
    required this.ticker,
    required this.levelType,
    required this.price,
    this.label,
    this.timeframe,
    required this.notedAt,
    this.invalidatedAt,
    this.invalidationNote,
  });

  bool get isActive => invalidatedAt == null;

  factory SupportResistanceLevel.fromJson(Map<String, dynamic> json) =>
      SupportResistanceLevel(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ticker: json['ticker'] as String,
        levelType: json['level_type'] == 'resistance'
            ? SRLevelType.resistance
            : SRLevelType.support,
        price: (json['price'] as num).toDouble(),
        label: json['label'] as String?,
        timeframe: json['timeframe'] != null
            ? SRTimeframe.values.firstWhere(
                (t) => t.name == json['timeframe'],
                orElse: () => SRTimeframe.daily,
              )
            : null,
        notedAt: DateTime.parse(json['noted_at'] as String),
        invalidatedAt: json['invalidated_at'] != null
            ? DateTime.parse(json['invalidated_at'] as String)
            : null,
        invalidationNote: json['invalidation_note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'level_type': levelType.name,
        'price': price,
        'label': label,
        'timeframe': timeframe?.name,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// INSIDER BUY
// ─────────────────────────────────────────────────────────────────────────────

enum InsiderTransactionType { purchase, sale, exercise, gift, taxWithholding, other }

extension InsiderTransactionTypeLabel on InsiderTransactionType {
  String get label => switch (this) {
        InsiderTransactionType.purchase => 'Purchase',
        InsiderTransactionType.sale => 'Sale',
        InsiderTransactionType.exercise => 'Exercise',
        InsiderTransactionType.gift => 'Gift',
        InsiderTransactionType.taxWithholding => 'Tax Withholding',
        InsiderTransactionType.other => 'Other',
      };
}

class TickerInsiderBuy {
  final String id;
  final String userId;
  final String ticker;
  final String insiderName;
  final String? insiderTitle;
  final int shares;
  final double? pricePerShare;
  final double? totalValue;
  final DateTime filedAt;
  final DateTime? transactionDate;
  final String? accessionNo;
  final InsiderTransactionType transactionType;
  final String? notes;

  const TickerInsiderBuy({
    required this.id,
    required this.userId,
    required this.ticker,
    required this.insiderName,
    this.insiderTitle,
    required this.shares,
    this.pricePerShare,
    this.totalValue,
    required this.filedAt,
    this.transactionDate,
    this.accessionNo,
    required this.transactionType,
    this.notes,
  });

  factory TickerInsiderBuy.fromJson(Map<String, dynamic> json) =>
      TickerInsiderBuy(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ticker: json['ticker'] as String,
        insiderName: json['insider_name'] as String,
        insiderTitle: json['insider_title'] as String?,
        shares: json['shares'] as int,
        pricePerShare: json['price_per_share'] != null
            ? (json['price_per_share'] as num).toDouble()
            : null,
        totalValue: json['total_value'] != null
            ? (json['total_value'] as num).toDouble()
            : null,
        filedAt: DateTime.parse(json['filed_at'] as String),
        transactionDate: json['transaction_date'] != null
            ? DateTime.parse(json['transaction_date'] as String)
            : null,
        accessionNo: json['accession_no'] as String?,
        transactionType: _txTypeFromDb(json['transaction_type'] as String),
        notes: json['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'insider_name': insiderName,
        'insider_title': insiderTitle,
        'shares': shares,
        'price_per_share': pricePerShare,
        'total_value': totalValue,
        'filed_at': filedAt.toIso8601String().split('T').first,
        'transaction_date':
            transactionDate?.toIso8601String().split('T').first,
        'accession_no': accessionNo,
        'transaction_type': _txTypeToDb(transactionType),
        'notes': notes,
      };
}

String _txTypeToDb(InsiderTransactionType t) => switch (t) {
      InsiderTransactionType.taxWithholding => 'tax_withholding',
      _ => t.name,
    };

InsiderTransactionType _txTypeFromDb(String s) => switch (s) {
      'tax_withholding' => InsiderTransactionType.taxWithholding,
      _ => InsiderTransactionType.values.firstWhere(
            (t) => t.name == s,
            orElse: () => InsiderTransactionType.other,
          ),
    };

// ─────────────────────────────────────────────────────────────────────────────
// EARNINGS REACTION
// ─────────────────────────────────────────────────────────────────────────────

class TickerEarningsReaction {
  final String id;
  final String userId;
  final String ticker;
  final DateTime earningsDate;
  final String? fiscalPeriod;
  final double? epsActual;
  final double? epsEstimate;
  final double? epsSurprisePct;
  final double? revenueActual;
  final double? revenueEstimate;
  final double? priceBefore;
  final double? priceAfter;
  final double? movePct;
  final String? direction;
  final double? ivRankBefore;
  final double? ivRankAfter;
  final String? notes;

  const TickerEarningsReaction({
    required this.id,
    required this.userId,
    required this.ticker,
    required this.earningsDate,
    this.fiscalPeriod,
    this.epsActual,
    this.epsEstimate,
    this.epsSurprisePct,
    this.revenueActual,
    this.revenueEstimate,
    this.priceBefore,
    this.priceAfter,
    this.movePct,
    this.direction,
    this.ivRankBefore,
    this.ivRankAfter,
    this.notes,
  });

  bool get beat =>
      epsActual != null &&
      epsEstimate != null &&
      epsActual! > epsEstimate!;

  factory TickerEarningsReaction.fromJson(Map<String, dynamic> json) =>
      TickerEarningsReaction(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        ticker: json['ticker'] as String,
        earningsDate: DateTime.parse(json['earnings_date'] as String),
        fiscalPeriod: json['fiscal_period'] as String?,
        epsActual: (json['eps_actual'] as num?)?.toDouble(),
        epsEstimate: (json['eps_estimate'] as num?)?.toDouble(),
        epsSurprisePct: (json['eps_surprise_pct'] as num?)?.toDouble(),
        revenueActual: (json['revenue_actual'] as num?)?.toDouble(),
        revenueEstimate: (json['revenue_estimate'] as num?)?.toDouble(),
        priceBefore: (json['price_before'] as num?)?.toDouble(),
        priceAfter: (json['price_after'] as num?)?.toDouble(),
        movePct: (json['move_pct'] as num?)?.toDouble(),
        direction: json['direction'] as String?,
        ivRankBefore: (json['iv_rank_before'] as num?)?.toDouble(),
        ivRankAfter: (json['iv_rank_after'] as num?)?.toDouble(),
        notes: json['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'earnings_date': earningsDate.toIso8601String().split('T').first,
        'fiscal_period': fiscalPeriod,
        'eps_actual': epsActual,
        'eps_estimate': epsEstimate,
        'eps_surprise_pct': epsSurprisePct,
        'revenue_actual': revenueActual,
        'revenue_estimate': revenueEstimate,
        'price_before': priceBefore,
        'price_after': priceAfter,
        'move_pct': movePct,
        'direction': direction,
        'iv_rank_before': ivRankBefore,
        'iv_rank_after': ivRankAfter,
        'notes': notes,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// TRADE ANALYTICS  (computed from trades table, never stored)
// ─────────────────────────────────────────────────────────────────────────────

class StrategyStats {
  final int count;
  final int wins;
  final double winRate;
  final double avgReturn;
  final double totalPnl;

  const StrategyStats({
    required this.count,
    required this.wins,
    required this.winRate,
    required this.avgReturn,
    required this.totalPnl,
  });
}

class TickerTradeAnalytics {
  final String ticker;
  final int totalTrades;
  final int winCount;
  final int lossCount;
  final double winRate;
  final double avgReturn;
  final double totalRealizedPnl;
  final double avgIvRankAtEntry;
  final TradeStrategy? bestStrategy;
  final (int, int)? bestDteRange;
  final (double, double)? bestIvRankRange;
  final Map<int, double> monthlyPnl; // key = year*100+month
  final Map<TradeStrategy, StrategyStats> strategyBreakdown;
  final String? playbookSummary;

  const TickerTradeAnalytics({
    required this.ticker,
    required this.totalTrades,
    required this.winCount,
    required this.lossCount,
    required this.winRate,
    required this.avgReturn,
    required this.totalRealizedPnl,
    required this.avgIvRankAtEntry,
    this.bestStrategy,
    this.bestDteRange,
    this.bestIvRankRange,
    required this.monthlyPnl,
    required this.strategyBreakdown,
    this.playbookSummary,
  });

  bool get hasEnoughData => totalTrades >= 5;

  static TickerTradeAnalytics empty(String ticker) => TickerTradeAnalytics(
        ticker: ticker,
        totalTrades: 0,
        winCount: 0,
        lossCount: 0,
        winRate: 0,
        avgReturn: 0,
        totalRealizedPnl: 0,
        avgIvRankAtEntry: 0,
        monthlyPnl: {},
        strategyBreakdown: {},
      );

  /// Compute analytics from a list of trades for this ticker.
  static TickerTradeAnalytics compute(String ticker, List<Trade> allTrades) {
    final closed = allTrades
        .where((t) =>
            t.ticker.toUpperCase() == ticker.toUpperCase() &&
            t.status == TradeStatus.closed &&
            t.realizedPnl != null)
        .toList();

    if (closed.isEmpty) return empty(ticker);

    final total = closed.length;
    final wins = closed.where((t) => t.isProfitable).length;
    final winRate = wins / total;
    final avgReturn =
        closed.fold(0.0, (s, t) => s + (t.pnlPercent ?? 0)) / total;
    final totalPnl =
        closed.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0));

    // Average IV rank at entry
    final ivTrades = closed.where((t) => t.ivRank != null).toList();
    final avgIv = ivTrades.isEmpty
        ? 0.0
        : ivTrades.fold(0.0, (s, t) => s + t.ivRank!) / ivTrades.length;

    // Strategy breakdown
    final stratMap = <TradeStrategy, List<Trade>>{};
    for (final t in closed) {
      stratMap.putIfAbsent(t.strategy, () => []).add(t);
    }
    final stratBreakdown = stratMap.map((s, trades) {
      final w = trades.where((t) => t.isProfitable).length;
      return MapEntry(
        s,
        StrategyStats(
          count: trades.length,
          wins: w,
          winRate: w / trades.length,
          avgReturn: trades.fold(0.0, (sum, t) => sum + (t.pnlPercent ?? 0)) /
              trades.length,
          totalPnl:
              trades.fold(0.0, (sum, t) => sum + (t.realizedPnl ?? 0)),
        ),
      );
    });

    // Best strategy (min 2 trades)
    final qualStrats = stratBreakdown.entries
        .where((e) => e.value.count >= 2)
        .toList()
      ..sort((a, b) => b.value.winRate.compareTo(a.value.winRate));
    final bestStrategy =
        qualStrats.isEmpty ? null : qualStrats.first.key;

    // DTE bucketing
    const dteBuckets = [
      (0, 7),
      (8, 14),
      (15, 30),
      (31, 60),
      (61, 9999)
    ];
    final dteTrades =
        closed.where((t) => t.dteAtEntry != null).toList();
    (int, int)? bestDteRange;
    double bestDteWr = -1;
    for (final b in dteBuckets) {
      final inB = dteTrades
          .where((t) => t.dteAtEntry! >= b.$1 && t.dteAtEntry! <= b.$2)
          .toList();
      if (inB.length < 2) continue;
      final wr = inB.where((t) => t.isProfitable).length / inB.length;
      if (wr > bestDteWr) {
        bestDteWr = wr;
        bestDteRange = b;
      }
    }

    // IV rank bucketing
    const ivBuckets = [
      (0.0, 20.0),
      (20.0, 40.0),
      (40.0, 60.0),
      (60.0, 80.0),
      (80.0, 100.0),
    ];
    (double, double)? bestIvRange;
    double bestIvWr = -1;
    for (final b in ivBuckets) {
      final inB = ivTrades
          .where((t) => t.ivRank! >= b.$1 && t.ivRank! <= b.$2)
          .toList();
      if (inB.length < 2) continue;
      final wr = inB.where((t) => t.isProfitable).length / inB.length;
      if (wr > bestIvWr) {
        bestIvWr = wr;
        bestIvRange = b;
      }
    }

    // Monthly P&L map
    final monthlyPnl = <int, double>{};
    for (final t in closed) {
      if (t.closedAt == null) continue;
      final key = t.closedAt!.year * 100 + t.closedAt!.month;
      monthlyPnl[key] = (monthlyPnl[key] ?? 0) + (t.realizedPnl ?? 0);
    }

    // Playbook summary (5+ trades required)
    String? playbook;
    if (total >= 5 && bestStrategy != null) {
      final pct = (winRate * 100).toStringAsFixed(0);
      playbook = 'You win $pct% trading ${bestStrategy.label}';
      if (bestDteRange != null) {
        final dteLabel = bestDteRange.$2 >= 9999
            ? '${bestDteRange.$1}+ DTE'
            : '${bestDteRange.$1}–${bestDteRange.$2} DTE';
        playbook += ' with $dteLabel';
      }
      if (bestIvRange != null) {
        playbook +=
            ' when IV Rank is ${bestIvRange.$1.toStringAsFixed(0)}–${bestIvRange.$2.toStringAsFixed(0)}.';
      } else {
        playbook += '.';
      }
    }

    return TickerTradeAnalytics(
      ticker: ticker,
      totalTrades: total,
      winCount: wins,
      lossCount: total - wins,
      winRate: winRate,
      avgReturn: avgReturn,
      totalRealizedPnl: totalPnl,
      avgIvRankAtEntry: avgIv,
      bestStrategy: bestStrategy,
      bestDteRange: bestDteRange,
      bestIvRankRange: bestIvRange,
      monthlyPnl: monthlyPnl,
      strategyBreakdown: stratBreakdown,
      playbookSummary: playbook,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TIMELINE EVENT  (merged feed — never stored)
// ─────────────────────────────────────────────────────────────────────────────

enum TimelineEventType {
  tradeOpened,
  tradeClosed,
  note,
  secFiling,
  earningsReaction,
  srLevelAdded,
  srLevelInvalidated,
  insiderBuy,
}

class TickerTimelineEvent {
  final DateTime timestamp;
  final TimelineEventType type;
  final String summary;

  // Exactly one of these is non-null depending on type
  final Trade? trade;
  final TickerProfileNote? note;
  final SecFiling? secFiling;
  final TickerEarningsReaction? earningsReaction;
  final SupportResistanceLevel? srLevel;
  final TickerInsiderBuy? insiderBuy;

  const TickerTimelineEvent({
    required this.timestamp,
    required this.type,
    required this.summary,
    this.trade,
    this.note,
    this.secFiling,
    this.earningsReaction,
    this.srLevel,
    this.insiderBuy,
  });
}
