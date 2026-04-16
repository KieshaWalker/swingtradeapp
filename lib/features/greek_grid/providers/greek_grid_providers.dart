// =============================================================================
// features/greek_grid/providers/greek_grid_providers.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/greek_grid_models.dart';
import '../services/greek_grid_repository.dart';

// ── Repository ────────────────────────────────────────────────────────────────

final _repoProvider = Provider<GreekGridRepository>(
  (_) => GreekGridRepository(Supabase.instance.client),
);

// ── Main notifier — all history for one ticker ────────────────────────────────

class GreekGridNotifier
    extends FamilyAsyncNotifier<List<GreekGridPoint>, String> {
  @override
  Future<List<GreekGridPoint>> build(String ticker) =>
      ref.read(_repoProvider).loadAll(ticker);

  Future<int> purgeExpired() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return 0;
    final count = await ref.read(_repoProvider).purgeExpired(userId);
    ref.invalidateSelf();
    return count;
  }
}

final greekGridProvider = AsyncNotifierProvider.family<
    GreekGridNotifier, List<GreekGridPoint>, String>(
  GreekGridNotifier.new,
);

// ── Derived: snapshot for one obs_date ───────────────────────────────────────
// Returns null while loading or if no data for that date.

final greekGridSnapshotProvider =
    Provider.family<GreekGridSnapshot?, (String, DateTime)>((ref, params) {
  final (ticker, obsDate) = params;
  return ref.watch(greekGridProvider(ticker)).whenOrNull(data: (points) {
    final filtered = points
        .where((p) =>
            p.obsDate.year  == obsDate.year &&
            p.obsDate.month == obsDate.month &&
            p.obsDate.day   == obsDate.day)
        .toList();
    if (filtered.isEmpty) return null;
    return GreekGridSnapshot(
        ticker: ticker, obsDate: obsDate, points: filtered);
  });
});

// ── Derived: all obs_dates available for a ticker ─────────────────────────────

final greekGridObsDatesProvider =
    Provider.family<List<DateTime>, String>((ref, ticker) {
  return ref.watch(greekGridProvider(ticker)).whenOrNull(data: (points) {
        final dates = points
            .map((p) => DateTime.utc(p.obsDate.year, p.obsDate.month, p.obsDate.day))
            .toSet()
            .toList()
          ..sort();
        return dates;
      }) ??
      [];
});

// ── Derived: time-series for one cell (band × bucket) ────────────────────────

final greekGridTimeSeriesProvider = Provider.family<List<GreekGridPoint>,
    (String, StrikeBand, ExpiryBucket)>((ref, params) {
  final (ticker, band, bucket) = params;
  return ref.watch(greekGridProvider(ticker)).whenOrNull(data: (points) =>
          points
              .where((p) => p.strikeBand == band && p.expiryBucket == bucket)
              .toList()
            ..sort((a, b) => a.obsDate.compareTo(b.obsDate))) ??
      [];
});
