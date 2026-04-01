// =============================================================================
// features/macro/fred_sync_widget.dart
// =============================================================================
// Silent background widget — wraps any screen and triggers all FRED fetches.
// When each series arrives it is persisted to Supabase, then macroScoreProvider
// is invalidated so the score recomputes with the fresh history.
//
// Usage: wrap DashboardScreen body (or any screen) with FredSyncWidget.
// It renders its [child] immediately; FRED calls happen in the background.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/fred/fred_providers.dart';
import '../../services/macro/macro_score_provider.dart';

class FredSyncWidget extends ConsumerWidget {
  final Widget child;
  const FredSyncWidget({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // VIX
    ref.listen(fredVixProvider, (_, next) {
      next.whenData((series) async {
        await saveFredVix(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // Gold
    ref.listen(fredGoldProvider, (_, next) {
      next.whenData((series) async {
        await saveFredGold(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // Silver
    ref.listen(fredSilverProvider, (_, next) {
      next.whenData((series) async {
        await saveFredSilver(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // HY OAS
    ref.listen(fredHyOasProvider, (_, next) {
      next.whenData((series) async {
        await saveFredHyOas(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // IG OAS
    ref.listen(fredIgOasProvider, (_, next) {
      next.whenData((series) async {
        await saveFredIgOas(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // 2s10s Spread
    ref.listen(fredSpreadProvider, (_, next) {
      next.whenData((series) async {
        await saveFredSpread(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    // Fed Funds
    ref.listen(fredFedFundsProvider, (_, next) {
      next.whenData((series) async {
        await saveFredFedFunds(series);
        ref.invalidate(macroScoreProvider);
      });
    });

    return child;
  }
}
