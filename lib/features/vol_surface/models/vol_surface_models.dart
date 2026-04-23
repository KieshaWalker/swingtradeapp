// =============================================================================
// vol_surface/models/vol_surface_models.dart
// =============================================================================
class VolPoint {
  final double strike;
  final int    dte;

  // ── Implied volatility ───────────────────────────────────────────────────
  final double? callIv;
  final double? putIv;

  // ── Volume & open interest ───────────────────────────────────────────────
  final int? callVolume;
  final int? putVolume;
  final int? callOI;
  final int? putOI;

  // ── Greeks ───────────────────────────────────────────────────────────────
  final double? callDelta;
  final double? putDelta;
  final double? callGamma;
  final double? putGamma;
  final double? callTheta;
  final double? putTheta;
  final double? callVega;
  final double? putVega;
  final double? callRho;
  final double? putRho;

  // ── Pricing ──────────────────────────────────────────────────────────────
  final double? callBid;
  final double? callAsk;
  final double? callMark;
  final double? callLast;
  final double? callTheo;
  final double? callIntrinsic;
  final double? callExtrinsic;
  final double? callHigh;
  final double? callLow;

  final double? putBid;
  final double? putAsk;
  final double? putMark;
  final double? putLast;
  final double? putTheo;
  final double? putIntrinsic;
  final double? putExtrinsic;
  final double? putHigh;
  final double? putLow;

  // ── Size (bid/ask depth) ─────────────────────────────────────────────────
  final int? callBidSize;
  final int? callAskSize;
  final int? putBidSize;
  final int? putAskSize;

  // ── Probabilities (N(d2) approximated via delta) ─────────────────────────
  // Prob ITM ≈ |delta|,  Prob OTM ≈ 1 − |delta|
  final double? callProbItm;
  final double? callProbOtm;
  final double? putProbItm;
  final double? putProbOtm;

  const VolPoint({
    required this.strike,
    required this.dte,
    // IV
    this.callIv,
    this.putIv,
    // Volume / OI
    this.callVolume,
    this.putVolume,
    this.callOI,
    this.putOI,
    // Greeks
    this.callDelta,
    this.putDelta,
    this.callGamma,
    this.putGamma,
    this.callTheta,
    this.putTheta,
    this.callVega,
    this.putVega,
    this.callRho,
    this.putRho,
    // Pricing
    this.callBid,
    this.callAsk,
    this.callMark,
    this.callLast,
    this.callTheo,
    this.callIntrinsic,
    this.callExtrinsic,
    this.callHigh,
    this.callLow,
    this.putBid,
    this.putAsk,
    this.putMark,
    this.putLast,
    this.putTheo,
    this.putIntrinsic,
    this.putExtrinsic,
    this.putHigh,
    this.putLow,
    // Size
    this.callBidSize,
    this.callAskSize,
    this.putBidSize,
    this.putAskSize,
    // Probabilities
    this.callProbItm,
    this.callProbOtm,
    this.putProbItm,
    this.putProbOtm,
  });

  /// Returns the IV value for the given display mode and spot price.
  double? iv(String mode, double? spot) {
    switch (mode) {
      case 'call':
        return callIv;
      case 'put':
        return putIv;
      case 'avg':
        if (callIv != null && putIv != null) return (callIv! + putIv!) / 2;
        return callIv ?? putIv;
      default: // otm — use call for strike > spot, put for strike < spot, avg at ATM
        if (spot == null || strike > spot) return callIv;
        if (strike < spot) return putIv;
        if (callIv != null && putIv != null) return (callIv! + putIv!) / 2;
        return callIv ?? putIv;
    }
  }

