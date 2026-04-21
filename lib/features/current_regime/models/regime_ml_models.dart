// =============================================================================
// features/current_regime/models/regime_ml_models.dart
// =============================================================================
// Response models for POST /regime/ml-analyze.
// =============================================================================

enum RegimeBucket {
  stablePositive,
  trendingPositive,
  trendingNegative,
  stableNegative,
  unknown,
}

extension RegimeBucketX on RegimeBucket {
  String get label => switch (this) {
    RegimeBucket.stablePositive   => 'Positive Gamma',
    RegimeBucket.trendingPositive => 'Trending → Positive',
    RegimeBucket.trendingNegative => 'Trending → Negative',
    RegimeBucket.stableNegative   => 'Negative Gamma',
    RegimeBucket.unknown          => 'Unknown',
  };

  String get shortLabel => switch (this) {
    RegimeBucket.stablePositive   => '+GEX',
    RegimeBucket.trendingPositive => '↑+GEX',
    RegimeBucket.trendingNegative => '↓−GEX',
    RegimeBucket.stableNegative   => '−GEX',
    RegimeBucket.unknown          => '?',
  };

  static RegimeBucket parse(String s) => switch (s) {
    'stable_positive'   => RegimeBucket.stablePositive,
    'trending_positive' => RegimeBucket.trendingPositive,
    'trending_negative' => RegimeBucket.trendingNegative,
    'stable_negative'   => RegimeBucket.stableNegative,
    _                   => RegimeBucket.unknown,
  };
}

class RegimeMlFeatures {
  final double? spotToZglPct;
  final double? spotToZglTrend;
  final double? ivp;
  final double? ivpTrend;
  final String? hmmState;
  final double? hmmProbability;
  final bool?   smaAligned;
  final double? vixDevPct;
  final int     regimeDurationDays;

  const RegimeMlFeatures({
    this.spotToZglPct,
    this.spotToZglTrend,
    this.ivp,
    this.ivpTrend,
    this.hmmState,
    this.hmmProbability,
    this.smaAligned,
    this.vixDevPct,
    required this.regimeDurationDays,
  });

  factory RegimeMlFeatures.fromJson(Map<String, dynamic> j) => RegimeMlFeatures(
    spotToZglPct:       (j['spot_to_zgl_pct']  as num?)?.toDouble(),
    spotToZglTrend:     (j['spot_to_zgl_trend'] as num?)?.toDouble(),
    ivp:                (j['ivp']               as num?)?.toDouble(),
    ivpTrend:           (j['ivp_trend']         as num?)?.toDouble(),
    hmmState:           j['hmm_state']          as String?,
    hmmProbability:     (j['hmm_probability']   as num?)?.toDouble(),
    smaAligned:         j['sma_aligned']        as bool?,
    vixDevPct:          (j['vix_dev_pct']       as num?)?.toDouble(),
    regimeDurationDays: (j['regime_duration_days'] as num?)?.toInt() ?? 0,
  );
}

class TickerRegimeResult {
  final String          ticker;
  final String          currentRegime;   // "positive" | "negative" | "unknown"
  final RegimeBucket    bucket;
  final double          mlScore;         // -1 to +1
  final double          transitionProb;  // 0-1 probability of flipping
  final double          confidence;      // 0-1
  final RegimeMlFeatures features;
  final String          strategyBias;
  final List<String>    signals;
  final DateTime?       lastUpdated;

  const TickerRegimeResult({
    required this.ticker,
    required this.currentRegime,
    required this.bucket,
    required this.mlScore,
    required this.transitionProb,
    required this.confidence,
    required this.features,
    required this.strategyBias,
    required this.signals,
    this.lastUpdated,
  });

  factory TickerRegimeResult.fromJson(Map<String, dynamic> j) =>
      TickerRegimeResult(
        ticker:         j['ticker']          as String,
        currentRegime:  j['current_regime']  as String? ?? 'unknown',
        bucket:         RegimeBucketX.parse(j['bucket'] as String? ?? ''),
        mlScore:        (j['ml_score']       as num?)?.toDouble() ?? 0,
        transitionProb: (j['transition_prob'] as num?)?.toDouble() ?? 0.5,
        confidence:     (j['confidence']     as num?)?.toDouble() ?? 0,
        features:       RegimeMlFeatures.fromJson(
                            j['features'] as Map<String, dynamic>? ?? {}),
        strategyBias:   j['strategy_bias']   as String? ?? 'unclear',
        signals:        (j['signals']        as List?)?.cast<String>() ?? [],
        lastUpdated:    j['last_updated'] != null
                            ? DateTime.tryParse(j['last_updated'] as String)
                            : null,
      );
}

class MlMarketContext {
  final Map<String, dynamic>? spyRegime;
  final String?  vixState;
  final double?  vixCurrent;
  final double?  vixDevPct;

  const MlMarketContext({
    this.spyRegime,
    this.vixState,
    this.vixCurrent,
    this.vixDevPct,
  });

  factory MlMarketContext.fromJson(Map<String, dynamic> j) => MlMarketContext(
    spyRegime:  j['spy_regime']  as Map<String, dynamic>?,
    vixState:   j['vix_state']   as String?,
    vixCurrent: (j['vix_current'] as num?)?.toDouble(),
    vixDevPct:  (j['vix_dev_pct'] as num?)?.toDouble(),
  );
}

class RegimeMlAnalysis {
  final DateTime                asOf;
  final MlMarketContext         marketContext;
  final List<TickerRegimeResult> tickers;

  const RegimeMlAnalysis({
    required this.asOf,
    required this.marketContext,
    required this.tickers,
  });

  factory RegimeMlAnalysis.fromJson(Map<String, dynamic> j) => RegimeMlAnalysis(
    asOf:          DateTime.parse(j['as_of'] as String),
    marketContext: MlMarketContext.fromJson(
                       j['market_context'] as Map<String, dynamic>? ?? {}),
    tickers:       (j['tickers'] as List?)
                       ?.map((e) => TickerRegimeResult.fromJson(
                           e as Map<String, dynamic>))
                       .toList() ?? [],
  );

  List<TickerRegimeResult> get stablePositive =>
      tickers.where((t) => t.bucket == RegimeBucket.stablePositive).toList()
        ..sort((a, b) => b.mlScore.compareTo(a.mlScore));

  List<TickerRegimeResult> get trendingPositive =>
      tickers.where((t) => t.bucket == RegimeBucket.trendingPositive).toList()
        ..sort((a, b) => b.mlScore.compareTo(a.mlScore));

  List<TickerRegimeResult> get trendingNegative =>
      tickers.where((t) => t.bucket == RegimeBucket.trendingNegative).toList()
        ..sort((a, b) => a.mlScore.compareTo(b.mlScore));

  List<TickerRegimeResult> get stableNegative =>
      tickers.where((t) => t.bucket == RegimeBucket.stableNegative).toList()
        ..sort((a, b) => a.mlScore.compareTo(b.mlScore));
}
