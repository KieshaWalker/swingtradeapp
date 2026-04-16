// =============================================================================
// features/greek_grid/models/greek_grid_models.dart
// =============================================================================

// ── Enums ─────────────────────────────────────────────────────────────────────

enum StrikeBand {
  deepItm,  // moneyness < -15%
  itm,      // -15% to -5%
  atm,      // -5% to +5%
  otm,      // +5% to +15%
  deepOtm;  // > +15%

  static StrikeBand fromMoneynessPct(double pct) {
    if (pct < -15) return StrikeBand.deepItm;
    if (pct < -5)  return StrikeBand.itm;
    if (pct <= 5)  return StrikeBand.atm;
    if (pct <= 15) return StrikeBand.otm;
    return StrikeBand.deepOtm;
  }

  static StrikeBand fromJson(String s) =>
      values.firstWhere((e) => e.dbValue == s,
          orElse: () => StrikeBand.atm);

  String get dbValue => switch (this) {
    StrikeBand.deepItm => 'deep_itm',
    StrikeBand.itm     => 'itm',
    StrikeBand.atm     => 'atm',
    StrikeBand.otm     => 'otm',
    StrikeBand.deepOtm => 'deep_otm',
  };

  String get label => switch (this) {
    StrikeBand.deepItm => 'Deep ITM',
    StrikeBand.itm     => 'ITM',
    StrikeBand.atm     => 'ATM',
    StrikeBand.otm     => 'OTM',
    StrikeBand.deepOtm => 'Deep OTM',
  };

  String get rangeLabel => switch (this) {
    StrikeBand.deepItm => '< −15%',
    StrikeBand.itm     => '−15% to −5%',
    StrikeBand.atm     => '±5%',
    StrikeBand.otm     => '+5% to +15%',
    StrikeBand.deepOtm => '> +15%',
  };
}

enum ExpiryBucket {
  weekly,       // DTE ≤ 7
  nearMonthly,  // 8–30
  monthly,      // 31–60
  farMonthly,   // 61–90
  quarterly;    // > 90

  static ExpiryBucket fromDte(int dte) {
    if (dte <= 7)  return ExpiryBucket.weekly;
    if (dte <= 30) return ExpiryBucket.nearMonthly;
    if (dte <= 60) return ExpiryBucket.monthly;
    if (dte <= 90) return ExpiryBucket.farMonthly;
    return ExpiryBucket.quarterly;
  }

  static ExpiryBucket fromJson(String s) =>
      values.firstWhere((e) => e.dbValue == s,
          orElse: () => ExpiryBucket.monthly);

  String get dbValue => switch (this) {
    ExpiryBucket.weekly      => 'weekly',
    ExpiryBucket.nearMonthly => 'near_monthly',
    ExpiryBucket.monthly     => 'monthly',
    ExpiryBucket.farMonthly  => 'far_monthly',
    ExpiryBucket.quarterly   => 'quarterly',
  };

  String get label => switch (this) {
    ExpiryBucket.weekly      => '≤7d',
    ExpiryBucket.nearMonthly => '8–30d',
    ExpiryBucket.monthly     => '31–60d',
    ExpiryBucket.farMonthly  => '61–90d',
    ExpiryBucket.quarterly   => '>90d',
  };
}

enum GreekSelector {
  delta, gamma, vega, theta, iv, vanna, charm, volga;

  String get label => switch (this) {
    GreekSelector.delta => 'Δ Delta',
    GreekSelector.gamma => 'Γ Gamma',
    GreekSelector.vega  => 'V Vega',
    GreekSelector.theta => 'Θ Theta',
    GreekSelector.iv    => 'IV',
    GreekSelector.vanna => 'Vanna',
    GreekSelector.charm => 'Charm',
    GreekSelector.volga => 'Volga',
  };

  String get shortLabel => switch (this) {
    GreekSelector.delta => 'Δ',
    GreekSelector.gamma => 'Γ',
    GreekSelector.vega  => 'V',
    GreekSelector.theta => 'Θ',
    GreekSelector.iv    => 'IV',
    GreekSelector.vanna => 'Va',
    GreekSelector.charm => 'Ch',
    GreekSelector.volga => 'Vo',
  };
}

// ── GreekGridPoint — one cell in the 3D grid ──────────────────────────────────

class GreekGridPoint {
  final String?      id;
  final String       ticker;
  final DateTime     obsDate;
  final StrikeBand   strikeBand;
  final ExpiryBucket expiryBucket;
  final double       strike;
  final DateTime?    expiryDate;

