// =============================================================================
// features/positions/providers/positions_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/position_models.dart';

SupabaseClient get _db => Supabase.instance.client;

// ── Persisted positions (Supabase) ────────────────────────────────────────────

class PositionsNotifier extends StateNotifier<List<Position>> {
  final Ref _ref;

  PositionsNotifier(this._ref) : super([]) {
    _load();
  }

  static const _legCols =
      'id, type, ticker, strike, expiry, quantity, entry_price, exit_price, status, closed_at';

  Future<void> _load() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final rows = await _db
          .from('positions')
          .select('id, name, position_legs($_legCols)')
          .eq('user_id', userId)
          .order('created_at');
      state = (rows as List)
          .map((r) => Position.fromSupabase(r as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  Future<void> add(Position p) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    await _db.from('positions').insert({
      'id': p.id,
      'name': p.name,
      'user_id': userId,
    });
    if (p.legs.isNotEmpty) {
      await _db.from('position_legs').insert(
            p.legs.map((l) => l.toSupabaseInsert(p.id)).toList(),
          );
      // Capture entry snapshots for each leg
      await _captureSnapshots(p.legs, SnapshotType.entry);
    }
    state = [...state, p];
  }

  Future<void> update(Position p) async {
    await _db
        .from('positions')
        .update({'name': p.name, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', p.id);

    // Only delete legs that were removed — preserves snapshot history for retained legs.
    final existing = state.firstWhere((s) => s.id == p.id,
        orElse: () => Position(id: p.id, name: p.name, legs: const []));
    final newIds = p.legs.map((l) => l.id).toSet();
    final removedIds =
        existing.legs.map((l) => l.id).where((id) => !newIds.contains(id)).toList();
    if (removedIds.isNotEmpty) {
      await _db
          .from('position_legs')
          .delete()
          .inFilter('id', removedIds);
    }

    // Upsert keeps existing rows (and their snapshot history) intact for legs
    // with unchanged IDs; inserts genuinely new legs.
    if (p.legs.isNotEmpty) {
      await _db.from('position_legs').upsert(
            p.legs.map((l) => l.toSupabaseInsert(p.id)).toList(),
          );
    }
    state = [for (final e in state) e.id == p.id ? p : e];
  }

  Future<void> remove(String id) async {
    await _db.from('positions').delete().eq('id', id);
    state = state.where((p) => p.id != id).toList();
  }

  Future<void> closeLeg(String legId, double exitPrice) async {
    final now = DateTime.now();
    await _db.from('position_legs').update({
      'status': 'closed',
      'exit_price': exitPrice,
      'closed_at': now.toIso8601String(),
    }).eq('id', legId);

    // Find the leg in state and capture exit snapshot
    PositionLeg? leg;
    for (final pos in state) {
      leg = pos.legs.where((l) => l.id == legId).firstOrNull;
      if (leg != null) break;
    }

    if (leg != null) {
      final closed = PositionLeg(
        id: leg.id,
        type: leg.type,
        ticker: leg.ticker,
        strike: leg.strike,
        expiry: leg.expiry,
        quantity: leg.quantity,
        entryPrice: leg.entryPrice,
        exitPrice: exitPrice,
        status: LegStatus.closed,
        closedAt: now,
      );
      await _captureSnapshots([closed], SnapshotType.exit);
      _ref.invalidate(legSnapshotsProvider(legId));
    }

    // Refresh state from DB
    await _load();
  }

  // Fetches live data and inserts snapshots for the given legs (options only).
  Future<void> _captureSnapshots(List<PositionLeg> legs, SnapshotType type) async {
    final optionLegs = legs.where((l) => l.type != LegType.underlying).toList();
    if (optionLegs.isEmpty) return;

    final today = DateTime.now();
    final snapshots = await Future.wait(optionLegs.map((leg) async {
      SchwabOptionsChain? chain;
      try {
        chain = await _ref.read(
          schwabOptionsChainProvider(OptionsChainParams(
            symbol: leg.ticker,
            contractType: 'ALL',
            strikeCount: 50,
          )).future,
        );
      } catch (_) {
        chain = null;
      }

      final expiration = chain?.expirations
          .where((e) => e.expirationDate == leg.expiry)
          .firstOrNull;
      final contracts = expiration == null
          ? null
          : (leg.type == LegType.call ? expiration.calls : expiration.puts);
      final contract = contracts
          ?.where((c) => (c.strikePrice - (leg.strike ?? 0)).abs() < 0.5)
          .firstOrNull;

      Map<String, dynamic>? fv;
      if (contract != null && chain != null) {
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
      }

      return LegSnapshot(
        id: const Uuid().v4(),
        legId: leg.id,
        snapshotDate: today,
        snapshotType: type,
        underlyingPrice: chain?.underlyingPrice,
        marketPrice: contract?.markPrice,
        bsTheo: (fv?['bs_fair_value'] as num?)?.toDouble(),
        sabrTheo: (fv?['sabr_fair_value'] as num?)?.toDouble(),
        hestonTheo: (fv?['heston_fair_value'] as num?)?.toDouble(),
        modelTheo: (fv?['model_fair_value'] as num?)?.toDouble(),
        delta: contract?.delta,
        gamma: contract?.gamma,
        theta: contract?.theta,
        vega: contract?.vega,
        rho: contract?.rho,
        impliedVol: contract != null
            ? contract.impliedVolatility / 100.0
            : null,
      );
    }));

    final rows = snapshots.map((s) => s.toSupabaseInsert()).toList();
    await _db
        .from('position_leg_snapshots')
        .upsert(rows, onConflict: 'leg_id,snapshot_date,snapshot_type');
  }
}

final positionsProvider =
    StateNotifierProvider<PositionsNotifier, List<Position>>(
        (ref) => PositionsNotifier(ref));

// ── Enriched positions (live Schwab + fair-value model prices) ────────────────

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

// ── Snapshot history per leg ──────────────────────────────────────────────────

final legSnapshotsProvider =
    FutureProvider.family<List<LegSnapshot>, String>((ref, legId) async {
  final rows = await _db
      .from('position_leg_snapshots')
      .select()
      .eq('leg_id', legId)
      .order('snapshot_date')
      .order('snapshot_type');
  return (rows as List)
      .map((r) => LegSnapshot.fromSupabase(r as Map<String, dynamic>))
      .toList();
});
