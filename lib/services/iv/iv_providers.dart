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
import '../python_api/python_api_client.dart';
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

  // Fetch history for Python's percentile calculations
  final storage = IvStorageService();
  final history = await storage.getHistory(symbol);
  final historyMaps = history.map((s) => s.toJson()).toList();

  final raw = await PythonApiClient.ivAnalytics(
    chain:    chain.rawJson,
    spotPrice: chain.underlyingPrice,
    history:  historyMaps,
  );
  final analysis = IvAnalysis.fromJson(raw);

  // Persist a local snapshot (fire-and-forget)
  storage.saveSnapshot(IvSnapshot(
    ticker:         symbol,
    date:           DateTime.now().toUtc(),
    atmIv:          analysis.currentIv,
    skew:           analysis.skew,
    totalGex:       analysis.totalGex,
    maxGexStrike:   analysis.maxGexStrike,
    putCallRatio:   analysis.putCallRatio,
    underlyingPrice: analysis.underlyingPrice,
    gexByStrike:    (raw['gex_strikes'] as List? ?? [])
                        .cast<Map<String, dynamic>>(),
  ));

  return analysis;
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

/// Called once per chain load to silently persist an IV snapshot via Python.
Future<void> autoIngestIv(SchwabOptionsChain chain) async {
  try {
    await PythonApiClient.ivSnapshot(
      chain:    chain.rawJson,
      spotPrice: chain.underlyingPrice,
      ticker:   chain.symbol,
    );
  } catch (_) {
    // Silent — IV ingestion should never crash the chain screen
  }
}
