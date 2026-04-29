// =============================================================================
// services/iv/iv_models.dart
// =============================================================================
// Data models for the IV Analytics Engine:
//
//  IvSnapshot      — one row from iv_snapshots table (persisted daily record)
//  IvAnalysis      — computed live result from Python /iv/analytics endpoint
//  IvRating        — cheap / fair / expensive / extreme enum
//  SkewPoint       — (strike, putIv, callIv, skewDelta) for the skew curve
//  GexStrike       — per-strike gamma exposure entry
// =============================================================================

/// Cheapness/expensiveness rating derived from IVR + IVP      
/// IVR means "IV Rank" — where current IV sits in the 52-week range (0–100%)
/// IVP means "IV Percentile" — percentage of past days with IV below current
enum IvRating {
  extreme,   // IVR > 80 — historically very expensive, premium selling zone
  expensive, // IVR 50–80
  fair,      // IVR 25–50
  cheap,     // IVR < 25 — historically cheap, debit buying zone
  noData,
}

extension IvRatingX on IvRating {
  String get label => switch (this) {
    IvRating.extreme   => 'Extreme',
    IvRating.expensive => 'Expensive',
    IvRating.fair      => 'Fair',
    IvRating.cheap     => 'Cheap',
    IvRating.noData    => 'No Data',
  };

  String get description => switch (this) {
    IvRating.extreme   => 'IV is in the top 20% of its 52w range — premium selling favored. additionally- high iv percentiles, can often predict a coming market reversal in price',
    IvRating.expensive => 'IV elevated above historical average — consider spreads or credit strategies over naked longs',
    IvRating.fair      => 'IV near historical average — neutral conditions',
    IvRating.cheap     => 'IV compressed relative to 52-week range — debit spreads and long options favored',
    IvRating.noData    => 'Insufficient history — check back after more chain loads',
  };
}

/// One strike's contribution to gamma exposure (dealer perspective)
class GexStrike {
  final double strike;
  final double callOi;
  final double putOi;
  final double callGamma;
  final double putGamma;

  const GexStrike({
    required this.strike,
    required this.callOi,
    required this.putOi,
    required this.callGamma,
    required this.putGamma,
  });

  double dealerGex(double underlyingPrice) {
    final callGex = callOi * callGamma * 100 * underlyingPrice;
    final putGex  = putOi  * putGamma  * 100 * underlyingPrice;
    return (callGex - putGex) / 1e6;
  }

  Map<String, dynamic> toJson(double underlyingPrice) => {
    'strike':     strike,
    'dealer_gex': dealerGex(underlyingPrice),
    'call_oi':    callOi,
    'put_oi':     putOi,
  };

  factory GexStrike.fromJson(Map<String, dynamic> j) => GexStrike(
    strike:    (j['strike']  as num).toDouble(),
    callOi:    (j['call_oi'] as num? ?? 0).toDouble(),
    putOi:     (j['put_oi']  as num? ?? 0).toDouble(),
    callGamma: 0,   // not persisted — reconstructed from GEX + OI
    putGamma:  0,
  );

  // Convenience getter for reading persisted GEX value directly
  static double gexFromJson(Map<String, dynamic> j) =>
      (j['dealer_gex'] as num? ?? 0).toDouble();
}

// =============================================================================
// Vanna / Charm / Volga per-strike models
// =============================================================================
// All three are "second-order Greeks" derived from available Schwab data.
// Formulas assume r≈0 and q≈0 (simplified Black-Scholes).
//
//  Vanna  = ∂²V/∂S∂σ  = change in delta for a 1% change in IV
//           Approximation: -gamma × spot × √T × d₂
//           Dealer VEX: (callOI × callVanna - putOI × putVanna) × 100 × spot
//           → When IV drops (vol crush), dealers BUY back delta → rally
//           → When IV rises, dealers SELL delta → pressure
//
//  Charm  = ∂Δ/∂t     = how dealer delta hedges decay each day (delta decay)
//           Approximation: gamma × spot × (IV/100) × d₂ / (2√T × 365)
//           Dealer CEX: (callOI × callCharm - putOI × putCharm) × 100 × spot
//           → Positive CEX → dealers buy delta as time passes (AM session effect)
//           → Negative CEX → dealers sell delta near close
//
//  Volga  = ∂²V/∂σ²   = change in vega for a 1% change in IV (vol convexity)
//  (Vomma)  Approximation: vega × d₁ × d₂ / (IV/100)
//           Dealer Volga Exposure (VolgaEX): (callOI - putOI) × volga × 100
//           → High Volga → options very sensitive to vol-of-vol
//           → Vanna-Volga surface steepness drives smile pricing
// =============================================================================

