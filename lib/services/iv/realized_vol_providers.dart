// =============================================================================
// services/iv/realized_vol_providers.dart
// =============================================================================
// Riverpod providers for Realized Volatility:
//
//   realizedVolProvider(symbol)
//     — Live computation: fetch quotes + history, compute RV, auto-persist.
//     — FutureProvider.family; keyed by ticker
//     — Called by Vol Surface Gate (Phase 4) and dashboard widgets
//
//   realizedVolRepositoryProvider
//     — Singleton repository for Supabase I/O
//
//   realizedVolHistoryProvider(symbol)
//     — Raw list of RealizedVolSnapshot for time-series or sparklines
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:developer' as developer;
import '../../features/auth/providers/auth_provider.dart';
import '../python_api/python_api_client.dart';
import 'realized_vol_models.dart';
import 'realized_vol_repository.dart';

// ── Repository singleton ───────────────────────────────────────────────────

final realizedVolRepositoryProvider = Provider<RealizedVolRepository>((ref) {
  return RealizedVolRepository(ref.watch(supabaseClientProvider));
});

// ── Live RV computation (quotes fetch + service compute + auto-persist) ─────

/// Compute RV from quote history and persist the result.
///
/// Flow:
///   1. Fetch 252 days of daily closes from economy_quote_snapshots
///   2. Fetch RV history (252 days) for percentile ranking
///   3. Run RealizedVolService.computeFromQuotes()
///   4. Save today's snapshot to realized_vol_snapshots
///   5. Return RealizedVolResult
///
/// If quote table is empty or unavailable, returns RealizedVolResult.noData.
final realizedVolProvider = FutureProvider.family<RealizedVolResult, String>((
  ref,
  symbol,
) async {
  final repo = ref.watch(realizedVolRepositoryProvider);

  // Fetch latest 252 daily closes (52 weeks)
  final quoteRows = await repo.getQuoteHistory(symbol, limit: 252);
  if (quoteRows.isEmpty) {
    // No price history available yet
    return RealizedVolResult(
      rv20d: 0.0,
      rv60d: 0.0,
      rv20dPercentile: null,
      rv60dPercentile: null,
      rating: RealizedVolRating.noData,
      rv20dHistory: [],
      rv60dHistory: [],
      computedAt: DateTime.now().toUtc(),
    );
  }

  // Extract prices (oldest first)
  final prices = quoteRows.map((r) => (r['price'] as num).toDouble()).toList();

  // Fetch RV history for percentile ranking
  final rvHistory = await repo.getHistory(symbol, limit: 252);

  // Compute RV via Python API
  final historyRv20d = rvHistory.map((s) => s.rv20d).toList();
  final historyRv60d = rvHistory.map((s) => s.rv60d).toList();
  final raw = await PythonApiClient.realizedVolCompute(
    closes:       prices,
    historyRv20d: historyRv20d,
    historyRv60d: historyRv60d,
  );
  final result = RealizedVolResult.fromJson(raw);

  // Auto-persist today's snapshot
  try {
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);

    await repo.save(
      RealizedVolSnapshot(
        symbol: symbol,
        date: today,
        rv20d: result.rv20d,
        rv60d: result.rv60d,
        rv20dPercentile: result.rv20dPercentile,
        rv60dPercentile: result.rv60dPercentile,
        persistedAt: now,
      ),
    );
  } catch (e) {
    // Silently ignore persistence errors; UI still gets the result
    developer.log('RealizedVolProvider: failed to persist for $symbol: $e');
  }

  return result;
});

// ── RV history (for time-series / sparklines) ──────────────────────────────

final realizedVolHistoryProvider =
    FutureProvider.family<List<RealizedVolSnapshot>, String>((ref, symbol) {
      return ref.read(realizedVolRepositoryProvider).getHistory(symbol);
    });
