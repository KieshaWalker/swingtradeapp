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

class FredSyncWidget extends ConsumerStatefulWidget {
  final Widget child;
  const FredSyncWidget({super.key, required this.child});

  @override
  ConsumerState<FredSyncWidget> createState() => _FredSyncWidgetState();
}

class _FredSyncWidgetState extends ConsumerState<FredSyncWidget> {
  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    ref.listenManual(fredVixProvider, (_, next) {
      next.whenData((series) async {
        await saveFredVix(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredGoldProvider, (_, next) {
      next.whenData((series) async {
        await saveFredGold(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredSilverProvider, (_, next) {
      next.whenData((series) async {
        await saveFredSilver(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredHyOasProvider, (_, next) {
      next.whenData((series) async {
        await saveFredHyOas(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredIgOasProvider, (_, next) {
      next.whenData((series) async {
        await saveFredIgOas(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredSpreadProvider, (_, next) {
      next.whenData((series) async {
        await saveFredSpread(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });

    ref.listenManual(fredFedFundsProvider, (_, next) {
      next.whenData((series) async {
        await saveFredFedFunds(series);
        if (mounted) ref.invalidate(macroScoreProvider);
      });
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