/// Per-strike Vanna, Charm, and Volga exposures
class SecondOrderStrike {
  final double strike;

  // Vanna (∂Δ/∂σ) — per contract
  final double callVanna;
  final double putVanna;
  final double callOi;
  final double putOi;

  // Charm (∂Δ/∂t per day) — per contract
  final double callCharm;
  final double putCharm;

  // Volga (∂Vega/∂σ) — per contract
  final double callVolga;
  final double putVolga;

  const SecondOrderStrike({
    required this.strike,
    required this.callVanna,
    required this.putVanna,
    required this.callOi,
    required this.putOi,
    required this.callCharm,
    required this.putCharm,
    required this.callVolga,
    required this.putVolga,
  });

  /// Net dealer Vanna Exposure in $ per 1-vol-point IV move
  /// Positive VEX → IV drop causes dealer BUYING (vol-crush rally)
  /// Negative VEX → IV drop causes dealer SELLING
  double get dealerVex {
    final callVex = callOi * callVanna * 100;
    final putVex  = putOi  * putVanna  * 100;
    return callVex - putVex;
  }

  /// Net dealer Charm Exposure in $ delta per day
  /// Positive CEX → time passing causes dealers to BUY delta
  /// Negative CEX → time passing causes dealers to SELL delta
  double get dealerCex {
    final callCex = callOi * callCharm * 100;
    final putCex  = putOi  * putCharm  * 100;
    return callCex - putCex;
  }

  /// Net dealer Volga Exposure (vol convexity)
  /// High positive → market makers short convexity; large IV moves hurt them
  double get dealerVolga {
    final callVolgaEx = callOi * callVolga * 100;
    final putVolgaEx  = putOi  * putVolga  * 100;
    return callVolgaEx - putVolgaEx;
  }
}

// =============================================================================
// Risk-Neutral Density models (Breeden-Litzenberger)
// =============================================================================

/// One strike on the RND density curve
class RndPoint {
  final double strike;
  final double density;    // q(K), normalised
  final double probAbove;  // P(S_T > K)
  final double probBelow;  // P(S_T ≤ K)

  const RndPoint({
    required this.strike,
    required this.density,
    required this.probAbove,
    required this.probBelow,
  });

  factory RndPoint.fromJson(Map<String, dynamic> j) => RndPoint(
    strike:    (j['strike']     as num).toDouble(),
    density:   (j['density']    as num).toDouble(),
    probAbove: (j['prob_above'] as num).toDouble(),
    probBelow: (j['prob_below'] as num).toDouble(),
  );
}

/// Implied moments extracted from the risk-neutral density
class RndMoments {
  final double mean;
  final double variance;
  final double impliedVol;   // lognormal cross-check
  final double skewness;     // negative = left-tail (crash); positive = right-tail (lottery)
  final double kurtosis;     // excess kurtosis; 0 = lognormal; >0 = fat tails

  const RndMoments({
    required this.mean,
    required this.variance,
    required this.impliedVol,
    required this.skewness,
    required this.kurtosis,
  });

  factory RndMoments.fromJson(Map<String, dynamic> j) => RndMoments(
    mean:       (j['mean']        as num).toDouble(),
    variance:   (j['variance']    as num).toDouble(),
    impliedVol: (j['implied_vol'] as num).toDouble(),
    skewness:   (j['skewness']    as num).toDouble(),
    kurtosis:   (j['kurtosis']    as num).toDouble(),
  );
}

/// One DTE slice of the risk-neutral density
class RndSlice {
  final int dte;
  final String expiry;
  final List<RndPoint> strikes;
  final RndMoments moments;
  final double sabrAlpha;
  final double sabrRho;
  final double sabrNu;
  final double sabrRmse;
  final bool reliable;

  const RndSlice({
    required this.dte,
    required this.expiry,
    required this.strikes,
    required this.moments,
    required this.sabrAlpha,
    required this.sabrRho,
    required this.sabrNu,
    required this.sabrRmse,
    required this.reliable,
  });

