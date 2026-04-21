// =============================================================================
// services/regime/regime_models.dart
// =============================================================================
// Data models for the current market regime snapshot.
// Populated by the Python pipeline (schwab_pull.py every 8 hours) and stored
// in the Supabase regime_snapshots table. Dart is read-only here — all math
// lives in api/services/regime_service.py + api/services/hmm_regime.py.
// =============================================================================

enum StrategyBias {
  directionalBullish,
  directionalBearish,
  straddleOnly,
  premiumSell,
  unclear,
}

extension StrategyBiasX on StrategyBias {
  String get label => switch (this) {
    StrategyBias.directionalBullish => 'Directional Bullish',
    StrategyBias.directionalBearish => 'Directional Bearish',
    StrategyBias.straddleOnly       => 'Straddle Only',
    StrategyBias.premiumSell        => 'Premium Sell',
    StrategyBias.unclear            => 'Unclear',
  };

  String get description => switch (this) {
    StrategyBias.directionalBullish =>
        'Low-vol + Long Gamma + SMA bullish cross — buy calls, bull spreads, '
        'or sell puts (credit). Losses curtailed by dealer support.',
    StrategyBias.directionalBearish =>
        'Short Gamma + SMA bearish — buy puts or bear spreads. '
        'Dealer flow amplifies downside moves.',
    StrategyBias.straddleOnly =>
        'High-vol / classicShortGamma regime — straddles are the only '
        'profitable structure here. Both sides benefit from vol expansion.',
    StrategyBias.premiumSell =>
        'Post-event with positive gamma cushion — IV mean-reversion expected. '
        'Sell premium via iron condors, credit spreads, or covered calls.',
    StrategyBias.unclear =>
        'Conflicting signals — near gamma flip zone or regime mismatch. '
        'Wait for stabilization before committing directionally.',
  };
}

enum HmmVolState { lowVol, highVol }

extension HmmVolStateX on HmmVolState {
  String get label => switch (this) {
    HmmVolState.lowVol  => 'Low-Vol',
    HmmVolState.highVol => 'High-Vol',
  };
}

class CurrentRegime {
  final String        ticker;
  final String        gammaRegime;       // "positive" | "negative" | "unknown"
  final String        ivGexSignal;       // classicShortGamma | stableGamma | …
  final double?       sma10;
  final double?       sma50;
  final bool?         smaCrossed;        // SMA10 > SMA50
  final double?       vixCurrent;
  final double?       vix10ma;
  final double?       vixDevPct;         // (VIX − VIX10MA) / VIX10MA × 100
  final double?       vixRsi;            // Wilder RSI(14)
  final double?       spotToZglPct;      // (spot − ZGL) / spot × 100
  final double?       ivPercentile;      // IVP 0–100
  final HmmVolState?  hmmState;
  final double?       hmmProbability;
  final StrategyBias  strategyBias;
  final List<String>  signals;
  final DateTime?     obsDate;

  const CurrentRegime({
    required this.ticker,
    required this.gammaRegime,
    required this.ivGexSignal,
    required this.strategyBias,
    required this.signals,
    this.sma10,
    this.sma50,
    this.smaCrossed,
    this.vixCurrent,
    this.vix10ma,
    this.vixDevPct,
    this.vixRsi,
    this.spotToZglPct,
    this.ivPercentile,
    this.hmmState,
    this.hmmProbability,
    this.obsDate,
  });

  factory CurrentRegime.fromJson(Map<String, dynamic> j) {
    return CurrentRegime(
      ticker:        j['ticker'] as String,
      gammaRegime:   j['gamma_regime'] as String? ?? 'unknown',
      ivGexSignal:   j['iv_gex_signal'] as String? ?? 'unknown',
      sma10:         (j['sma10'] as num?)?.toDouble(),
      sma50:         (j['sma50'] as num?)?.toDouble(),
      smaCrossed:    j['sma_crossed'] as bool?,
      vixCurrent:    (j['vix_current'] as num?)?.toDouble(),
      vix10ma:       (j['vix_10ma'] as num?)?.toDouble(),
      vixDevPct:     (j['vix_dev_pct'] as num?)?.toDouble(),
      vixRsi:        (j['vix_rsi'] as num?)?.toDouble(),
      spotToZglPct:  (j['spot_to_zgl_pct'] as num?)?.toDouble(),
      ivPercentile:  (j['iv_percentile'] as num?)?.toDouble(),
      hmmState:      _parseHmmState(j['hmm_state'] as String?),
      hmmProbability:(j['hmm_probability'] as num?)?.toDouble(),
      strategyBias:  _parseBias(j['strategy_bias'] as String?),
      signals:       (j['signals'] as List?)?.cast<String>() ?? [],
      obsDate:       j['obs_date'] != null
          ? DateTime.tryParse(j['obs_date'] as String)
          : null,
    );
  }

  static StrategyBias _parseBias(String? s) => switch (s) {
    'directional_bullish' => StrategyBias.directionalBullish,
    'directional_bearish' => StrategyBias.directionalBearish,
    'straddle_only'       => StrategyBias.straddleOnly,
    'premium_sell'        => StrategyBias.premiumSell,
    _                     => StrategyBias.unclear,
  };

  static HmmVolState? _parseHmmState(String? s) => switch (s) {
    'low_vol'  => HmmVolState.lowVol,
    'high_vol' => HmmVolState.highVol,
    _          => null,
  };
}
