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

/// DTE targets captured on each chain load.
const _dteBuckets = [4, 7, 31];

/// Load the last 90 days of ATM greek snapshots for [symbol] at a specific
/// [dteBucket] (4, 7, or 31). Results sorted oldest → newest for charting.
///
/// Family key: (symbol, dteBucket)
final greekHistoryProvider =
    FutureProvider.family<List<GreekSnapshot>, (String, int)>(
        (ref, params) async {
  final (symbol, dteBucket) = params;
  final repo = ref.watch(greekSnapshotRepositoryProvider);
  final list = await repo.getHistory(
    symbol.toUpperCase(),
    dteBucket: dteBucket,
    limit: 90,
  );
  return list.reversed.toList(); // oldest first for chart x-axis
});

// =============================================================================
// Auto-ingest helper
// =============================================================================
// Called once per chain load from OptionsChainScreen.
// Saves THREE rows per day — one for each DTE bucket (4, 7, 31) — each
// selecting the expiry with DTE closest to that target.
// Errors are swallowed to never disrupt the UI.

/// Find the expiration with DTE closest to [targetDte].
SchwabOptionsExpiration _selectNearestExpiry(
    SchwabOptionsChain chain, int targetDte) {
  if (chain.expirations.isEmpty) throw StateError('No expirations in chain');
  return chain.expirations.reduce((a, b) =>
      (a.dte - targetDte).abs() < (b.dte - targetDte).abs() ? a : b);
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

/// Save today's ATM greek snapshots across all DTE buckets [4, 7, 31].
/// Call this from the options chain screen on each chain load.
Future<void> autoIngestGreeks(SchwabOptionsChain chain) async {
  final repo = GreekSnapshotRepository(Supabase.instance.client);
  final now   = DateTime.now().toUtc();
  final today = DateTime.utc(now.year, now.month, now.day);

  for (final targetDte in _dteBuckets) {
    try {
      final exp  = _selectNearestExpiry(chain, targetDte);
      final call = _atmCall(exp.calls);
      final put  = _atmPut(exp.puts);

      final snap = GreekSnapshot(
        ticker:          chain.symbol,
        obsDate:         today,
        underlyingPrice: chain.underlyingPrice,
        dteBucket:       targetDte,
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

      await repo.save(snap);
    } catch (_) {
      // Never disrupt the options chain UI on ingest failure.
    }
  }
}