  factory RndSlice.fromJson(Map<String, dynamic> j) => RndSlice(
    dte:       (j['dte'] as num).toInt(),
    expiry:    j['expiry'] as String? ?? '',
    strikes:   (j['strikes'] as List? ?? [])
                   .map((e) => RndPoint.fromJson(e as Map<String, dynamic>))
                   .toList(),
    moments:   RndMoments.fromJson(j['moments'] as Map<String, dynamic>),
    sabrAlpha: (j['sabr_alpha'] as num).toDouble(),
    sabrRho:   (j['sabr_rho']   as num).toDouble(),
    sabrNu:    (j['sabr_nu']    as num).toDouble(),
    sabrRmse:  (j['sabr_rmse']  as num).toDouble(),
    reliable:  j['reliable'] as bool? ?? false,
  );

  /// Find the strike point closest to [targetProb] prob_above (e.g. 0.5 ≈ ATM).
  RndPoint? nearestByProbAbove(double targetProb) {
    if (strikes.isEmpty) return null;
    return strikes.reduce((a, b) =>
        (a.probAbove - targetProb).abs() < (b.probAbove - targetProb).abs() ? a : b);
  }
}

/// One point on the volatility skew curve (per strike)
class SkewPoint {
  final double strike;
  final double? putIv;
  final double? callIv;
  final double moneyness; // (strike - spot) / spot × 100

  const SkewPoint({
    required this.strike,
    required this.moneyness,
    this.putIv,
    this.callIv,
  });

  double? get skewDelta => (putIv != null && callIv != null)
      ? putIv! - callIv!
      : null;
}

/// Persisted snapshot stored in Supabase iv_snapshots.
/// Basic fields written since migration 011; extended fields added in 027.
class IvSnapshot {
  final String ticker;
  final DateTime date;
  final double atmIv;
  final double? skew;
  final List<Map<String, dynamic>> gexByStrike;
  final double? totalGex;
  final double? maxGexStrike;
  final double? putCallRatio;
  final double? underlyingPrice;

  // Extended fields (migration 027)
  final double? ivRank;
  final double? ivPercentile;
  final IvRating? ivRating;
  final GammaRegime? gammaRegime;
  final GammaSlope? gammaSlope;
  final IvGexSignal? ivGexSignal;
  final double? zeroGammaLevel;
  final double? spotToZeroGammaPct;
  final double? deltaGex;
  final double? putWallDensity;
  final VannaRegime? vannaRegime;
  final double? totalVex;
  final double? totalCex;
  final double? totalVolga;
  final double? maxVexStrike;
  final double? skewAvg52w;
  final double? skewZScore;

  const IvSnapshot({
    required this.ticker,
    required this.date,
    required this.atmIv,
    this.skew,
    this.gexByStrike = const [],
    this.totalGex,
    this.maxGexStrike,
    this.putCallRatio,
    this.underlyingPrice,
    this.ivRank,
    this.ivPercentile,
    this.ivRating,
    this.gammaRegime,
    this.gammaSlope,
    this.ivGexSignal,
    this.zeroGammaLevel,
    this.spotToZeroGammaPct,
    this.deltaGex,
    this.putWallDensity,
    this.vannaRegime,
    this.totalVex,
    this.totalCex,
    this.totalVolga,
    this.maxVexStrike,
    this.skewAvg52w,
    this.skewZScore,
  });

