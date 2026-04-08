// =============================================================================
// features/iv/screens/iv_screen.dart
// =============================================================================
// IV Analytics screen — per-ticker view with:
//   • IV Rank gauge (IVR + IVP + 52w range)
//   • Volatility skew curve
//   • Gamma Exposure (GEX) bar chart + gamma wall
//
// Route: /ticker/:symbol/iv
// Pushed from TickerProfileScreen or OptionsChainScreen "IV" button.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_providers.dart';
import '../widgets/gex_chart.dart';
import '../widgets/iv_rank_gauge.dart';
import '../widgets/skew_chart.dart';
import '../widgets/vanna_charm_chart.dart';

class IvScreen extends ConsumerWidget {
  final String symbol;
  const IvScreen({super.key, required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ivAnalysisProvider(symbol));

    return Scaffold(
      appBar: AppBar(
        title: Text('$symbol — IV Analytics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(ivAnalysisProvider(symbol)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => _ErrorView(symbol: symbol, error: e, ref: ref),
        data:    (analysis) => RefreshIndicator(
          color:     AppTheme.profitColor,
          onRefresh: () async {
            ref.invalidate(ivAnalysisProvider(symbol));
            await ref.read(ivAnalysisProvider(symbol).future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              // ── IV Rank ──────────────────────────────────────────────────
              IvRankGauge(analysis: analysis),
              const SizedBox(height: 16),

              // ── Skew curve ───────────────────────────────────────────────
              SkewChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── GEX chart ────────────────────────────────────────────────
              GexChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── Vanna / Charm / Volga ────────────────────────────────────
              VannaCharmChart(analysis: analysis),
              const SizedBox(height: 16),

              // ── Trader summary card ──────────────────────────────────────
              _SummaryCard(analysis: analysis),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String symbol;
  final Object error;
  final WidgetRef ref;
  const _ErrorView({
    required this.symbol,
    required this.error,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart_rounded,
                size: 48, color: AppTheme.neutralColor),
            const SizedBox(height: 16),
            Text(
              'Could not load IV data for $symbol',
              style: const TextStyle(color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text('$error',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon:      const Icon(Icons.refresh_rounded, size: 16),
              label:     const Text('Retry'),
              onPressed: () => ref.invalidate(ivAnalysisProvider(symbol)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Trader summary card ────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final dynamic analysis; // IvAnalysis
  const _SummaryCard({required this.analysis});

  @override
  Widget build(BuildContext context) {
    // Build a concise strategy suggestion based on IVR + skew + GEX
    final ivr   = analysis.ivRank as double?;
    final skew  = analysis.skew  as double?;
    final gex   = analysis.totalGex as double?;

    final bullets = <String>[];

    // IV-based suggestion
    if (ivr != null) {
      if (ivr >= 80) {
        bullets.add('IV is extremely elevated (IVR ${ivr.toStringAsFixed(0)}%) — '
            'premium selling strategies favored: iron condors, short strangles, credit spreads.');
      } else if (ivr >= 50) {
        bullets.add('IV above average (IVR ${ivr.toStringAsFixed(0)}%) — '
            'consider vertical spreads to limit vega exposure.');
      } else if (ivr >= 25) {
        bullets.add('IV near fair value (IVR ${ivr.toStringAsFixed(0)}%) — '
            'neutral conditions; directional debit or credit spreads both viable.');
      } else {
        bullets.add('IV compressed (IVR ${ivr.toStringAsFixed(0)}%) — '
            'long premium strategies favored: debit spreads, calendars, LEAPS.');
      }
    }

    // Skew-based suggestion
    if (skew != null) {
      if (skew > 8) {
        bullets.add('Steep put skew signals elevated tail fear — '
            'put spreads offer better risk/reward than naked puts.');
      } else if (skew < 1) {
        bullets.add('Flat/inverted skew — calls relatively cheap; '
            'call spreads may offer better value than puts.');
      }
    }

    // GEX-based suggestion
    if (gex != null) {
      if (gex > 0) {
        bullets.add('Positive GEX environment — '
            'price likely to revert to the gamma wall. '
            'Range-bound strategies (iron condors) perform well.');
      } else {
        bullets.add('Negative GEX environment — '
            'directional moves can accelerate. '
            'Favor directional spreads with defined risk.');
      }
    }

    if (bullets.isEmpty) {
      bullets.add('Load an options chain for this ticker to generate strategy suggestions.');
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'STRATEGY CONTEXT',
            style: TextStyle(
              color:      AppTheme.neutralColor,
              fontSize:   11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          ...bullets.map((b) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 5, height: 5,
                  decoration: const BoxDecoration(
                    color:  AppTheme.profitColor,
                    shape:  BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(b,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
