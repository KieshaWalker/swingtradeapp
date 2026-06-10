// =============================================================================
// features/strategy_tracker/models/strategy_models.dart
// =============================================================================
// Enums:
//   VolumeCondition     { aboveAvg, belowAvg, any }
//   SetupStatus         { hot, warm, neutral, cold, dead, recovering, insufficient }
//   TargetArea          { sma20…sma200, allTimeHigh, allTimeLow, weekHigh52,
//                         weekLow52, priorHigh, priorLow, gapFill,
//                         breakoutLevel, srZone }
//
// Criteria classes (serialized to/from JSONB in strategy_setups):
//   SmaCondition        — {sma: 20, position: "above"|"below"}
//   VixCondition        — {operator: "lt"|"gt"|"between", value?, low?, high?}
//   SpyCondition        — {type: "sma"|"area", sma?, position?, area?}
//
// StrategySetup:
//   Holds List<Trade> linkedTrades (all statuses, populated by provider).
//   Computed getters derive win-rate, profit-factor, expectancy, status, etc.
//   closedTrades  — subset where status != open (used for all stat math)
//   scoredTrades  — closedTrades with realizedPnl != null (wins/losses definite)
//   allCriteriaLabels — flat list of human-readable criteria for UI display
//   targetAreas   — where the trade is intended to reach (separate from entry)
// =============================================================================
import 'package:flutter/material.dart';
import '../../trades/models/trade.dart';

// ── TargetArea ────────────────────────────────────────────────────────────────
// Where the trade aims to reach. Stored as text[] in strategy_setups.

enum TargetArea {
  sma20, sma50, sma100, sma200,
  allTimeHigh, allTimeLow,
  weekHigh52, weekLow52,
  priorHigh, priorLow,
  gapFill, breakoutLevel, srZone,
}

extension TargetAreaExt on TargetArea {
  String get dbValue => switch (this) {
        TargetArea.sma20         => '20_sma',
        TargetArea.sma50         => '50_sma',
        TargetArea.sma100        => '100_sma',
        TargetArea.sma200        => '200_sma',
        TargetArea.allTimeHigh   => 'all_time_high',
        TargetArea.allTimeLow    => 'all_time_low',
        TargetArea.weekHigh52    => '52w_high',
        TargetArea.weekLow52     => '52w_low',
        TargetArea.priorHigh     => 'prior_high',
        TargetArea.priorLow      => 'prior_low',
        TargetArea.gapFill       => 'gap_fill',
        TargetArea.breakoutLevel => 'breakout',
        TargetArea.srZone        => 'sr_zone',
      };

  String get label => switch (this) {
        TargetArea.sma20         => '20 SMA',
        TargetArea.sma50         => '50 SMA',
        TargetArea.sma100        => '100 SMA',
        TargetArea.sma200        => '200 SMA',
        TargetArea.allTimeHigh   => 'All-Time High',
        TargetArea.allTimeLow    => 'All-Time Low',
        TargetArea.weekHigh52    => '52W High',
        TargetArea.weekLow52     => '52W Low',
        TargetArea.priorHigh     => 'Prior High',
        TargetArea.priorLow      => 'Prior Low',
        TargetArea.gapFill       => 'Gap Fill',
        TargetArea.breakoutLevel => 'Breakout',
        TargetArea.srZone        => 'S/R Zone',
      };
}

TargetArea? targetAreaFromDb(String s) =>
    TargetArea.values.where((t) => t.dbValue == s).firstOrNull;

// Groups used in the add/edit sheet UI
const kTargetAreaGroups = <(String, List<TargetArea>)>[
  ('SMA Levels',      [TargetArea.sma20, TargetArea.sma50, TargetArea.sma100, TargetArea.sma200]),
  ('Market Extremes', [TargetArea.allTimeHigh, TargetArea.allTimeLow, TargetArea.weekHigh52, TargetArea.weekLow52]),
  ('Price Structure', [TargetArea.priorHigh, TargetArea.priorLow, TargetArea.gapFill, TargetArea.breakoutLevel, TargetArea.srZone]),
];

// ── VolumeCondition ────────────────────────────────────────────────────────────

enum VolumeCondition { aboveAvg, belowAvg, any }

extension VolumeConditionExt on VolumeCondition {
  String get dbValue => switch (this) {
        VolumeCondition.aboveAvg => 'above_avg',
        VolumeCondition.belowAvg => 'below_avg',
        VolumeCondition.any      => 'any',
      };
  String get label => switch (this) {
        VolumeCondition.aboveAvg => 'Above Average',
        VolumeCondition.belowAvg => 'Below Average',
        VolumeCondition.any      => 'Any',
      };
}