  factory IvSnapshot.fromJson(Map<String, dynamic> j) {
    IvRating? parseRating(String? s) => switch (s) {
      'extreme'   => IvRating.extreme,
      'expensive' => IvRating.expensive,
      'fair'      => IvRating.fair,
      'cheap'     => IvRating.cheap,
      _           => null,
    };
    GammaRegime? parseGammaRegime(String? s) => switch (s) {
      'positive' => GammaRegime.positive,
      'negative' => GammaRegime.negative,
      _          => null,
    };
    GammaSlope? parseGammaSlope(String? s) => switch (s) {
      'rising'  => GammaSlope.rising,
      'falling' => GammaSlope.falling,
      'flat'    => GammaSlope.flat,
      _         => null,
    };
    IvGexSignal? parseIvGexSignal(String? s) => switch (s) {
      'classicShortGamma'  => IvGexSignal.classicShortGamma,
      'regimeShift'        => IvGexSignal.regimeShift,
      'eventOverPosGamma'  => IvGexSignal.eventOverPosGamma,
      'stableGamma'        => IvGexSignal.stableGamma,
      _                    => null,
    };
    VannaRegime? parseVannaRegime(String? s) => switch (s) {
      'bullishOnVolCrush' => VannaRegime.bullishOnVolCrush,
      'bearishOnVolCrush' => VannaRegime.bearishOnVolCrush,
      'bullishOnVolSpike' => VannaRegime.bullishOnVolSpike,
      'bearishOnVolSpike' => VannaRegime.bearishOnVolSpike,
      _                   => null,
    };

    return IvSnapshot(
      ticker:             j['ticker'] as String,
      date:               DateTime.parse(j['date'] as String),
      atmIv:              (j['atm_iv'] as num).toDouble(),
      skew:               (j['skew'] as num?)?.toDouble(),
      gexByStrike:        (j['gex_by_strike'] as List? ?? [])
                              .cast<Map<String, dynamic>>(),
      totalGex:           (j['total_gex'] as num?)?.toDouble(),
      maxGexStrike:       (j['max_gex_strike'] as num?)?.toDouble(),
      putCallRatio:       (j['put_call_ratio'] as num?)?.toDouble(),
      underlyingPrice:    (j['underlying_price'] as num?)?.toDouble(),
      ivRank:             (j['iv_rank'] as num?)?.toDouble(),
      ivPercentile:       (j['iv_percentile'] as num?)?.toDouble(),
      ivRating:           parseRating(j['iv_rating'] as String?),
      gammaRegime:        parseGammaRegime(j['gamma_regime'] as String?),
      gammaSlope:         parseGammaSlope(j['gamma_slope'] as String?),
      ivGexSignal:        parseIvGexSignal(j['iv_gex_signal'] as String?),
      zeroGammaLevel:     (j['zero_gamma_level'] as num?)?.toDouble(),
      spotToZeroGammaPct: (j['spot_to_zero_gamma_pct'] as num?)?.toDouble(),
      deltaGex:           (j['delta_gex'] as num?)?.toDouble(),
      putWallDensity:     (j['put_wall_density'] as num?)?.toDouble(),
      vannaRegime:        parseVannaRegime(j['vanna_regime'] as String?),
      totalVex:           (j['total_vex'] as num?)?.toDouble(),
      totalCex:           (j['total_cex'] as num?)?.toDouble(),
      totalVolga:         (j['total_volga'] as num?)?.toDouble(),
      maxVexStrike:       (j['max_vex_strike'] as num?)?.toDouble(),
      skewAvg52w:         (j['skew_avg_52w'] as num?)?.toDouble(),
      skewZScore:         (j['skew_z_score'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'ticker':           ticker,
    'date':             date.toIso8601String().substring(0, 10),
    'atm_iv':           atmIv,
    'skew':             skew,
    'gex_by_strike':    gexByStrike,
    'total_gex':        totalGex,
    'max_gex_strike':   maxGexStrike,
    'put_call_ratio':   putCallRatio,
    'underlying_price': underlyingPrice,
  };
}

/// Whether dealers are net long or short gamma (GEX sign)
enum GammaRegime {
  positive, // dealers long gamma → price-stabilising (mean reversion)
  negative, // dealers short gamma → price-amplifying (trend/squeeze)
  unknown,
}

/// Direction of the GEX profile as price moves up the strike ladder
enum GammaSlope {
  rising,  // GEX increasing toward higher strikes → cushion strengthening
  flat,    // GEX roughly constant
  falling, // GEX declining toward higher strikes → approaching danger zone
}

extension GammaSlopeX on GammaSlope {
  String get label => switch (this) {
    GammaSlope.rising  => '↗ Rising',
    GammaSlope.flat    => '→ Flat',
    GammaSlope.falling => '↘ Falling',
  };
  String get description => switch (this) {
  GammaSlope.rising =>
    'GEX increases at strikes above spot — price moving up enters '
    'deeper positive-gamma territory. Dealer cushion strengthens '
    'with each tick higher; mean-reversion support is building.',
  GammaSlope.flat =>
    'GEX profile stable across strikes near spot. '
    'No structural regime change imminent.',
  GammaSlope.falling =>
    'GEX decreases at strikes above spot — price moving up erodes '
    'the positive-gamma cushion. Glide path toward the zero-gamma '
    'flip level; dealers provide progressively less stabilisation.',
};
}


//Scenario 1: Stability Around $590
//Heavy positive Gamma exposure suggests SPY may remain anchored near $590. Traders could take advantage of this stability by deploying low-volatility strategies, such as credit spreads or iron condors, to capture premium in a range-bound environment.
//Scenario 2: A Drop Below $589
//If SPY breaks below $589, the negative Gamma exposure signals heightened volatility risk. This could present an opportunity for bearish trades, such as buying puts or using debit spreads, to profit from an acceleration in the downward move. Watch for confirming signals, such as increasing volume or sustained price breaks below $589.
//Why Gamma Exposure Matters
//Gamma Exposure helps traders see beyond traditional technical analysis by revealing how hedging dynamics influence price behavior. Here are the key takeaways:

//Support and Resistance Levels: Strikes with high positive Gamma exposure often act as magnets, stabilizing price movements as expiration nears.
//Volatility Indicators: Strikes with heavy negative Gamma exposure point to areas where volatility may spike, especially during breakouts or trending markets.

/// Single-snapshot IV / GEX combined regime classification
enum IvGexSignal {
  classicShortGamma,   // negative GEX + elevated IV → inverse correlation active
  regimeShift,         // negative GEX + suppressed IV → correlation breaking; hidden risk
  eventOverPosGamma,   // positive GEX + IV elevated → post-event, dealers long gamma
  stableGamma,         // positive GEX + suppressed IV → ideal premium-selling environment
  unknown,
}

extension IvGexSignalX on IvGexSignal {
  String get label => switch (this) {
    IvGexSignal.classicShortGamma => 'Classic Short Gamma',
    IvGexSignal.regimeShift       => 'Regime Shift Signal',
    IvGexSignal.eventOverPosGamma => 'Event / Pos Gamma',
    IvGexSignal.stableGamma       => 'Stable Gamma',
    IvGexSignal.unknown           => 'Unknown',
  };
  String get description => switch (this) {
    IvGexSignal.classicShortGamma =>
      'Short Gamma regime + elevated IV — dealers selling into weakness; '
      'volatility expansion actively in progress. Standard 3σ models underestimate tail risk.',
    IvGexSignal.regimeShift =>
      'Short Gamma regime but IV is suppressed — correlation breaking. '
      'This is the stealth danger zone: the market looks calm but structural support is absent. '
      'Increase tail-risk probabilities in ES95 and Monte Carlo now.',
    IvGexSignal.eventOverPosGamma =>
      'Positive Gamma + elevated IV — dealers are long gamma, providing a cushion. '
      'IV should mean-revert as the event passes. Good environment for premium selling.',
    IvGexSignal.stableGamma =>
      'Positive Gamma + suppressed IV — optimal for net-short premium strategies. '
      'Dealers are stabilising. Iron condors and credit spreads thrive here.',
    IvGexSignal.unknown => 'Insufficient data to classify the IV/GEX signal.',
  };
  // Strategy guidance derived from regime research:
  // "losses curtailed in low-vol regime; straddles only profitable in high-vol"
  String get strategyHint => switch (this) {
    IvGexSignal.stableGamma =>
      'Low-vol stabilizing regime. Best for: directional (call buying, credit spreads). '
      'Losses curtailed in this environment. Avoid straddles — theta erodes premium.',
    IvGexSignal.classicShortGamma =>
      'High-vol amplifying regime. Best for: straddles or bearish directional (puts). '
      'Straddles are only profitable in this regime. Signal: SHORT the market.',
    IvGexSignal.regimeShift =>
      'Stealth danger zone: negative gamma + suppressed IV. '
      'Avoid undefined-risk trades. Use defined-risk structures only. '
      'Volatility expansion is likely underpriced by models.',
    IvGexSignal.eventOverPosGamma =>
      'Post-event with positive gamma cushion. IV mean-reversion likely. '
      'Best for: defined-risk bullish plays or premium selling. '
      'Avoid naked premium buying — IV crush risk elevated.',
    IvGexSignal.unknown =>
      'Insufficient history to classify regime. '
      'Load more chain data before sizing up.',
  };
  bool get isDangerous => this == IvGexSignal.classicShortGamma ||
      this == IvGexSignal.regimeShift;
}

extension GammaRegimeX on GammaRegime {
  String get label => switch (this) {
    GammaRegime.positive => 'Positive Gamma',
    GammaRegime.negative => 'Negative Gamma',
    GammaRegime.unknown  => 'Unknown',
  };
  String get description => switch (this) {
    GammaRegime.positive =>
      'Dealers are net LONG gamma (total GEX ≥ 0) — call gamma across the chain outweighs put gamma. '
    'They buy dips and sell rips, dampening volatility and stabilising price. '
    'Creates support on the downside; allows gradual upward drift. '
    'See Spot-to-Flip % for proximity to the gamma flip level. '
    'Trading signal: LONG the market.',
    GammaRegime.negative =>
      'Dealers are net SHORT gamma (total GEX < 0) — put gamma across the chain outweighs call gamma. '
    'They sell as prices fall and buy as prices rise, amplifying moves and increasing volatility. '
    'Creates resistance on the upside; leads to accelerated downside moves. '
    'When net gamma turns negative, conditions are at least temporarily bearish '
    'until the trend stabilises. Near zero = potential reversal watch. '
    'Trading signal: SHORT the market.',
    GammaRegime.unknown  => 'Insufficient data to determine regime.',
  };
  String get tradingSignal => switch (this) {
    GammaRegime.positive => 'LONG',
    GammaRegime.negative => 'SHORT',
    GammaRegime.unknown  => '—',
  };
}

/// Whether a vol-crush or vol-spike will cause dealer buying or selling
enum VannaRegime {
  bullishOnVolCrush,  // positive VEX → IV drop forces dealers to buy delta
  bearishOnVolCrush,  // negative VEX → IV drop forces dealers to sell delta
  bullishOnVolSpike,  // negative VEX → IV rise forces dealers to buy delta
  bearishOnVolSpike,  // positive VEX → IV rise forces dealers to sell delta
  unknown,
}

extension VannaRegimeX on VannaRegime {
  String get label => switch (this) {
    VannaRegime.bullishOnVolCrush => 'Bullish on Vol Crush',
    VannaRegime.bearishOnVolCrush => 'Bearish on Vol Crush',
    VannaRegime.bullishOnVolSpike => 'Bullish on Vol Spike',
    VannaRegime.bearishOnVolSpike => 'Bearish on Vol Spike',
    VannaRegime.unknown           => 'Unknown',
  };
  String get description => switch (this) {
    VannaRegime.bullishOnVolCrush =>
      'Positive VEX: when IV falls (e.g. post-earnings vol crush), dealers '
      'accumulate long delta → bullish tailwind.',
    VannaRegime.bearishOnVolCrush =>
      'Negative VEX: when IV falls, dealers shed delta → bearish pressure even '
      'as vol normalises.',
    VannaRegime.bullishOnVolSpike =>
      'Negative VEX: an IV spike forces dealers to buy delta → potential squeeze.',
    VannaRegime.bearishOnVolSpike =>
      'Positive VEX: an IV spike forces dealers to sell delta → amplifies downside.',
    VannaRegime.unknown => 'Insufficient data to determine Vanna regime.',
  };
}

/// Full live analysis result — computed from chain + history
class IvAnalysis {
  final String ticker;
  final double currentIv;       // ATM IV today (%)
  final double? iv52wHigh;
  final double? iv52wLow;
  final double? ivRank;         // 0–100 (IVR)
  final double? ivPercentile;   // 0–100 (IVP)
  final IvRating rating;
  final int historyDays;        // days of data available

  // Skew
  final double? skew;           // current OTM put IV - OTM call IV
  final double? skewAvg52w;     // rolling avg skew
  final double? skewZScore;     // how extreme vs history
  final List<SkewPoint> skewCurve;

  // GEX
  final List<GexStrike> gexStrikes;
  final double? totalGex;       // net GEX $ millions
  final double? maxGexStrike;   // biggest dealer gamma wall
  final double? putCallRatio;

  // Second-order Greeks: Vanna / Charm / Volga
  final List<SecondOrderStrike> secondOrder;
  final double? totalVex;       // net Vanna Exposure ($ per 1 vol pt)
  final double? totalCex;       // net Charm Exposure ($ delta per day)
  final double? totalVolga;     // net Volga Exposure (vol convexity)
  final double? maxVexStrike;   // strike with largest absolute VEX
  final GammaRegime gammaRegime;
  final VannaRegime  vannaRegime;

  // ── Advanced GEX metrics ─────────────────────────────────────────────────
  // Zero Gamma Level: the strike where per-strike GEX crosses zero
  // (the "flip point" — above = dealers long gamma, below = short gamma)
  final double? zeroGammaLevel;

  // Distance from spot to Zero Gamma Level as a percentage of spot.
  // Negative = spot is already below the flip point (Short Gamma regime).
  final double? spotToZeroGammaPct;

  // Day-over-day change in total GEX (GEX_t − GEX_{t−1}).
  // Deeply negative = glide path to Short Gamma washout.
  final double? deltaGex;

  // Directional slope of the GEX profile across strikes near spot.
  final GammaSlope gammaSlope;

  // Combined IV + GEX regime classification.
  final IvGexSignal ivGexSignal;

  // Wall density: put wall OI as a multiple of average OI within ±5% of spot.
  // < 0.5 = thin wall (washout risk). > 2.0 = strong structural support.
  final double? putWallDensity;

  // Underlying spot price at analysis time — required for dealerGex() scaling.
  final double? underlyingPrice;

  // ── Institutional-grade GEX fields ────────────────────────────────────────
  // GEX contributed solely by same-day (0DTE) expiries ($M).
  final double? gex0dte;
  // gex0dte / |total_gex| × 100 — what fraction of total gamma is 0DTE-driven.
  final double? gex0dtePct;
  // Lowest significant positive-GEX support level above the zero-gamma level.
  // The "volatility trigger": below it, dealers flip to short gamma behaviour.
  final double? volatilityTrigger;
  // (spot − volatilityTrigger) / spot × 100.
  // Negative = spot is already in the transition corridor below the VT.
  final double? spotToVtPct;

  // ── Risk-Neutral Density ─────────────────────────────────────────────────
  // One slice per DTE with a valid SABR calibration.
  // Empty if SABR calibration fails for all expirations.
  final List<RndSlice> rnd;

  const IvAnalysis({
    required this.ticker,
    required this.currentIv,
    required this.rating,
    this.iv52wHigh,
    this.iv52wLow,
    this.ivRank,
    this.ivPercentile,
    this.historyDays = 0,
    this.skew,
    this.skewAvg52w,
    this.skewZScore,
    this.skewCurve = const [],
    this.gexStrikes = const [],
    this.totalGex,
    this.maxGexStrike,
    this.putCallRatio,
    this.secondOrder = const [],
    this.totalVex,
    this.totalCex,
    this.totalVolga,
    this.maxVexStrike,
    this.gammaRegime  = GammaRegime.unknown,
    this.vannaRegime  = VannaRegime.unknown,
    this.zeroGammaLevel,
    this.spotToZeroGammaPct,
    this.deltaGex,
    this.gammaSlope   = GammaSlope.flat,
    this.ivGexSignal  = IvGexSignal.unknown,
    this.putWallDensity,
    this.underlyingPrice,
    this.gex0dte,
    this.gex0dtePct,
    this.volatilityTrigger,
    this.spotToVtPct,
    this.rnd = const [],
  });

  factory IvAnalysis.fromJson(Map<String, dynamic> j) {
    final ratingStr = j['rating'] as String? ?? 'no_data';
    final rating = switch (ratingStr) {
      'extreme'   => IvRating.extreme,
      'expensive' => IvRating.expensive,
      'fair'      => IvRating.fair,
      'cheap'     => IvRating.cheap,
      _           => IvRating.noData,
    };
    final grStr = j['gamma_regime'] as String? ?? 'unknown';
    final gammaRegime = switch (grStr) {
      'positive' => GammaRegime.positive,
      'negative' => GammaRegime.negative,
      _          => GammaRegime.unknown,
    };
    final vrStr = j['vanna_regime'] as String? ?? 'unknown';
    final vannaRegime = switch (vrStr) {
      'bullishOnVolCrush' => VannaRegime.bullishOnVolCrush,
      'bearishOnVolCrush' => VannaRegime.bearishOnVolCrush,
      'bullishOnVolSpike' => VannaRegime.bullishOnVolSpike,
      'bearishOnVolSpike' => VannaRegime.bearishOnVolSpike,
      _                     => VannaRegime.unknown,
    };
    final gsStr = j['gamma_slope'] as String? ?? 'flat';
    final gammaSlope = switch (gsStr) {
      'rising'  => GammaSlope.rising,
      'falling' => GammaSlope.falling,
      _         => GammaSlope.flat,
    };
    final sigStr = j['iv_gex_signal'] as String? ?? 'unknown';
    final ivGexSignal = switch (sigStr) {
      'classicShortGamma'   => IvGexSignal.classicShortGamma,
      'regimeShift'         => IvGexSignal.regimeShift,
      'eventOverPosGamma'   => IvGexSignal.eventOverPosGamma,
      'stableGamma'         => IvGexSignal.stableGamma,
      _                     => IvGexSignal.unknown,
    };
    final gexStrikes = (j['gex_strikes'] as List? ?? [])
        .map((e) => GexStrike.fromJson(e as Map<String, dynamic>))
        .toList();
    return IvAnalysis(
      ticker:             j['ticker']               as String? ?? '',
      currentIv:          (j['current_iv']          as num).toDouble(),
      iv52wHigh:          (j['iv52w_high']          as num?)?.toDouble(),
      iv52wLow:           (j['iv52w_low']           as num?)?.toDouble(),
      ivRank:             (j['iv_rank']             as num?)?.toDouble(),
      ivPercentile:       (j['iv_percentile']       as num?)?.toDouble(),
      rating:             rating,
      historyDays:        (j['history_days']        as num? ?? 0).toInt(),
      skew:               (j['skew']                as num?)?.toDouble(),
      skewAvg52w:         (j['skew_avg_52w']        as num?)?.toDouble(),
      skewZScore:         (j['skew_z_score']        as num?)?.toDouble(),
      gexStrikes:         gexStrikes,
      totalGex:           (j['total_gex']           as num?)?.toDouble(),
      maxGexStrike:       (j['max_gex_strike']      as num?)?.toDouble(),
      putCallRatio:       (j['put_call_ratio']      as num?)?.toDouble(),
      totalVex:           (j['total_vex']           as num?)?.toDouble(),
      totalCex:           (j['total_cex']           as num?)?.toDouble(),
      totalVolga:         (j['total_volga']         as num?)?.toDouble(),
      maxVexStrike:       (j['max_vex_strike']      as num?)?.toDouble(),
      gammaRegime:        gammaRegime,
      vannaRegime:        vannaRegime,
      zeroGammaLevel:     (j['zero_gamma_level']    as num?)?.toDouble(),
      spotToZeroGammaPct: (j['spot_to_zero_gamma_pct'] as num?)?.toDouble(),
      deltaGex:           (j['delta_gex']           as num?)?.toDouble(),
      gammaSlope:         gammaSlope,
      ivGexSignal:        ivGexSignal,
      putWallDensity:     (j['put_wall_density']    as num?)?.toDouble(),
      underlyingPrice:    (j['underlying_price']    as num?)?.toDouble(),
      gex0dte:            (j['gex_0dte']            as num?)?.toDouble(),
      gex0dtePct:         (j['gex_0dte_pct']        as num?)?.toDouble(),
      volatilityTrigger:  (j['volatility_trigger']  as num?)?.toDouble(),
      spotToVtPct:        (j['spot_to_vt_pct']      as num?)?.toDouble(),
      rnd:                (j['rnd'] as List? ?? [])
                              .map((e) => RndSlice.fromJson(e as Map<String, dynamic>))
                              .toList(),
    );
  }

  bool get hasHistory => historyDays >= 10;

  String get ivRankLabel => ivRank != null
      ? '${ivRank!.toStringAsFixed(0)}%'
      : '—';

  String get ivPercentileLabel => ivPercentile != null
      ? '${ivPercentile!.toStringAsFixed(0)}%'
      : '—';

  String get skewLabel {
    if (skew == null) return '—';
    final s = skew!;
    if (s > 10) return 'Steep (${s.toStringAsFixed(1)}pp)';
    if (s > 5)  return 'Elevated (${s.toStringAsFixed(1)}pp)';
    if (s > 1)  return 'Mild (${s.toStringAsFixed(1)}pp)';
    if (s > 0)  return 'Normal (${s.toStringAsFixed(1)}pp)';
    return 'Flat/Inverted (${s.toStringAsFixed(1)}pp)';
  }

  String get gexLabel {
    if (totalGex == null) return '—';
    final g = totalGex!;
    final abs = g.abs();
    final fmt = abs >= 1000
        ? '\$${(abs / 1000).toStringAsFixed(1)}B'
        : '\$${abs.toStringAsFixed(0)}M';
    return g >= 0 ? '+$fmt' : '-$fmt';
  }

  String get vexLabel {
    if (totalVex == null) return '—';
    final v = totalVex!;
    final abs = v.abs();
    final fmt = abs >= 1e6 ? '\$${(abs / 1e6).toStringAsFixed(1)}M'
        : abs >= 1e3 ? '\$${(abs / 1e3).toStringAsFixed(0)}K'
        : '\$${abs.toStringAsFixed(0)}';
    return v >= 0 ? '+$fmt' : '-$fmt';
  }

  String get deltaGexLabel {
    if (deltaGex == null) return '—';
    final d = deltaGex!;
    final abs = d.abs();
    final fmt = abs >= 1000
        ? '\$${(abs / 1000).toStringAsFixed(1)}B'
        : '\$${abs.toStringAsFixed(0)}M';
    return d >= 0 ? '+$fmt' : '-$fmt';
  }

  String get cexLabel {
    if (totalCex == null) return '—';
    final c = totalCex!;
    final abs = c.abs();
    final fmt = abs >= 1e6 ? '\$${(abs / 1e6).toStringAsFixed(1)}M'
        : abs >= 1e3 ? '\$${(abs / 1e3).toStringAsFixed(0)}K'
        : '\$${abs.toStringAsFixed(0)}';
    return c >= 0 ? '+$fmt/day' : '-$fmt/day';
  }
}
