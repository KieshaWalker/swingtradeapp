// =============================================================================
// services/iv/iv_models.dart
// =============================================================================
// Data models for the IV Analytics Engine:
//
//  IvSnapshot      — one row from iv_snapshots table (persisted daily record)
//  IvAnalysis      — computed live result from IvAnalyticsService
//  IvRating        — cheap / fair / expensive / extreme enum
//  SkewPoint       — (strike, putIv, callIv, skewDelta) for the skew curve
//  GexStrike       — per-strike gamma exposure entry
// =============================================================================

/// Cheapness/expensiveness rating derived from IVR + IVP
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
    IvRating.extreme   => 'IV is in the top 20% of its 52w range — premium selling favored',
    IvRating.expensive => 'IV elevated — consider spreads or credit strategies',
    IvRating.fair      => 'IV near historical average — neutral conditions',
    IvRating.cheap     => 'IV compressed — debit spreads and long options favored',
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

  /// Dealer GEX ($ millions):
  ///   dealers long call gamma → positive (stabilising)
  ///   dealers short put gamma → negative (destabilising / amplifies moves)
  /// GEX = (callOI × callGamma - putOI × putGamma) × 100 × underlyingPrice / 1e6
  double dealerGex(double underlyingPrice) {
    final callGex = callOi * callGamma * 100 * underlyingPrice;
    final putGex  = putOi  * putGamma  * 100 * underlyingPrice;
    return (callGex - putGex) / 1e6;
  }

  Map<String, dynamic> toJson(double underlyingPrice) => {
    'strike':    strike,
    'gex':       dealerGex(underlyingPrice),
    'calls_oi':  callOi,
    'puts_oi':   putOi,
  };

  factory GexStrike.fromJson(Map<String, dynamic> j) => GexStrike(
    strike:    (j['strike']   as num).toDouble(),
    callOi:    (j['calls_oi'] as num? ?? 0).toDouble(),
    putOi:     (j['puts_oi']  as num? ?? 0).toDouble(),
    callGamma: 0,   // not persisted — reconstructed from GEX + OI
    putGamma:  0,
  );

  // Convenience getter for reading persisted GEX value directly
  static double gexFromJson(Map<String, dynamic> j) =>
      (j['gex'] as num? ?? 0).toDouble();
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

/// Persisted snapshot stored in Supabase iv_snapshots
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
  });

  factory IvSnapshot.fromJson(Map<String, dynamic> j) => IvSnapshot(
    ticker:          j['ticker'] as String,
    date:            DateTime.parse(j['date'] as String),
    atmIv:           (j['atm_iv'] as num).toDouble(),
    skew:            (j['skew'] as num?)?.toDouble(),
    gexByStrike:     (j['gex_by_strike'] as List? ?? [])
                         .cast<Map<String, dynamic>>(),
    totalGex:        (j['total_gex'] as num?)?.toDouble(),
    maxGexStrike:    (j['max_gex_strike'] as num?)?.toDouble(),
    putCallRatio:    (j['put_call_ratio'] as num?)?.toDouble(),
    underlyingPrice: (j['underlying_price'] as num?)?.toDouble(),
  );

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
    GammaSlope.rising  => 'Dealer cushion strengthening — mean-reversion support is building.',
    GammaSlope.flat    => 'GEX profile stable near spot. No structural change imminent.',
    GammaSlope.falling => 'GEX declining as price moves up — glide path toward Short Gamma danger zone.',
  };
}

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
      'Spot is ABOVE the gamma flip point — dealers are net LONG gamma (often from calls). '
      'They buy dips and sell rips, stabilizing the market and lowering volatility. '
      'Creates support on the downside; allows gradual upward drift. '
      'Trading signal: LONG the market.',
    GammaRegime.negative =>
      'Spot is BELOW the gamma flip point — dealers are net SHORT gamma (often from puts). '
      'They sell as prices fall and buy as prices rise, amplifying moves and increasing volatility. '
      'Creates resistance on the upside; leads to accelerated downside moves. '
      'When net gamma turns negative, conditions are at least temporarily bearish '
      'until the trend stabilizes. Near zero = potential reversal watch. '
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
  });

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