VolumeCondition volumeConditionFromDb(String? s) => switch (s) {
      'above_avg' => VolumeCondition.aboveAvg,
      'below_avg' => VolumeCondition.belowAvg,
      _           => VolumeCondition.any,
    };

// ── SetupStatus ────────────────────────────────────────────────────────────────
// Rules (evaluated on most-recent-first closed trades):
//   insufficient — fewer than 3 closed trades
//   dead         — 5+ consecutive losses from most recent
//   recovering   — was losing (4+ losses in trades 3–7) but last 2 are wins
//   hot          — 4 or 5 wins in last 5
//   warm         — 3 wins in last 5
//   cold         — 1 or 0 wins in last 5
//   neutral      — 2 wins in last 5

enum SetupStatus { hot, warm, neutral, cold, dead, recovering, insufficient }

extension SetupStatusExt on SetupStatus {
  String get label => switch (this) {
        SetupStatus.hot          => 'HOT',
        SetupStatus.warm         => 'WARM',
        SetupStatus.neutral      => 'NEUTRAL',
        SetupStatus.cold         => 'COLD',
        SetupStatus.dead         => 'DEAD',
        SetupStatus.recovering   => 'RECOVERING',
        SetupStatus.insufficient => 'NEW',
      };
  Color get color => switch (this) {
        SetupStatus.hot          => const Color(0xFF4ADE80),
        SetupStatus.warm         => const Color(0xFF86EFAC),
        SetupStatus.neutral      => const Color(0xFFA09FC8),
        SetupStatus.cold         => const Color(0xFFFBBF24),
        SetupStatus.dead         => const Color(0xFFFF6B8A),
        SetupStatus.recovering   => const Color(0xFF60A5FA),
        SetupStatus.insufficient => const Color(0xFFA09FC8),
      };
}

// ── SmaCondition ──────────────────────────────────────────────────────────────

class SmaCondition {
  final int    sma;       // 20, 50, 100, 200
  final String position;  // 'above' | 'below'

  const SmaCondition({required this.sma, required this.position});

  factory SmaCondition.fromJson(Map<String, dynamic> j) => SmaCondition(
        sma:      j['sma'] as int,
        position: j['position'] as String,
      );

  Map<String, dynamic> toJson() => {'sma': sma, 'position': position};

  String get label {
    final pos = position == 'above' ? 'Above' : 'Below';
    return 'Price $pos $sma SMA';
  }
}

// ── VixCondition ──────────────────────────────────────────────────────────────

class VixCondition {
  final String  operator;  // 'lt' | 'gt' | 'between'
  final double? value;     // used for 'lt' and 'gt'
  final double? low;       // used for 'between'
  final double? high;      // used for 'between'

  const VixCondition({
    required this.operator,
    this.value,
    this.low,
    this.high,
  });

  factory VixCondition.fromJson(Map<String, dynamic> j) => VixCondition(
        operator: j['operator'] as String,
        value:    j['value'] != null ? (j['value'] as num).toDouble() : null,
        low:      j['low']   != null ? (j['low']   as num).toDouble() : null,
        high:     j['high']  != null ? (j['high']  as num).toDouble() : null,
      );

  Map<String, dynamic> toJson() => {
        'operator': operator,
        if (value != null) 'value': value,
        if (low   != null) 'low':   low,
        if (high  != null) 'high':  high,
      };

  String get label => switch (operator) {
        'lt'      => 'VIX < ${value?.toStringAsFixed(0)}',
        'gt'      => 'VIX > ${value?.toStringAsFixed(0)}',
        'between' => 'VIX ${low?.toStringAsFixed(0)}–${high?.toStringAsFixed(0)}',
        _         => 'VIX condition',
      };
}

// ── SpyCondition ──────────────────────────────────────────────────────────────

class SpyCondition {
  final String  type;      // 'sma' | 'area'
  final int?    sma;       // 20, 50, 100, 200
  final String? position;  // 'above' | 'below'
  final String? area;      // 'at_highs' | 'pulling_back' | 'downtrend' | 'range'

  const SpyCondition({
    required this.type,
    this.sma,
    this.position,
    this.area,
  });

  factory SpyCondition.fromJson(Map<String, dynamic> j) => SpyCondition(
        type:     j['type']     as String,
        sma:      j['sma']      as int?,
        position: j['position'] as String?,
        area:     j['area']     as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        if (sma      != null) 'sma':      sma,
        if (position != null) 'position': position,
        if (area     != null) 'area':     area,
      };

  String get label {
    if (type == 'sma') {
      final pos = position == 'above' ? 'Above' : 'Below';
      return 'SPY $pos $sma SMA';
    }
    return 'SPY: ${_areaLabel(area ?? '')}';
  }

