// =============================================================================
// features/blotter/providers/fair_value_provider.dart
// =============================================================================
// Riverpod FutureProvider.family that calls the Python fair-value API.
// Keyed by all pricing inputs so the result auto-invalidates when spot,
// IV, DTE, or broker mid change. autoDispose so stale results are dropped
// when the screen is no longer mounted.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/python_api/python_api_client.dart';
import '../models/blotter_models.dart';

// ── Key ───────────────────────────────────────────────────────────────────────

@immutable
class FairValueKey {
  final double  spot;
  final double  strike;
  final double  iv;          // decimal (0.25 = 25%)
  final int     dte;
  final bool    isCall;
  final double  brokerMid;
  final double? rho;
  final double? nu;

  const FairValueKey({
    required this.spot,
    required this.strike,
    required this.iv,
    required this.dte,
    required this.isCall,
    required this.brokerMid,
    this.rho,
    this.nu,
  });

  @override
  bool operator ==(Object other) =>
      other is FairValueKey &&
      spot      == other.spot      &&
      strike    == other.strike    &&
      iv        == other.iv        &&
      dte       == other.dte       &&
      isCall    == other.isCall    &&
      brokerMid == other.brokerMid &&
      rho       == other.rho       &&
      nu        == other.nu;

  @override
  int get hashCode =>
      Object.hash(spot, strike, iv, dte, isCall, brokerMid, rho, nu);
}

// ── Provider ──────────────────────────────────────────────────────────────────

final fairValueProvider = FutureProvider.autoDispose
    .family<FairValueResult?, FairValueKey>((ref, key) async {
  if (key.spot <= 0 || key.brokerMid <= 0 || key.dte <= 0 || key.iv <= 0) {
    return null;
  }
  final raw = await PythonApiClient.fairValueCompute(
    spot:          key.spot,
    strike:        key.strike,
    impliedVol:    key.iv,
    daysToExpiry:  key.dte,
    isCall:        key.isCall,
    brokerMid:     key.brokerMid,
    calibratedRho: key.rho,
    calibratedNu:  key.nu,
  );
  return FairValueResult.fromJson(raw) ??
      FairValueResult(
        bsFairValue:    key.brokerMid,
        sabrFairValue:  key.brokerMid,
        modelFairValue: key.brokerMid,
        brokerMid:      key.brokerMid,
        edgeBps:        0,
        sabrVol:        key.iv,
        impliedVol:     key.iv,
      );
});
