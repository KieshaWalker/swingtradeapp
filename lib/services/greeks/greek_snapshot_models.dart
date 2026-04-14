// =============================================================================
// services/greeks/greek_snapshot_models.dart
// =============================================================================
// One row per ticker per calendar day — ATM call + ATM put greeks.
//
// "ATM" selection strategy (in priority order):
//   1. Call with |delta| closest to 0.50
//   2. Put  with |delta| closest to 0.50
//   3. Fallback: strike closest to underlying price
//
// Expiration selected: nearest expiry with DTE in [7, 90]; falls back to
// nearest overall DTE if none qualify.
//
// Stored in Supabase table:  greek_snapshots
// Upsert key:                (user_id, ticker, obs_date)
// =============================================================================

class GreekSnapshot {
  final String    ticker;
  final DateTime  obsDate;          // date only (UTC midnight)
  final double    underlyingPrice;

  // ATM Call (null when chain has no calls)
  final double?   callStrike;
  final int?      callDte;
  final double?   callDelta;
  final double?   callGamma;
  final double?   callTheta;
  final double?   callVega;
  final double?   callRho;
  final double?   callIv;
  final int?      callOi;

  // ATM Put
  final double?   putStrike;
  final int?      putDte;
  final double?   putDelta;
  final double?   putGamma;
  final double?   putTheta;
  final double?   putVega;
  final double?   putRho;
  final double?   putIv;
  final int?      putOi;

  const GreekSnapshot({
    required this.ticker,
    required this.obsDate,
    required this.underlyingPrice,
    this.callStrike,
    this.callDte,
    this.callDelta,
    this.callGamma,
    this.callTheta,
    this.callVega,
    this.callRho,
    this.callIv,
    this.callOi,
    this.putStrike,
    this.putDte,
    this.putDelta,
    this.putGamma,
    this.putTheta,
    this.putVega,
    this.putRho,
    this.putIv,
    this.putOi,
  });

  Map<String, dynamic> toJson(String userId) => {
    'user_id':          userId,
    'ticker':           ticker.toUpperCase(),
    'obs_date':         obsDate.toIso8601String().substring(0, 10),
    'underlying_price': underlyingPrice,
    'call_strike':      callStrike,
    'call_dte':         callDte,
    'call_delta':       callDelta,
    'call_gamma':       callGamma,
    'call_theta':       callTheta,
    'call_vega':        callVega,
    'call_rho':         callRho,
    'call_iv':          callIv,
    'call_oi':          callOi,
    'put_strike':       putStrike,
    'put_dte':          putDte,
    'put_delta':        putDelta,
    'put_gamma':        putGamma,
    'put_theta':        putTheta,
    'put_vega':         putVega,
    'put_rho':          putRho,
    'put_iv':           putIv,
    'put_oi':           putOi,
  };

  factory GreekSnapshot.fromJson(Map<String, dynamic> j) => GreekSnapshot(
    ticker:          j['ticker'] as String,
    obsDate:         DateTime.parse(j['obs_date'] as String),
    underlyingPrice: (j['underlying_price'] as num).toDouble(),
    callStrike:      (j['call_strike'] as num?)?.toDouble(),
    callDte:         j['call_dte'] as int?,
    callDelta:       (j['call_delta'] as num?)?.toDouble(),
    callGamma:       (j['call_gamma'] as num?)?.toDouble(),
    callTheta:       (j['call_theta'] as num?)?.toDouble(),
    callVega:        (j['call_vega'] as num?)?.toDouble(),
    callRho:         (j['call_rho'] as num?)?.toDouble(),
    callIv:          (j['call_iv'] as num?)?.toDouble(),
    callOi:          j['call_oi'] as int?,
    putStrike:       (j['put_strike'] as num?)?.toDouble(),
    putDte:          j['put_dte'] as int?,
    putDelta:        (j['put_delta'] as num?)?.toDouble(),
    putGamma:        (j['put_gamma'] as num?)?.toDouble(),
    putTheta:        (j['put_theta'] as num?)?.toDouble(),
    putVega:         (j['put_vega'] as num?)?.toDouble(),
    putRho:          (j['put_rho'] as num?)?.toDouble(),
    putIv:           (j['put_iv'] as num?)?.toDouble(),
    putOi:           j['put_oi'] as int?,
  );
}
