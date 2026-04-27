// =============================================================================
// features/summary/widgets/ticker_insights_section.dart
// =============================================================================
// Horizontal-scrolling per-ticker insight cards for the home dashboard.
// Surfaces three data layers per ticker without requiring a live chain fetch:
//
//   IV Analytics  — latest IvSnapshot from Supabase (IVR, gammaRegime, ivGexSignal, vanna)
//   Regime ML     — TickerRegimeResult from /regime/ml-analyze (one shared call)
//   Greek Grid    — latest ATM band from greek_grid_snapshots (per-ticker Supabase query)
//
// Tickers shown = union of watchedTickers + currently-open trade tickers, sorted.
// Tap a card to navigate to /ticker/<symbol>.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/economy/economy_snapshot_models.dart';
import '../../../features/economy/providers/api_data_providers.dart';
import '../../../services/iv/iv_storage_service.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../../current_regime/models/regime_ml_models.dart';
import '../../current_regime/providers/regime_ml_provider.dart';
import '../../greek_grid/models/greek_grid_models.dart';
import '../../greek_grid/providers/greek_grid_providers.dart';
import '../../ticker_profile/providers/ticker_profile_providers.dart';
import '../../trades/models/trade.dart';
import '../../trades/providers/trades_provider.dart';

// ── Bundled data provider ──────────────────────────────────────────────────────
// Fetches the merged ticker list and their latest IV snapshots in one shot.
// Using a non-family FutureProvider avoids List<String> key equality issues.

typedef _InsightsData = ({List<String> tickers, Map<String, IvSnapshot> ivMap});

final tickerInsightsDataProvider = FutureProvider<_InsightsData>((ref) async {
  final watched = await ref.watch(watchedTickersProvider.future);
  final trades  = await ref.watch(tradesProvider.future);

  final openTickers = trades
      .where((t) => t.status == TradeStatus.open)
      .map((t) => t.ticker.toUpperCase())
      .toSet();

  final all = {
    ...watched.map((t) => t.toUpperCase()),
    ...openTickers,
  }.toList()..sort();

  final ivMap = await IvStorageService().getLatestBatch(all);
  return (tickers: all, ivMap: ivMap);
});

// ── Section ────────────────────────────────────────────────────────────────────

class TickerInsightsSection extends ConsumerWidget {
  const TickerInsightsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync   = ref.watch(tickerInsightsDataProvider);
    final regimeAsync = ref.watch(regimeMlProvider);
    final pulseAsync  = ref.watch(economyPulseProvider);