  final double? delta;
  final double? gamma;
  final double? vega;
  final double? theta;
  final double? iv;
  final double? vanna;
  final double? charm;
  final double? volga;

  final int? openInterest;
  final int? volume;
  final double spotAtObs;
  final int contractCount;

  const GreekGridPoint({
    this.id,
    required this.ticker,
    required this.obsDate,
    required this.strikeBand,
    required this.expiryBucket,
    required this.strike,
    this.expiryDate,
    this.delta,
    this.gamma,
    this.vega,
    this.theta,
    this.iv,
    this.vanna,
    this.charm,
    this.volga,
    this.openInterest,
    this.volume,
    required this.spotAtObs,
    this.contractCount = 1,
  });

  bool get isExpired =>
      expiryDate != null && expiryDate!.isBefore(DateTime.now().toUtc());

  double get moneynessPct => spotAtObs > 0
      ? (strike - spotAtObs) / spotAtObs * 100
      : 0;

  double? greekValue(GreekSelector s) => switch (s) {
    GreekSelector.delta => delta,
    GreekSelector.gamma => gamma,
    GreekSelector.vega  => vega,
    GreekSelector.theta => theta,
    GreekSelector.iv    => iv,
    GreekSelector.vanna => vanna,
    GreekSelector.charm => charm,
    GreekSelector.volga => volga,
  };

  factory GreekGridPoint.fromJson(Map<String, dynamic> j) => GreekGridPoint(
    id:            j['id'] as String?,
    ticker:        j['ticker'] as String,
    obsDate:       DateTime.parse(j['obs_date'] as String),
    strikeBand:    StrikeBand.fromJson(j['strike_band'] as String),
    expiryBucket:  ExpiryBucket.fromJson(j['expiry_bucket'] as String),
    strike:        (j['strike'] as num).toDouble(),
    expiryDate:    j['expiry_date'] != null
                     ? DateTime.tryParse(j['expiry_date'] as String)
                     : null,
    delta:         (j['delta'] as num?)?.toDouble(),
    gamma:         (j['gamma'] as num?)?.toDouble(),
    vega:          (j['vega']  as num?)?.toDouble(),
    theta:         (j['theta'] as num?)?.toDouble(),
    iv:            (j['iv']    as num?)?.toDouble(),
    vanna:         (j['vanna'] as num?)?.toDouble(),
    charm:         (j['charm'] as num?)?.toDouble(),
    volga:         (j['volga'] as num?)?.toDouble(),
    openInterest:  (j['open_interest'] as num?)?.toInt(),
    volume:        (j['volume']        as num?)?.toInt(),
    spotAtObs:     (j['spot_at_obs']   as num).toDouble(),
    contractCount: (j['contract_count'] as num? ?? 1).toInt(),
  );

  Map<String, dynamic> toUpsertRow(String userId) => {
    'user_id':        userId,
    'ticker':         ticker,
    'obs_date':       obsDate.toIso8601String().substring(0, 10),
    'strike_band':    strikeBand.dbValue,
    'expiry_bucket':  expiryBucket.dbValue,
    'strike':         strike,
    if (expiryDate != null)
      'expiry_date':  expiryDate!.toIso8601String().substring(0, 10),
    if (delta != null)        'delta':         delta,
    if (gamma != null)        'gamma':         gamma,
    if (vega  != null)        'vega':          vega,
    if (theta != null)        'theta':         theta,
    if (iv    != null)        'iv':            iv,
    if (vanna != null)        'vanna':         vanna,
    if (charm != null)        'charm':         charm,
    if (volga != null)        'volga':         volga,
    if (openInterest != null) 'open_interest': openInterest,
    if (volume != null)       'volume':        volume,
    'spot_at_obs':    spotAtObs,
    'contract_count': contractCount,
  };
}

// ── GreekGridSnapshot — all cells for one ticker × one obs_date ───────────────

class GreekGridSnapshot {
  final String              ticker;
  final DateTime            obsDate;
  final List<GreekGridPoint> points;

  const GreekGridSnapshot({
    required this.ticker,
    required this.obsDate,
    required this.points,
  });

  GreekGridPoint? cell(StrikeBand band, ExpiryBucket bucket) =>
      points.where((p) => p.strikeBand == band && p.expiryBucket == bucket)
            .firstOrNull;
}
