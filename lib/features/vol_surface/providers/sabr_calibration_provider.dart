// =============================================================================
// vol_surface/providers/sabr_calibration_provider.dart
// =============================================================================
// Riverpod provider that wraps SABR surface calibration.
//
// Flow:
//   1. sabr_calibration_provider(ticker) watches volSurfaceProvider.
//   2. When the latest snapshot for the ticker arrives, it runs
//      SabrCalibrator.calibrate() in a background Isolate.
//   3. Results are persisted to sabr_calibrations via SabrCalibrationRepository.
//   4. Other providers (e.g. FairValueEngine) read
//      sabrSliceProvider((ticker, dte)) to get the closest calibrated slice.
//
// The family key is the ticker symbol (upper-cased).
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/vol_surface/sabr_calibrator.dart';
import 'vol_surface_provider.dart';

// ── Repository ────────────────────────────────────────────────────────────────

class SabrCalibrationRepository {
  final SupabaseClient _db;
  SabrCalibrationRepository(this._db);

  Future<void> upsertSlices(
    List<SabrSlice> slices,
    String          ticker,
    DateTime        obsDate,
  ) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null || slices.isEmpty) return;

    final obsDateStr = obsDate.toIso8601String().substring(0, 10);

    final rows = slices.map((s) => {
      'user_id':       userId,
      'ticker':        ticker.toUpperCase(),
      'obs_date':      obsDateStr,
      'dte':           s.dte,
      'alpha':         s.alpha,
      'beta':          s.beta,
      'rho':           s.rho,
      'nu':            s.nu,
      'rmse':          s.rmse,
      'n_points':      s.nPoints,
      'calibrated_at': DateTime.now().toUtc().toIso8601String(),
    }).toList();

    await _db
        .from('sabr_calibrations')
        .upsert(rows, onConflict: 'user_id,ticker,obs_date,dte');
  }

  /// Load the most recent calibration for [ticker] (all slices for latest obs_date).
  Future<List<SabrSlice>> loadLatest(String ticker) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];

    // Find the latest obs_date for this ticker
    final latestRow = await _db
        .from('sabr_calibrations')
        .select('obs_date')
        .eq('user_id', userId)
        .eq('ticker', ticker.toUpperCase())
        .order('obs_date', ascending: false)
        .limit(1)
        .maybeSingle();

    if (latestRow == null) return [];
    final latestDate = latestRow['obs_date'] as String;

    final rows = await _db
        .from('sabr_calibrations')
        .select()
        .eq('user_id', userId)
        .eq('ticker', ticker.toUpperCase())
        .eq('obs_date', latestDate)
        .order('dte', ascending: true);

    return (rows as List)
        .map((r) => SabrSlice.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final _sabrRepoProvider = Provider<SabrCalibrationRepository>(
  (_) => SabrCalibrationRepository(Supabase.instance.client),
);

/// Runs SABR calibration for [ticker] whenever the vol surface updates.
/// Returns the list of calibrated slices (one per DTE), or [] while loading.
///
/// This provider is watched by [sabrSliceProvider] — consumers should use
/// that family provider for point lookups rather than this one directly.
final sabrCalibrationProvider = AsyncNotifierProvider.family<
    _SabrCalibrationNotifier, List<SabrSlice>, String>(
  _SabrCalibrationNotifier.new,
);

class _SabrCalibrationNotifier
    extends FamilyAsyncNotifier<List<SabrSlice>, String> {
  @override
  Future<List<SabrSlice>> build(String ticker) async {
    // Watch vol surface — re-calibrate when new snapshots arrive.
    final snaps = await ref.watch(volSurfaceProvider.future);

    final filtered = snaps
        .where((s) => s.ticker.toUpperCase() == ticker.toUpperCase())
        .toList()
      ..sort((a, b) => b.obsDate.compareTo(a.obsDate));

    if (filtered.isEmpty) {
      // No surface data yet — fall back to last persisted calibration.
      return ref.read(_sabrRepoProvider).loadLatest(ticker);
    }

    final latest = filtered.first;
    final slices = await SabrCalibrator.calibrate(latest);

    // Persist in background — don't await, never block the UI.
    ref.read(_sabrRepoProvider).upsertSlices(
      slices, ticker, latest.obsDate,
    ).ignore();

    return slices;
  }
}

/// Point-lookup: returns the calibrated [SabrSlice] closest to [targetDte]
/// for the given [ticker], or null if calibration hasn't completed yet.
///
/// Usage in FairValueEngine:
///   final slice = ref.watch(sabrSliceProvider((ticker, daysToExpiry)));
final sabrSliceProvider =
    Provider.family<SabrSlice?, (String, int)>((ref, params) {
  final (ticker, targetDte) = params;
  final async = ref.watch(sabrCalibrationProvider(ticker));
  return async.whenOrNull(
    data: (slices) => SabrCalibrator.sliceForDte(slices, targetDte),
  );
});