  Map<String, dynamic> toJson() => {
        'strike': strike,
        'dte':    dte,
        // IV
        if (callIv != null)      'call_iv':       callIv,
        if (putIv  != null)      'put_iv':        putIv,
        // Volume / OI
        if (callVolume != null)  'call_vol':      callVolume,
        if (putVolume  != null)  'put_vol':       putVolume,
        if (callOI     != null)  'call_oi':       callOI,
        if (putOI      != null)  'put_oi':        putOI,
        // Greeks
        if (callDelta  != null)  'call_delta':    callDelta,
        if (putDelta   != null)  'put_delta':     putDelta,
        if (callGamma  != null)  'call_gamma':    callGamma,
        if (putGamma   != null)  'put_gamma':     putGamma,
        if (callTheta  != null)  'call_theta':    callTheta,
        if (putTheta   != null)  'put_theta':     putTheta,
        if (callVega   != null)  'call_vega':     callVega,
        if (putVega    != null)  'put_vega':      putVega,
        if (callRho    != null)  'call_rho':      callRho,
        if (putRho     != null)  'put_rho':       putRho,
        // Pricing
        if (callBid       != null) 'call_bid':       callBid,
        if (callAsk       != null) 'call_ask':       callAsk,
        if (callMark      != null) 'call_mark':      callMark,
        if (callLast      != null) 'call_last':      callLast,
        if (callTheo      != null) 'call_theo':      callTheo,
        if (callIntrinsic != null) 'call_intrinsic': callIntrinsic,
        if (callExtrinsic != null) 'call_extrinsic': callExtrinsic,
        if (callHigh      != null) 'call_high':      callHigh,
        if (callLow       != null) 'call_low':       callLow,
        if (putBid        != null) 'put_bid':        putBid,
        if (putAsk        != null) 'put_ask':        putAsk,
        if (putMark       != null) 'put_mark':       putMark,
        if (putLast       != null) 'put_last':       putLast,
        if (putTheo       != null) 'put_theo':       putTheo,
        if (putIntrinsic  != null) 'put_intrinsic':  putIntrinsic,
        if (putExtrinsic  != null) 'put_extrinsic':  putExtrinsic,
        if (putHigh       != null) 'put_high':       putHigh,
        if (putLow        != null) 'put_low':        putLow,
        // Size
        if (callBidSize != null) 'call_bid_size': callBidSize,
        if (callAskSize != null) 'call_ask_size': callAskSize,
        if (putBidSize  != null) 'put_bid_size':  putBidSize,
        if (putAskSize  != null) 'put_ask_size':  putAskSize,
        // Probabilities
        if (callProbItm != null) 'call_prob_itm': callProbItm,
        if (callProbOtm != null) 'call_prob_otm': callProbOtm,
        if (putProbItm  != null) 'put_prob_itm':  putProbItm,
        if (putProbOtm  != null) 'put_prob_otm':  putProbOtm,
      };

  factory VolPoint.fromJson(Map<String, dynamic> j) => VolPoint(
        strike: (j['strike'] as num).toDouble(),
        dte:    (j['dte']    as num).toInt(),
        // IV
        callIv: (j['call_iv'] as num?)?.toDouble(),
        putIv:  (j['put_iv']  as num?)?.toDouble(),
        // Volume / OI
        callVolume: (j['call_vol'] as num?)?.toInt(),
        putVolume:  (j['put_vol']  as num?)?.toInt(),
        callOI:     (j['call_oi']  as num?)?.toInt(),
        putOI:      (j['put_oi']   as num?)?.toInt(),
        // Greeks
        callDelta: (j['call_delta'] as num?)?.toDouble(),
        putDelta:  (j['put_delta']  as num?)?.toDouble(),
        callGamma: (j['call_gamma'] as num?)?.toDouble(),
        putGamma:  (j['put_gamma']  as num?)?.toDouble(),
        callTheta: (j['call_theta'] as num?)?.toDouble(),
        putTheta:  (j['put_theta']  as num?)?.toDouble(),
        callVega:  (j['call_vega']  as num?)?.toDouble(),
        putVega:   (j['put_vega']   as num?)?.toDouble(),
        callRho:   (j['call_rho']   as num?)?.toDouble(),
        putRho:    (j['put_rho']    as num?)?.toDouble(),
        // Pricing
        callBid:       (j['call_bid']       as num?)?.toDouble(),
        callAsk:       (j['call_ask']       as num?)?.toDouble(),
        callMark:      (j['call_mark']      as num?)?.toDouble(),
        callLast:      (j['call_last']      as num?)?.toDouble(),
        callTheo:      (j['call_theo']      as num?)?.toDouble(),
        callIntrinsic: (j['call_intrinsic'] as num?)?.toDouble(),
        callExtrinsic: (j['call_extrinsic'] as num?)?.toDouble(),
        callHigh:      (j['call_high']      as num?)?.toDouble(),
        callLow:       (j['call_low']       as num?)?.toDouble(),
        putBid:        (j['put_bid']        as num?)?.toDouble(),
        putAsk:        (j['put_ask']        as num?)?.toDouble(),
        putMark:       (j['put_mark']       as num?)?.toDouble(),
        putLast:       (j['put_last']       as num?)?.toDouble(),
        putTheo:       (j['put_theo']       as num?)?.toDouble(),
        putIntrinsic:  (j['put_intrinsic']  as num?)?.toDouble(),
        putExtrinsic:  (j['put_extrinsic']  as num?)?.toDouble(),
        putHigh:       (j['put_high']       as num?)?.toDouble(),
        putLow:        (j['put_low']        as num?)?.toDouble(),
        // Size
        callBidSize: (j['call_bid_size'] as num?)?.toInt(),
        callAskSize: (j['call_ask_size'] as num?)?.toInt(),
        putBidSize:  (j['put_bid_size']  as num?)?.toInt(),
        putAskSize:  (j['put_ask_size']  as num?)?.toInt(),
        // Probabilities
        callProbItm: (j['call_prob_itm'] as num?)?.toDouble(),
        callProbOtm: (j['call_prob_otm'] as num?)?.toDouble(),
        putProbItm:  (j['put_prob_itm']  as num?)?.toDouble(),
        putProbOtm:  (j['put_prob_otm']  as num?)?.toDouble(),
      );
}

