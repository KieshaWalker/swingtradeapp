// =============================================================================
// features/trades/models/trade_journal.dart — Post-trade reflection model
// =============================================================================
// Enums:
//   DailyTrend  { bullish, bearish, sideways, choppy }
//   TradeGrade  { a, b, c, d, f }
//
// TradeJournal: mirrors the trade_journal Supabase table.
//   One-to-one with a Trade (unique trade_id FK).
//   Created/updated from TradeJournalScreen after a trade is closed.
// =============================================================================

enum DailyTrend { bullish, bearish, sideways, choppy }

extension DailyTrendExt on DailyTrend {
  String get label => switch (this) {
        DailyTrend.bullish => 'Bullish',
        DailyTrend.bearish => 'Bearish',
        DailyTrend.sideways => 'Sideways',
        DailyTrend.choppy => 'Choppy',
      };

  static DailyTrend fromDb(String v) => switch (v.toLowerCase()) {
        'bearish' => DailyTrend.bearish,
        'sideways' => DailyTrend.sideways,
        'choppy' => DailyTrend.choppy,
        _ => DailyTrend.bullish,
      };
}

enum TradeGrade { a, b, c, d, f }

extension TradeGradeExt on TradeGrade {
  String get label => name.toUpperCase();

  static TradeGrade fromDb(String v) => switch (v.toLowerCase()) {
        'b' => TradeGrade.b,
        'c' => TradeGrade.c,
        'd' => TradeGrade.d,
        'f' => TradeGrade.f,
        _ => TradeGrade.a,
      };
}

class TradeJournal {
  final String id;
  final String tradeId;
  final String userId;

  // Reflection
  final DailyTrend? dailyTrend;
  final double? rMultiple;
  final TradeGrade? grade;
  final String? tag;
  final String? mistakes;
  final bool? exitedTooSoon;
  final bool? followedStopLoss;
  final bool? meditation;
  final bool? tookBreaks;
  final String? mindsetNotes;
  final String? postTradeNotes;

  // Research
  final double? shortPct;
  final double? institutionalPct;
  final double? sharesShorted;
  final double? prevMonthSharesShorted;
  final String? generalNews;

  final DateTime createdAt;
  final DateTime updatedAt;

  const TradeJournal({
    required this.id,
    required this.tradeId,
    required this.userId,
    this.dailyTrend,
    this.rMultiple,
    this.grade,
    this.tag,
    this.mistakes,
    this.exitedTooSoon,
    this.followedStopLoss,
    this.meditation,
    this.tookBreaks,
    this.mindsetNotes,
    this.postTradeNotes,
    this.shortPct,
    this.institutionalPct,
    this.sharesShorted,
    this.prevMonthSharesShorted,
    this.generalNews,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TradeJournal.fromJson(Map<String, dynamic> json) => TradeJournal(
        id: json['id'] as String,
        tradeId: json['trade_id'] as String,
        userId: json['user_id'] as String,
        dailyTrend: json['daily_trend'] != null
            ? DailyTrendExt.fromDb(json['daily_trend'] as String)
            : null,
        rMultiple: json['r_multiple'] != null
            ? (json['r_multiple'] as num).toDouble()
            : null,
        grade: json['grade'] != null
            ? TradeGradeExt.fromDb(json['grade'] as String)
            : null,
        tag: json['tag'] as String?,
        mistakes: json['mistakes'] as String?,
        exitedTooSoon: json['exited_too_soon'] as bool?,
        followedStopLoss: json['followed_stop_loss'] as bool?,
        meditation: json['meditation'] as bool?,
        tookBreaks: json['took_breaks'] as bool?,
        mindsetNotes: json['mindset_notes'] as String?,
        postTradeNotes: json['post_trade_notes'] as String?,
        shortPct: json['short_pct'] != null
            ? (json['short_pct'] as num).toDouble()
            : null,
        institutionalPct: json['institutional_pct'] != null
            ? (json['institutional_pct'] as num).toDouble()
            : null,
        sharesShorted: json['shares_shorted'] != null
            ? (json['shares_shorted'] as num).toDouble()
            : null,
        prevMonthSharesShorted: json['prev_month_shares_shorted'] != null
            ? (json['prev_month_shares_shorted'] as num).toDouble()
            : null,
        generalNews: json['general_news'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Map<String, dynamic> toUpsertJson(String userId) => {
        'trade_id': tradeId,
        'user_id': userId,
        'daily_trend': dailyTrend?.name,
        'r_multiple': rMultiple,
        'grade': grade?.name,
        'tag': tag,
        'mistakes': mistakes,
        'exited_too_soon': exitedTooSoon,
        'followed_stop_loss': followedStopLoss,
        'meditation': meditation,
        'took_breaks': tookBreaks,
        'mindset_notes': mindsetNotes,
        'post_trade_notes': postTradeNotes,
        'short_pct': shortPct,
        'institutional_pct': institutionalPct,
        'shares_shorted': sharesShorted,
        'prev_month_shares_shorted': prevMonthSharesShorted,
        'general_news': generalNews,
        'updated_at': DateTime.now().toIso8601String(),
      };
}
