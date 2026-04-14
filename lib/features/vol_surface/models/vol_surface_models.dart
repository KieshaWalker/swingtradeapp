// =============================================================================
// vol_surface/models/vol_surface_models.dart
// =============================================================================
class VolPoint {
  final double strike;
  final int dte;
  final double? callIv;
  final double? putIv;
  final int? callVolume;
  final int? putVolume;
  final int? callOI;
  final int? putOI;

  const VolPoint({
    required this.strike,
    required this.dte,
    this.callIv,
    this.putIv,
    this.callVolume,
    this.putVolume,
    this.callOI,
    this.putOI,
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
        // ATM: prefer average, fall back to either side
        if (callIv != null && putIv != null) return (callIv! + putIv!) / 2;
        return callIv ?? putIv;
    }
  }

  Map<String, dynamic> toJson() => {
        'strike': strike,
        'dte': dte,
        if (callIv != null) 'call_iv': callIv,
        if (putIv != null) 'put_iv': putIv,
        if (callVolume != null) 'call_vol': callVolume,
        if (putVolume != null) 'put_vol': putVolume,
        if (callOI != null) 'call_oi': callOI,
        if (putOI != null) 'put_oi': putOI,
      };

  factory VolPoint.fromJson(Map<String, dynamic> j) => VolPoint(
        strike: (j['strike'] as num).toDouble(),
        dte: (j['dte'] as num).toInt(),
        callIv: j['call_iv'] != null ? (j['call_iv'] as num).toDouble() : null,
        putIv: j['put_iv'] != null ? (j['put_iv'] as num).toDouble() : null,
        callVolume: j['call_vol'] != null ? (j['call_vol'] as num).toInt() : null,
        putVolume: j['put_vol'] != null ? (j['put_vol'] as num).toInt() : null,
        callOI: j['call_oi'] != null ? (j['call_oi'] as num).toInt() : null,
        putOI: j['put_oi'] != null ? (j['put_oi'] as num).toInt() : null,
      );
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
        'ticker': ticker,
        'obs_date': obsDateStr,
        if (spotPrice != null) 'spot_price': spotPrice,
        'points': points.map((p) => p.toJson()).toList(),
        'parsed_at': parsedAt.toIso8601String(),
      };

  factory VolSnapshot.fromRow(Map<String, dynamic> r) => VolSnapshot(
        id: r['id'] as String?,
        ticker: r['ticker'] as String,
        obsDate: DateTime.parse(r['obs_date'] as String),
        spotPrice: r['spot_price'] != null
            ? (r['spot_price'] as num).toDouble()
            : null,
        points: (r['points'] as List)
            .map((p) => VolPoint.fromJson(p as Map<String, dynamic>))
            .toList(),
        parsedAt: DateTime.parse(r['parsed_at'] as String),
      );
}
