// =============================================================================
// features/positions/providers/positions_provider.dart
// =============================================================================
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/position_models.dart';

// ── Persisted positions ───────────────────────────────────────────────────────

class PositionsNotifier extends StateNotifier<List<Position>> {
  static const _prefsKey = 'positions_v1';

  PositionsNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((j) => Position.fromJson(j as Map<String, dynamic>))
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(state.map((p) => p.toJson()).toList()));
  }

  void add(Position p) {
    state = [...state, p];
    _save();
  }

  void update(Position p) {
    state = [for (final e in state) e.id == p.id ? p : e];
    _save();
  }

  void remove(String id) {
    state = state.where((p) => p.id != id).toList();
    _save();
  }
}

final positionsProvider =
    StateNotifierProvider<PositionsNotifier, List<Position>>(
        (_) => PositionsNotifier());

// ── Enriched positions (with live Schwab Greeks) ──────────────────────────────

final enrichedPositionsProvider =
    FutureProvider<List<EnrichedPosition>>((ref) async {
  final positions = ref.watch(positionsProvider);
  if (positions.isEmpty) return [];

  final optionTickers = positions
      .expand((p) => p.legs.where((l) => l.type != LegType.underlying))
      .map((l) => l.ticker)
      .toSet();

  final chainByTicker = <String, SchwabOptionsChain?>{};
  await Future.wait(optionTickers.map((ticker) async {
    try {
      chainByTicker[ticker] = await ref.read(
        schwabOptionsChainProvider(OptionsChainParams(
          symbol: ticker,
          contractType: 'ALL',
          strikeCount: 50,
        )).future,
      );
    } catch (_) {
      chainByTicker[ticker] = null;
    }
  }));

  return Future.wait(positions.map((pos) async {
    final enrichedLegs = await Future.wait(pos.legs.map((leg) async {
      if (leg.type == LegType.underlying) return EnrichedLeg(leg: leg);

      final chain = chainByTicker[leg.ticker];
      if (chain == null) return EnrichedLeg(leg: leg);

      final expiration = chain.expirations
          .where((e) => e.expirationDate == leg.expiry)
          .firstOrNull;
      if (expiration == null) return EnrichedLeg(leg: leg);

      final contracts =
          leg.type == LegType.call ? expiration.calls : expiration.puts;
      final contract = contracts
          .where((c) => (c.strikePrice - (leg.strike ?? 0)).abs() < 0.5)
          .firstOrNull;

      if (contract == null) return EnrichedLeg(leg: leg);

      Map<String, dynamic>? fv;
      try {
        fv = await PythonApiClient.fairValueCompute(
          spot: chain.underlyingPrice,
          strike: leg.strike!,
          impliedVol: contract.impliedVolatility / 100.0,
          daysToExpiry: contract.daysToExpiration,
          isCall: leg.type == LegType.call,
          brokerMid: contract.markPrice,
          ticker: leg.ticker,
        );
      } catch (_) {
        fv = null;
      }

      return EnrichedLeg(
        leg: leg,
        marketPrice: contract.markPrice,
        bsTheo:     (fv?['bs_fair_value']     as num?)?.toDouble(),
        sabrTheo:   (fv?['sabr_fair_value']   as num?)?.toDouble(),
        hestonTheo: (fv?['heston_fair_value'] as num?)?.toDouble(),
        modelTheo:  (fv?['model_fair_value']  as num?)?.toDouble(),
        contractDelta: contract.delta,
        contractGamma: contract.gamma,
        contractTheta: contract.theta,
        contractVega: contract.vega,
        contractRho: contract.rho,
      );
    }));

    return EnrichedPosition(position: pos, legs: enrichedLegs);
  }));
});