    return dataAsync.when(
      loading: () => const SizedBox(
        height: 64,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (data) {
        if (data.tickers.isEmpty) return const SizedBox.shrink();

        final regimeTickers = regimeAsync.valueOrNull?.tickers ?? [];
        final pulse = pulseAsync.valueOrNull;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pulse != null) _MacroContextBar(pulse: pulse),
            if (pulse != null) const SizedBox(height: 10),
            SizedBox(
              height: 215,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: data.tickers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final ticker = data.tickers[i];
                  final ivSnap = data.ivMap[ticker];
                  final regime = regimeTickers
                      .where((r) => r.ticker == ticker)
                      .firstOrNull;
                  return _TickerInsightCard(
                    ticker: ticker,
                    ivSnap: ivSnap,
                    regimeResult: regime,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Macro context bar ──────────────────────────────────────────────────────────
// One-line row of market-level chips shown above the per-ticker scroll list.
// Data comes from economyPulseProvider (Schwab quotes — no chain fetch needed).

class _MacroContextBar extends StatelessWidget {
  final EconomyPulseData pulse;
  const _MacroContextBar({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (pulse.vix != null) _vixChip(pulse.vix!),
        if (pulse.sp500 != null) _changeChip('SPY', pulse.sp500!.changePercent),
        if (pulse.nasdaq != null) _changeChip('QQQ', pulse.nasdaq!.changePercent),
        if (pulse.hyg != null) _changeChip('HYG', pulse.hyg!.changePercent, label: 'Credit'),
        if (pulse.dxy != null) _changeChip('DXY', pulse.dxy!.changePercent),
      ],
    );
  }

  Widget _vixChip(StockQuote vix) {
    final v = vix.price;
    final color = v >= 30 ? AppTheme.lossColor
        : v >= 20 ? const Color(0xFFFFAB40)
        : v >= 15 ? AppTheme.neutralColor
        : AppTheme.profitColor;
    final level = v >= 30 ? 'Extreme'
        : v >= 20 ? 'Elevated'
        : v >= 15 ? 'Moderate'
        : 'Low';
    return _chip('VIX ${v.toStringAsFixed(1)}  $level', color);
  }

  Widget _changeChip(String symbol, double chgPct, {String? label}) {
    final color = chgPct >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    final sign  = chgPct >= 0 ? '+' : '';
    final tag   = label ?? symbol;
    return _chip('$tag $sign${chgPct.toStringAsFixed(2)}%', color);
  }

  static Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
    ),
  );
}

// ── Per-ticker card ────────────────────────────────────────────────────────────

class _TickerInsightCard extends ConsumerWidget {
  final String ticker;
  final IvSnapshot? ivSnap;
  final TickerRegimeResult? regimeResult;

  const _TickerInsightCard({
    required this.ticker,
    this.ivSnap,
    this.regimeResult,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quoteAsync = ref.watch(quoteProvider(ticker));
    final greekAsync = ref.watch(greekGridProvider(ticker));

    // Extract latest ATM-band point from greek grid (already cached if visited)
    final latestAtm = greekAsync.whenOrNull(data: (points) {
      if (points.isEmpty) return null;
      final latestDate = (points.toList()
            ..sort((a, b) => b.obsDate.compareTo(a.obsDate)))
          .first
          .obsDate;
      return points
          .where((p) =>
              p.obsDate.year == latestDate.year &&
              p.obsDate.month == latestDate.month &&
              p.obsDate.day == latestDate.day &&
              p.strikeBand == StrikeBand.atm)
          .firstOrNull;
    });

    return GestureDetector(
      onTap: () => context.push('/ticker/$ticker'),
      child: Container(
        width: 232,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppTheme.borderColor.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(quoteAsync),
            const SizedBox(height: 8),
            Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.35)),
            const SizedBox(height: 8),
            if (ivSnap != null) ...[
              _buildIvRow(ivSnap!),
              const SizedBox(height: 7),
            ],
            if (regimeResult != null) ...[
              _buildRegimeRow(regimeResult!),
              const SizedBox(height: 7),
            ],
            if (latestAtm != null) _buildGreekRow(latestAtm),
          ],
        ),
      ),
    );
  }

  // ── Header: ticker symbol + live price ──────────────────────────────────────

  Widget _buildHeader(AsyncValue<StockQuote?> quoteAsync) {
    return quoteAsync.when(
      loading: () => Text(ticker,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      error: (_, _) => Text(ticker,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      data: (q) {
        if (q == null) {
          return Text(ticker,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15));
        }
        final chgColor = q.changePercent >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ticker,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('\$${q.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 11)),
                Text(
                    '${q.changePercent >= 0 ? '+' : ''}${q.changePercent.toStringAsFixed(2)}%',
                    style: TextStyle(color: chgColor, fontSize: 10)),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── IV row ───────────────────────────────────────────────────────────────────

  Widget _buildIvRow(IvSnapshot snap) {
    final chips = <Widget>[];

    if (snap.ivRank != null) {
      chips.add(_chip(
        'IVR ${snap.ivRank!.toStringAsFixed(0)}%',
        _ivRatingColor(snap.ivRating),
      ));
    }

    if (snap.gammaRegime != null) {
      final isPos = snap.gammaRegime == GammaRegime.positive;
      chips.add(_chip(
        isPos ? '+GEX' : '−GEX',
        isPos ? AppTheme.profitColor : AppTheme.lossColor,
      ));
    }

    if (snap.ivGexSignal != null && snap.ivGexSignal != IvGexSignal.unknown) {
      chips.add(_chip(
        snap.ivGexSignal!.label,
        snap.ivGexSignal!.isDangerous ? AppTheme.lossColor : AppTheme.profitColor,
      ));
    }

    if (snap.vannaRegime != null && snap.vannaRegime != VannaRegime.unknown) {
      final vr = snap.vannaRegime!;
      final isBullish = vr == VannaRegime.bullishOnVolCrush ||
          vr == VannaRegime.bullishOnVolSpike;
      chips.add(_chip(
        vr.label,
        isBullish ? AppTheme.profitColor : AppTheme.lossColor,
      ));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('IV ANALYTICS'),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 3, children: chips),
      ],
    );
  }

  // ── Regime row ───────────────────────────────────────────────────────────────

  Widget _buildRegimeRow(TickerRegimeResult r) {
    final isPos  = r.currentRegime == 'positive';
    final color  = isPos ? AppTheme.profitColor : AppTheme.lossColor;
    final score  = r.mlScore;
    final scoreStr = '${score >= 0 ? '+' : ''}${score.toStringAsFixed(2)}';
    final confStr  = '${(r.confidence * 100).toStringAsFixed(0)}% conf';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('REGIME'),
        const SizedBox(height: 4),
        Row(
          children: [
            _chip(r.bucket.shortLabel, color),
            const SizedBox(width: 5),
            Text(scoreStr,
                style: TextStyle(
                    color: color, fontSize: 10, fontWeight: FontWeight.w700)),
            const SizedBox(width: 4),
            Text('·  $confStr',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
          ],
        ),
        if (r.strategyBias.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            r.strategyBias,
            style: const TextStyle(color: Colors.white54, fontSize: 10, height: 1.3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (r.signals.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            '• ${r.signals.first}',
            style: const TextStyle(color: Colors.white38, fontSize: 9, height: 1.3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  // ── Greek Grid ATM row ────────────────────────────────────────────────────────

  Widget _buildGreekRow(GreekGridPoint p) {
    final chips = <Widget>[
      if (p.delta != null)
        _chip('Δ ${p.delta!.toStringAsFixed(2)}', AppTheme.neutralColor),
      if (p.gamma != null)
        _chip('Γ ${p.gamma!.toStringAsFixed(3)}', AppTheme.neutralColor),
      if (p.theta != null)
        _chip('Θ ${p.theta!.toStringAsFixed(2)}', AppTheme.lossColor),
      if (p.iv != null)
        _chip('IV ${(p.iv! * 100).toStringAsFixed(0)}%', const Color(0xFF60A5FA)),
    ];

    if (chips.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('ATM GREEKS'),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 3, children: chips),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  static Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          color: AppTheme.neutralColor,
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      );

  static Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: color, fontSize: 9, fontWeight: FontWeight.w700),
        ),
      );

  static Color _ivRatingColor(IvRating? rating) => switch (rating) {
        IvRating.extreme   => AppTheme.lossColor,
        IvRating.expensive => const Color(0xFFFFAB40),
        IvRating.fair      => AppTheme.neutralColor,
        IvRating.cheap     => AppTheme.profitColor,
        _                  => AppTheme.neutralColor,
      };
}
