// =============================================================================
// services/iv/iv_providers.dart
// =============================================================================
// Riverpod providers for the IV Analytics Engine.
//
//  ivAnalysisProvider(symbol)
//    — Loads chain + history, runs analytics, saves today's snapshot.
//    — FutureProvider.family keyed by ticker symbol.
//    — Called by IvScreen and also auto-triggered by OptionsChainScreen.
//
//  ivHistoryProvider(symbol)
//    — Raw list of IvSnapshot rows for sparklines / history table.
//
//  ivWatchlistProvider(symbols)
//    — Batch latest-snapshot map for the watchlist summary row.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/schwab/schwab_models.dart';
import '../../services/schwab/schwab_providers.dart';
import 'iv_analytics_service.dart';
import 'iv_models.dart';
import 'iv_storage_service.dart';

// ── Full analysis (chain + history → IvAnalysis) ──────────────────────────────

final ivAnalysisProvider =
    FutureProvider.family<IvAnalysis, String>((ref, symbol) async {
  // Fetch chain (reuse existing chain provider with default params)
  final chain = await ref.read(
    schwabOptionsChainProvider(OptionsChainParams(
      symbol:      symbol,
      contractType: 'ALL',
      strikeCount:  20, // wider for better skew coverage
    )).future,
  );

  if (chain == null) {
    throw Exception('No options chain data for $symbol');
  }

  // Load history and save today's snapshot in parallel
  final storage = IvStorageService();
  final snap    = IvAnalyticsService.snapshotFromChain(chain);

  final history = await storage.getHistory(symbol);

  // Persist today's snapshot (fire-and-forget, don't block UI)
  storage.saveSnapshot(snap);

  return IvAnalyticsService.analyse(chain, history);
});

// ── Raw snapshot history (for sparklines / table) ─────────────────────────────

final ivHistoryProvider =
    FutureProvider.family<List<IvSnapshot>, String>((ref, symbol) async {
  return IvStorageService().getHistory(symbol);
});

// ── Batch latest for watchlist ────────────────────────────────────────────────

final ivWatchlistProvider =
    FutureProvider.family<Map<String, IvSnapshot>, List<String>>(
        (ref, symbols) async {
  return IvStorageService().getLatestBatch(symbols);
});

// ── Auto-ingest helper (call from OptionsChainScreen on chain load) ───────────

/// Called once per chain load to silently persist an IV snapshot.
/// Does not block the UI — errors are swallowed to avoid disrupting chain view.
Future<void> autoIngestIv(SchwabOptionsChain chain) async {
  try {
    final snap = IvAnalyticsService.snapshotFromChain(chain);
    await IvStorageService().saveSnapshot(snap);
  } catch (_) {
    // Silent — IV ingestion should never crash the chain screen
  }
}
