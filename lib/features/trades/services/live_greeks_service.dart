// =============================================================================
// features/trades/services/live_greeks_service.dart
// =============================================================================
// LiveGreeks model + helper that fetches Greeks from the Python API.
// =============================================================================

import '../../../services/python_api/python_api_client.dart';
import '../models/trade.dart';

class LiveGreeks {
  final double delta;
  final double gamma;
  final double theta;
  final double vega;
  final double vanna;
  final double charm;
  final double volga;
  final double impliedVol;
  final double dteRemaining;

  const LiveGreeks({
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.vanna,
    required this.charm,
    required this.volga,
    required this.impliedVol,
    required this.dteRemaining,
  });

  bool get isCall => delta > 0;

  factory LiveGreeks.fromJson(
    Map<String, dynamic> j, {
    required double impliedVol,
    required double dteRemaining,
  }) =>
      LiveGreeks(
        delta:        (j['delta']  as num).toDouble(),
        gamma:        (j['gamma']  as num).toDouble(),
        theta:        (j['theta']  as num).toDouble(),
        vega:         (j['vega']   as num).toDouble(),
        vanna:        (j['vanna']  as num? ?? 0).toDouble(),
        charm:        (j['charm']  as num? ?? 0).toDouble(),
        volga:        (j['vomma']  as num? ?? j['volga'] as num? ?? 0).toDouble(),
        impliedVol:   impliedVol,
        dteRemaining: dteRemaining,
      );
}

/// Fetch live Greeks for [trade] from the Python API.
Future<LiveGreeks?> fetchLiveGreeks({
  required Trade  trade,
  required double spot,
  required double currentIv,
  double          riskFreeRate  = 0.0433,
  double          dividendYield = 0.0,
}) async {
  try {
    final now         = DateTime.now();
    final minutesLeft = trade.expiration.difference(now).inMinutes.toDouble();
    const minT        = 1.0 / (365 * 24 * 60);
    final t           = (minutesLeft / (365 * 24 * 60)).clamp(minT, 10.0);

    final raw = await PythonApiClient.bsGreeks(
      s:          spot,
      k:          trade.strike,
      t:          t,
      sigma:      currentIv,
      r:          riskFreeRate,
      optionType: trade.optionType == OptionType.call ? 'call' : 'put',
    );
    return LiveGreeks.fromJson(raw, impliedVol: currentIv, dteRemaining: t * 365);
  } catch (_) {
    return null;
  }
}