  static String areaLabel(String a) => _areaLabel(a);

  static String _areaLabel(String a) => switch (a) {
        'at_highs'     => 'At Highs',
        'pulling_back' => 'Pulling Back',
        'downtrend'    => 'Downtrend',
        'range'        => 'Range-Bound',
        _              => a,
      };
}

// ── StrategySetup ─────────────────────────────────────────────────────────────

class StrategySetup {
  final String             id;
  final String             name;
  final String?            description;
  final List<String>       tags;

  // Preset structured criteria
  final List<SmaCondition> smaConditions;
  final bool               srLevelRequired;
  final double?            srProximityPct;
  final VolumeCondition    volumeCondition;
  final bool               volumeCrossNeeded;
  final bool               lowerVolumeNeeded;
  final VixCondition?      vixCondition;
  final SpyCondition?      spyCondition;

  // User-defined free-form criteria (each is just a label string)
  final List<String>       customCriteria;

  // Where the trade is targeting (separate from entry criteria)
  final List<TargetArea>   targetAreas;

  final DateTime           createdAt;

  // All trades tagged to this strategy (open + closed), oldest-first
  final List<Trade>        linkedTrades;

  const StrategySetup({
    required this.id,
    required this.name,
    this.description,
    required this.tags,
    required this.smaConditions,
    required this.srLevelRequired,
    this.srProximityPct,
    required this.volumeCondition,
    required this.volumeCrossNeeded,
    required this.lowerVolumeNeeded,
    this.vixCondition,
    this.spyCondition,
    required this.customCriteria,
    required this.targetAreas,
    required this.createdAt,
    this.linkedTrades = const [],
  });

  // ── Derived trade lists ───────────────────────────────────────────────────────

  List<Trade> get openTrades   =>
      linkedTrades.where((t) => t.status == TradeStatus.open).toList();
  List<Trade> get closedTrades =>
      linkedTrades.where((t) => t.status != TradeStatus.open).toList();
  // Only closed trades with a definite P&L (exit price was entered)
  List<Trade> get scoredTrades =>
      closedTrades.where((t) => t.realizedPnl != null).toList();

  // ── Win / loss stats (scored closed trades only) ──────────────────────────────

  int get totalScored => scoredTrades.length;
  int get wins        => scoredTrades.where((t) => t.realizedPnl! > 0).length;
  int get losses      => scoredTrades.where((t) => t.realizedPnl! < 0).length;
  int get breakevens  => scoredTrades.where((t) => t.realizedPnl! == 0).length;

  double get winRate  => totalScored == 0 ? 0.0 : wins / totalScored;

  double get totalPnl => scoredTrades
      .map((t) => t.realizedPnl!)
      .fold(0.0, (a, b) => a + b);

  double get avgWin {
    final ws = scoredTrades.where((t) => t.realizedPnl! > 0);
    if (ws.isEmpty) return 0.0;
    return ws.map((t) => t.realizedPnl!).fold(0.0, (a, b) => a + b) / ws.length;
  }

  double get avgLoss {
    final ls = scoredTrades.where((t) => t.realizedPnl! < 0);
    if (ls.isEmpty) return 0.0;
    return ls.map((t) => t.realizedPnl!).fold(0.0, (a, b) => a + b) / ls.length;
  }

  double get profitFactor {
    final tw = scoredTrades.where((t) => t.realizedPnl! > 0)
        .map((t) => t.realizedPnl!).fold(0.0, (a, b) => a + b);
    final tl = scoredTrades.where((t) => t.realizedPnl! < 0)
        .map((t) => t.realizedPnl!.abs()).fold(0.0, (a, b) => a + b);
    if (tl == 0) return tw > 0 ? 999.0 : 0.0;
    return tw / tl;
  }

  double get expectancy {
    if (scoredTrades.isEmpty) return 0.0;
    return scoredTrades.map((t) => t.realizedPnl!).fold(0.0, (a, b) => a + b) /
        scoredTrades.length;
  }

  int get maxConsecutiveLosses {
    int max = 0, current = 0;
    for (final t in scoredTrades) {
      if (t.realizedPnl! < 0) {
        current++;
        if (current > max) max = current;
      } else {
        current = 0;
      }
    }
    return max;
  }

  // ── Setup status (newest-first evaluation) ────────────────────────────────────

