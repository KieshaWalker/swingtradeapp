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
import 'package:supabase_flutter/supabase_flutter.dart';
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

  // Load history and live risk-free rate in parallel
  final storage = IvStorageService();
  final snap    = IvAnalyticsService.snapshotFromChain(chain);

  final historyFuture      = storage.getHistory(symbol);
  final riskFreeRateFuture = _fetchRiskFreeRate();
  final history            = await historyFuture;
  final riskFreeRate       = await riskFreeRateFuture;

  // Persist today's snapshot (fire-and-forget, don't block UI)
  storage.saveSnapshot(snap);

  return IvAnalyticsService.analyse(chain, history,
      riskFreeRate: riskFreeRate);
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

/// Fetches the latest FRED DFF (Fed Funds rate) from economy_indicator_snapshots.
/// Returns null on any error so the caller can fall back to the hardcoded default.
Future<double?> _fetchRiskFreeRate() async {
  try {
    final db = Supabase.instance.client;
    final rows = await db
        .from('economy_indicator_snapshots')
        .select('value')
        .eq('identifier', 'DFF')
        .order('date', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final raw = rows.first['value'];
    if (raw == null) return null;
    return (raw as num).toDouble();
  } catch (_) {
    return null;
  }
}

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
