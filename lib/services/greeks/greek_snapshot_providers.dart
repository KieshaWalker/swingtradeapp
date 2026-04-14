// =============================================================================
// services/greeks/greek_snapshot_providers.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/schwab/schwab_models.dart';
import 'greek_snapshot_models.dart';
import 'greek_snapshot_repository.dart';

final greekSnapshotRepositoryProvider = Provider<GreekSnapshotRepository>(
  (_) => GreekSnapshotRepository(Supabase.instance.client),
);

/// Load the last 90 days of ATM greek snapshots for [symbol].
/// Results are sorted oldest → newest for charting.
final greekHistoryProvider =
    FutureProvider.family<List<GreekSnapshot>, String>((ref, symbol) async {
  final repo = ref.watch(greekSnapshotRepositoryProvider);
  final list = await repo.getHistory(symbol.toUpperCase(), limit: 90);
  return list.reversed.toList(); // oldest first for chart x-axis
});

// =============================================================================
// Auto-ingest helper
// =============================================================================
// Called once per chain load from OptionsChainScreen.
// Finds the ATM call + ATM put from the optimal expiration and persists a
// daily greek snapshot. Errors are swallowed to never disrupt the UI.

/// Find the expiration with DTE closest to 30d (within [7, 90]).
/// Falls back to nearest overall if nothing qualifies.
SchwabOptionsExpiration _selectExpiration(SchwabOptionsChain chain) {
  final preferred = chain.expirations
      .where((e) => e.dte >= 7 && e.dte <= 90)
      .toList();
  final pool = preferred.isNotEmpty ? preferred : chain.expirations;
  return pool.reduce((a, b) =>
      (a.dte - 30).abs() < (b.dte - 30).abs() ? a : b);
}

/// ATM call: call with |delta| closest to 0.50.
SchwabOptionContract? _atmCall(List<SchwabOptionContract> calls) {
  if (calls.isEmpty) return null;
  final withDelta = calls.where((c) => c.delta != 0).toList();
  if (withDelta.isEmpty) return calls.first;
  return withDelta.reduce((a, b) =>
      (a.delta.abs() - 0.50).abs() < (b.delta.abs() - 0.50).abs() ? a : b);
}

/// ATM put: put with |delta| closest to 0.50.
SchwabOptionContract? _atmPut(List<SchwabOptionContract> puts) {
  if (puts.isEmpty) return null;
  final withDelta = puts.where((c) => c.delta != 0).toList();
  if (withDelta.isEmpty) return puts.first;
  return withDelta.reduce((a, b) =>
      (a.delta.abs() - 0.50).abs() < (b.delta.abs() - 0.50).abs() ? a : b);
}

/// Save today's ATM greek snapshot. Call this from the options chain screen.
Future<void> autoIngestGreeks(SchwabOptionsChain chain) async {
  try {
    final exp  = _selectExpiration(chain);
    final call = _atmCall(exp.calls);
    final put  = _atmPut(exp.puts);

    final now   = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);

    final snap = GreekSnapshot(
      ticker:          chain.symbol,
      obsDate:         today,
      underlyingPrice: chain.underlyingPrice,
      // Call
      callStrike: call?.strikePrice,
      callDte:    call?.daysToExpiration,
      callDelta:  call?.delta,
      callGamma:  call?.gamma,
      callTheta:  call?.theta,
      callVega:   call?.vega,
      callRho:    call?.rho,
      callIv:     call?.impliedVolatility,
      callOi:     call?.openInterest,
      // Put
      putStrike:  put?.strikePrice,
      putDte:     put?.daysToExpiration,
      putDelta:   put?.delta,
      putGamma:   put?.gamma,
      putTheta:   put?.theta,
      putVega:    put?.vega,
      putRho:     put?.rho,
      putIv:      put?.impliedVolatility,
      putOi:      put?.openInterest,
    );

    await GreekSnapshotRepository(Supabase.instance.client).save(snap);
  } catch (_) {
    // Never disrupt the options chain UI on ingest failure.
  }
}