  SetupStatus get status {
    if (totalScored < 3) return SetupStatus.insufficient;

    final newestFirst = scoredTrades.reversed.toList();
    final recent5 = newestFirst.take(5).toList();
    final recentWins = recent5.where((t) => t.realizedPnl! > 0).length;

    // Count consecutive losses from the most recent trade
    int consecutive = 0;
    for (final t in newestFirst) {
      if (t.realizedPnl! < 0) {
        consecutive++;
      } else {
        break;
      }
    }
    if (consecutive >= 5) return SetupStatus.dead;

    // Recovering: 4+ losses in trades 3–7 but last 2 are wins
    if (consecutive == 0 && totalScored >= 7) {
      final older    = newestFirst.skip(2).take(5).toList();
      final oldLoss  = older.where((t) => t.realizedPnl! < 0).length;
      final last2Win = newestFirst.take(2).every((t) => t.realizedPnl! > 0);
      if (oldLoss >= 4 && last2Win) return SetupStatus.recovering;
    }

    if (recentWins >= 4) return SetupStatus.hot;
    if (recentWins == 3) return SetupStatus.warm;
    if (recentWins <= 1) return SetupStatus.cold;
    return SetupStatus.neutral;
  }

  // ── All criteria as flat human-readable labels ────────────────────────────────

  List<String> get allCriteriaLabels => [
        for (final c in smaConditions) c.label,
        if (srLevelRequired)
          'Daily S/R Required'
              '${srProximityPct != null ? ' (within ${srProximityPct!.toStringAsFixed(1)}%)' : ''}',
        if (volumeCondition != VolumeCondition.any)
          'Volume: ${volumeCondition.label}',
        if (volumeCrossNeeded) 'Volume Cross Trigger',
        if (lowerVolumeNeeded) 'Lower/Declining Volume',
        if (vixCondition != null) vixCondition!.label,
        if (spyCondition != null) spyCondition!.label,
        ...customCriteria,
      ];

  bool get hasCriteria => allCriteriaLabels.isNotEmpty;
  bool get hasTargets  => targetAreas.isNotEmpty;

  // ── Serialization ─────────────────────────────────────────────────────────────

  factory StrategySetup.fromJson(
    Map<String, dynamic> j, {
    List<Trade> linkedTrades = const [],
  }) =>
      StrategySetup(
        id:          j['id']          as String,
        name:        j['name']        as String,
        description: j['description'] as String?,
        tags:        j['tags'] != null
            ? List<String>.from(j['tags'] as List)
            : [],
        smaConditions: j['sma_conditions'] != null
            ? (j['sma_conditions'] as List)
                .map((e) => SmaCondition.fromJson(e as Map<String, dynamic>))
                .toList()
            : [],
        srLevelRequired:   j['sr_level_required']  as bool? ?? false,
        srProximityPct:    j['sr_proximity_pct'] != null
            ? (j['sr_proximity_pct'] as num).toDouble()
            : null,
        volumeCondition:   volumeConditionFromDb(j['volume_condition'] as String?),
        volumeCrossNeeded: j['volume_cross_needed'] as bool? ?? false,
        lowerVolumeNeeded: j['lower_volume_needed'] as bool? ?? false,
        vixCondition: j['vix_condition'] != null
            ? VixCondition.fromJson(j['vix_condition'] as Map<String, dynamic>)
            : null,
        spyCondition: j['spy_condition'] != null
            ? SpyCondition.fromJson(j['spy_condition'] as Map<String, dynamic>)
            : null,
        customCriteria: j['custom_criteria'] != null
            ? (j['custom_criteria'] as List)
                .map((e) {
                  if (e is Map) {
                    return (e as Map<String, dynamic>)['label'] as String;
                  }
                  return e as String;
                })
                .toList()
            : [],
        targetAreas: j['target_areas'] != null
            ? (j['target_areas'] as List)
                .map((e) => targetAreaFromDb(e as String))
                .whereType<TargetArea>()
                .toList()
            : [],
        createdAt:    DateTime.parse(j['created_at'] as String).toLocal(),
        linkedTrades: linkedTrades,
      );

  Map<String, dynamic> toInsertJson() => {
        'name':               name,
        if (description != null) 'description': description,
        'tags':               tags,
        'sma_conditions':     smaConditions.map((s) => s.toJson()).toList(),
        'sr_level_required':  srLevelRequired,
        if (srProximityPct != null) 'sr_proximity_pct': srProximityPct,
        'volume_condition':    volumeCondition.dbValue,
        'volume_cross_needed': volumeCrossNeeded,
        'lower_volume_needed': lowerVolumeNeeded,
        if (vixCondition != null) 'vix_condition': vixCondition!.toJson(),
        if (spyCondition != null) 'spy_condition': spyCondition!.toJson(),
        'custom_criteria': customCriteria.map((c) => {'label': c}).toList(),
        'target_areas':    targetAreas.map((t) => t.dbValue).toList(),
      };
}