// ── SABR calibrated slice (one per DTE) ──────────────────────────────────────

class SabrSlice {
  final int    dte;
  final double alpha;
  final double beta;
  final double rho;
  final double nu;
  final double rmse;
  final int    nPoints;

  const SabrSlice({
    required this.dte,
    required this.alpha,
    required this.beta,
    required this.rho,
    required this.nu,
    required this.rmse,
    required this.nPoints,
  });

  bool get isReliable => nPoints >= 5 && rmse < 0.015;

  Map<String, dynamic> toJson() => {
    'dte': dte, 'alpha': alpha, 'beta': beta,
    'rho': rho, 'nu': nu, 'rmse': rmse, 'n_points': nPoints,
  };

  factory SabrSlice.fromJson(Map<String, dynamic> j) => SabrSlice(
    dte:     (j['dte']      as num).toInt(),
    alpha:   (j['alpha']    as num).toDouble(),
    beta:    (j['beta']     as num).toDouble(),
    rho:     (j['rho']      as num).toDouble(),
    nu:      (j['nu']       as num).toDouble(),
    rmse:    (j['rmse']     as num).toDouble(),
    nPoints: (j['n_points'] as num).toInt(),
  );

  @override
  String toString() =>
      'SABR ${dte}d: α=${alpha.toStringAsFixed(4)} '
      'ρ=${rho.toStringAsFixed(3)} ν=${nu.toStringAsFixed(3)} '
      'rmse=${(rmse * 100).toStringAsFixed(2)}% (n=$nPoints)';
}

class VolSnapshot {
  final String? id;
  final String ticker;
  final DateTime obsDate;
  final double? spotPrice;
  final List<VolPoint> points;
  final DateTime parsedAt;

  const VolSnapshot({
    this.id,
    required this.ticker,
    required this.obsDate,
    this.spotPrice,
    required this.points,
    required this.parsedAt,
  });

  String get obsDateStr {
    final y = obsDate.year.toString().padLeft(4, '0');
    final m = obsDate.month.toString().padLeft(2, '0');
    final d = obsDate.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  List<int> get dtes =>
      points.map((p) => p.dte).toSet().toList()..sort();

  List<double> get strikes =>
      points.map((p) => p.strike).toSet().toList()..sort();

  Map<String, dynamic> toUpsertRow() => {
        'ticker':     ticker,
        'obs_date':   obsDateStr,
        if (spotPrice != null) 'spot_price': spotPrice,
        'points':     points.map((p) => p.toJson()).toList(),
        'parsed_at':  parsedAt.toIso8601String(),
      };

  factory VolSnapshot.fromRow(Map<String, dynamic> r) => VolSnapshot(
        id:         r['id'] as String?,
        ticker:     r['ticker'] as String,
        obsDate:    DateTime.parse(r['obs_date'] as String),
        spotPrice:  (r['spot_price'] as num?)?.toDouble(),
        points:     (r['points'] as List)
            .map((p) => VolPoint.fromJson(p as Map<String, dynamic>))
            .toList(),
        parsedAt:   DateTime.parse(r['parsed_at'] as String),
      );
}
