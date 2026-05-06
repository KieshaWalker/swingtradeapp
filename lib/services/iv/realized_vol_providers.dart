// =============================================================================
// services/iv/realized_vol_providers.dart
// =============================================================================
// Riverpod providers for Realized Volatility.
//
// RV is computed entirely in the Python backend (expected_move_pull job) and
// persisted to realized_vol_snapshots. Flutter only reads from DB.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/providers/auth_provider.dart';
import 'realized_vol_models.dart';
import 'realized_vol_repository.dart';

// ── Repository singleton ───────────────────────────────────────────────────

final realizedVolRepositoryProvider = Provider<RealizedVolRepository>((ref) {
  return RealizedVolRepository(ref.watch(supabaseClientProvider));
});

// ── Latest snapshot ────────────────────────────────────────────────────────

/// Latest RV snapshot for a ticker, as written by the backend EOD job.
final realizedVolProvider =
    FutureProvider.family<RealizedVolSnapshot?, String>((ref, symbol) {
  return ref.read(realizedVolRepositoryProvider).getLatest(symbol);
});

// ── RV history (for time-series / sparklines) ──────────────────────────────

final realizedVolHistoryProvider =
    FutureProvider.family<List<RealizedVolSnapshot>, String>((ref, symbol) {
  return ref.read(realizedVolRepositoryProvider).getHistory(symbol);
});
