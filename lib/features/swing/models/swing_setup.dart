// =============================================================================
// features/swing/models/swing_setup.dart
// =============================================================================
// One row of swing_setups — the screen's output for a ticker on a session.
//
// EVERY ANALYTIC FIELD IS NULLABLE, AND THAT IS THE POINT. The backend
// distinguishes three states the UI must not collapse together:
//
//   a value      the leg was computed
//   null         the leg could not be computed (not enough history, no chain)
//   false        the leg was computed and the answer is no
//
// sma50Above200 is the sharp case: null means "cannot tell" for a ticker with
// under 200 bars, and rendering that as a bearish cross would quietly mislabel
// every young listing. Show a dash for null, never a default.
//
// NOTHING IS COMPUTED HERE. Channel fits, moving averages, volume ratios and
// the options confirmation are all produced in the Python backend and read from
// the DB, so there is exactly one implementation of each. Adding arithmetic to
// this file would create a second one that silently disagrees.
// =============================================================================

class TrendLine {
  final double slope;      // price per bar
  final double intercept;
  final int touches;
  final int startIdx;      // line is only valid from this bar forward
  final List<int> pivotIdx;

  const TrendLine({
    required this.slope,
    required this.intercept,
    required this.touches,
    required this.startIdx,
    required this.pivotIdx,
  });

  double valueAt(num x) => slope * x + intercept;

  static TrendLine? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return TrendLine(
      slope:     (j['slope'] as num?)?.toDouble() ?? 0,
      intercept: (j['intercept'] as num?)?.toDouble() ?? 0,
      touches:   (j['touches'] as num?)?.toInt() ?? 0,
      startIdx:  (j['start_idx'] as num?)?.toInt() ?? 0,
      pivotIdx:  ((j['pivot_idx'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }
}

class SwingSetup {
  final String ticker;
  final DateTime obsDate;
  final double? spot;

  // Channel
  final bool channelFound;
  final String? channelReason;
  final String? channelKind;       // channel | wedge | broadening
  final String? channelDirection;  // ascending | descending | horizontal
  final double? channelUpper;
  final double? channelLower;
  final double? channelWidthPct;
  final double? channelPosition;   // 0 at lower line, 1 at upper
  final double? channelConfidence;
  final int? channelStartIdx;
  final double? targetUp;
  final double? targetDown;
  final TrendLine? upperLine;
  final TrendLine? lowerLine;

  // Trend
  final double? sma50;
  final double? sma200;
  final double? pctToSma50;
  final double? pctToSma200;
  final bool? sma50Above200;

  // Volume
  final double? volRatio;
  final double? volZ;
  final bool? volSurge;
  final String? participation;     // elevated | normal | light

  // Options confirmation
  final double? emPct;
  final int? emDte;
  final double? emRatioUp;
  final double? impliedDaysUp;
  final bool? reachableUp;
  final String? gammaRegime;
  final double? zeroGammaLevel;
  final String? dealerPosture;     // dampening | amplifying
  final bool? breakoutSupported;

  final double? structureQuality;

  const SwingSetup({
    required this.ticker,
    required this.obsDate,
    required this.channelFound,
    this.spot,
    this.channelReason,
    this.channelKind,
    this.channelDirection,
    this.channelUpper,
    this.channelLower,
    this.channelWidthPct,
    this.channelPosition,
    this.channelConfidence,
    this.channelStartIdx,
    this.targetUp,
    this.targetDown,
    this.upperLine,
    this.lowerLine,
    this.sma50,
    this.sma200,
    this.pctToSma50,
    this.pctToSma200,
    this.sma50Above200,
    this.volRatio,
    this.volZ,
    this.volSurge,
    this.participation,
    this.emPct,
    this.emDte,
    this.emRatioUp,
    this.impliedDaysUp,
    this.reachableUp,
    this.gammaRegime,
    this.zeroGammaLevel,
    this.dealerPosture,
    this.breakoutSupported,
    this.structureQuality,
  });

  static double? _d(dynamic v) => (v as num?)?.toDouble();
  static int? _i(dynamic v) => (v as num?)?.toInt();

  factory SwingSetup.fromJson(Map<String, dynamic> j) {
    final lines = j['channel_lines'] as Map<String, dynamic>?;
    return SwingSetup(
      ticker: j['ticker'] as String,
      // A plain date column — parsed as-is and never shifted between zones,
      // per this repo's timestamp convention. Only timestamptz gets .toLocal().
      obsDate: DateTime.parse(j['obs_date'] as String),
      spot: _d(j['spot']),
      channelFound: (j['channel_found'] as bool?) ?? false,
      channelReason: j['channel_reason'] as String?,
      channelKind: j['channel_kind'] as String?,
      channelDirection: j['channel_direction'] as String?,
      channelUpper: _d(j['channel_upper']),
      channelLower: _d(j['channel_lower']),
      channelWidthPct: _d(j['channel_width_pct']),
      channelPosition: _d(j['channel_position']),
      channelConfidence: _d(j['channel_confidence']),
      channelStartIdx: _i(j['channel_start_idx']),
      targetUp: _d(j['target_up']),
      targetDown: _d(j['target_down']),
      upperLine: TrendLine.fromJson(lines?['upper'] as Map<String, dynamic>?),
      lowerLine: TrendLine.fromJson(lines?['lower'] as Map<String, dynamic>?),
      sma50: _d(j['sma50']),
      sma200: _d(j['sma200']),
      pctToSma50: _d(j['pct_to_sma50']),
      pctToSma200: _d(j['pct_to_sma200']),
      sma50Above200: j['sma50_above_200'] as bool?,
      volRatio: _d(j['vol_ratio']),
      volZ: _d(j['vol_z']),
      volSurge: j['vol_surge'] as bool?,
      participation: j['participation'] as String?,
      emPct: _d(j['em_pct']),
      emDte: _i(j['em_dte']),
      emRatioUp: _d(j['em_ratio_up']),
      impliedDaysUp: _d(j['implied_days_up']),
      reachableUp: j['reachable_up'] as bool?,
      gammaRegime: j['gamma_regime'] as String?,
      zeroGammaLevel: _d(j['zero_gamma_level']),
      dealerPosture: j['dealer_posture'] as String?,
      breakoutSupported: j['breakout_supported'] as bool?,
      structureQuality: _d(j['structure_quality']),
    );
  }
}
