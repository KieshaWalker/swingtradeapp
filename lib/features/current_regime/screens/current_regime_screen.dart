// =============================================================================
// features/current_regime/screens/current_regime_screen.dart
// =============================================================================
// Current Regime — ML-enhanced market & individual stock regime dashboard.
//
// Layout:
//   1. Market Context strip  — VIX state, term structure, SPY gamma, breadth
//   2. ML Intelligence panel — 14-feature legend, model metrics
//   3. Regime Glossary       — plain-English explanation of the 4 buckets
//   4. Ticker Regime Matrix  — 4 buckets; tap any ticker for full interpretation
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/macro/macro_score_provider.dart';
import '../../../services/macro/macro_score_model.dart';
import '../models/regime_ml_models.dart';
import '../providers/regime_ml_provider.dart';

// ── Palette helpers ───────────────────────────────────────────────────────────

Color _bucketColor(RegimeBucket b) => switch (b) {
  RegimeBucket.stablePositive   => const Color(0xFF4ADE80),
  RegimeBucket.trendingPositive => const Color(0xFF86EFAC),
  RegimeBucket.trendingNegative => const Color(0xFFFCA5A5),
  RegimeBucket.stableNegative   => const Color(0xFFFF6B8A),
  RegimeBucket.unknown          => Colors.white38,
};

Color _regimeColor(String regime) => switch (regime) {
  'positive' => AppTheme.profitColor,
  'negative' => AppTheme.lossColor,
  _          => AppTheme.neutralColor,
};

Color _biasColor(String bias) => switch (bias) {
  'directional_bullish' => AppTheme.profitColor,
  'directional_bearish' => AppTheme.lossColor,
  'straddle_only'       => const Color(0xFFFBBF24),
  'premium_sell'        => const Color(0xFF60A5FA),
  _                     => Colors.white38,
};

String _biasShortLabel(String bias) => switch (bias) {
  'directional_bullish' => 'BULL',
  'directional_bearish' => 'BEAR',
  'straddle_only'       => 'STRDL',
  'premium_sell'        => 'PREM',
  _                     => 'UNCL',
};

// ── Formatters ────────────────────────────────────────────────────────────────

String _pct(double? v, {int decimals = 1}) =>
    v == null ? '—' : '${v.toStringAsFixed(decimals)}%';

String _score(double v) =>
    v >= 0 ? '+${v.toStringAsFixed(2)}' : v.toStringAsFixed(2);

String _signed(double? v, {int decimals = 2, String suffix = ''}) {
  if (v == null) return '—';
  final s = v >= 0 ? '+' : '';
  return '$s${v.toStringAsFixed(decimals)}$suffix';
}

// ── Root screen ───────────────────────────────────────────────────────────────

class CurrentRegimeScreen extends ConsumerWidget {
  const CurrentRegimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mlAsync    = ref.watch(regimeMlProvider);
    final macroAsync = ref.watch(macroScoreProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Current Regime'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            color: Colors.white70,
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(regimeMlProvider);
              ref.invalidate(macroScoreProvider);
            },
          ),
          const AppMenuButton(),
        ],
      ),
      body: mlAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => _ErrorBody(error: e.toString()),
        data:    (a) => _Body(analysis: a, macroAsync: macroAsync),
      ),
    );
  }
}

// ── Body ──────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final RegimeMlAnalysis    analysis;
  final AsyncValue<MacroScore> macroAsync;

  const _Body({required this.analysis, required this.macroAsync});

  @override
  Widget build(BuildContext context) {
    final spyRegime = analysis.marketContext.spyRegime;
    final spyGamma  = spyRegime?['gamma_regime'] as String? ?? 'unknown';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        // 1. Market Context
        _SectionHeader('Market Context'),
        const SizedBox(height: 8),
        _MarketContextStrip(
          analysis:  analysis,
          macroAsync: macroAsync,
          spyGamma:  spyGamma,
        ),
        const SizedBox(height: 20),

        // 2. ML Intelligence
        _SectionHeader('ML Intelligence'),
        const SizedBox(height: 4),
        Text(
          'Scoring uses 14 feature dimensions derived from rolling regime history. '
          'Each ticker is scored −1 (strongly negative gamma) to +1 (strongly positive gamma).',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
        ),
        const SizedBox(height: 10),
        _ModelInfoCard(meta: analysis.modelMetadata),
        const SizedBox(height: 10),
        _FeatureWeightLegend(meta: analysis.modelMetadata),
        const SizedBox(height: 20),

        // 3. Regime Glossary
        _SectionHeader('What the Buckets Mean'),
        const SizedBox(height: 8),
        const _BucketGlossary(),
        const SizedBox(height: 20),

        // 4. Ticker Matrix
        _SectionHeader('Ticker Regime Matrix'),
        const SizedBox(height: 4),
        Text(
          'Tap any ticker to see interpretation, strategy guidance, and full signal breakdown.',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _TickerMatrix(analysis: analysis),

        const SizedBox(height: 16),
        Center(
          child: Text(
            'Last updated ${DateFormat('MMM d, HH:mm').format(analysis.asOf.toLocal())}',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontWeight: FontWeight.w700,
    ),
  );
}

// ── Market Context Strip ──────────────────────────────────────────────────────

class _MarketContextStrip extends StatelessWidget {
  final RegimeMlAnalysis    analysis;
  final AsyncValue<MacroScore> macroAsync;
  final String              spyGamma;

  const _MarketContextStrip({
    required this.analysis,
    required this.macroAsync,
    required this.spyGamma,
  });

  @override
  Widget build(BuildContext context) {
    final ctx      = analysis.marketContext;
    final spyRow   = ctx.spyRegime;
    final tsRatio  = (spyRow?['vix_term_structure_ratio'] as num?)?.toDouble();
    final breadth  = (spyRow?['breadth_proxy']            as num?)?.toDouble();

    // Term structure interpretation
    final (tsLabel, tsColor, tsSub) = tsRatio == null
        ? ('—', AppTheme.neutralColor, null)
        : tsRatio > 1.0
          ? ('Backwardation', AppTheme.lossColor,
             'VIX/VIX3M ${tsRatio.toStringAsFixed(3)} — near-term stress')
          : ('Contango', AppTheme.profitColor,
             'VIX/VIX3M ${tsRatio.toStringAsFixed(3)} — calm near-term');

    // Breadth interpretation
    final (breadthLabel, breadthColor, breadthSub) = breadth == null
        ? ('—', AppTheme.neutralColor, null)
        : breadth < -1.5
          ? ('Diverging', AppTheme.lossColor,
             'z ${breadth.toStringAsFixed(1)} — narrow rally')
          : breadth > 1.5
            ? ('Broad', AppTheme.profitColor,
               'z ${breadth.toStringAsFixed(1)} — wide participation')
            : ('Neutral', AppTheme.neutralColor,
               'z ${breadth.toStringAsFixed(1)}');

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        // Macro score
        macroAsync.when(
          loading: () => _ContextChip(label: 'Macro', value: '…',
              color: AppTheme.neutralColor),
          error: (e, _) => _ContextChip(label: 'Macro', value: 'Error',
              color: AppTheme.lossColor),
          data: (macro) => _ContextChip(
            label:    'Macro',
            value:    '${macro.total.toStringAsFixed(0)} ${macro.regime.label}',
            color:    _macroColor(macro.regime),
            subtitle: macro.regime.description.length > 40
                ? macro.regime.description.substring(0, 40)
                : macro.regime.description,
          ),
        ),

        // VIX state
        _ContextChip(
          label: 'VIX Regime',
          value: ctx.vixState == 'high_vol' ? 'High Vol'
               : ctx.vixState == 'low_vol'  ? 'Low Vol'
               : '—',
          color: ctx.vixState == 'high_vol'
              ? AppTheme.lossColor : AppTheme.profitColor,
          subtitle: ctx.vixCurrent != null
              ? 'VIX ${ctx.vixCurrent!.toStringAsFixed(1)}'
                '  Dev ${_pct(ctx.vixDevPct)}'
                '  RSI ${ctx.vixRsi?.toStringAsFixed(0) ?? '—'}'
                '  P ${ctx.vixHmmProb != null ? '${(ctx.vixHmmProb! * 100).toStringAsFixed(0)}%' : '—'}'
              : null,
        ),

        // Term structure
        _ContextChip(
          label:    'Term Structure',
          value:    tsLabel,
          color:    tsColor,
          subtitle: tsSub,
        ),

        // SPY gamma
        _ContextChip(
          label: 'SPY Gamma',
          value: spyGamma == 'positive' ? 'Positive'
               : spyGamma == 'negative' ? 'Negative'
               : 'Unknown',
          color: _regimeColor(spyGamma),
          subtitle: spyRow != null
              ? 'ZGL: ${_pct((spyRow['spot_to_zgl_pct'] as num?)?.toDouble())}'
              : null,
        ),

        // Breadth
        _ContextChip(
          label:    'Breadth',
          value:    breadthLabel,
          color:    breadthColor,
          subtitle: breadthSub,
        ),

        // Ticker count
        _ContextChip(
          label: 'Tracked',
          value: '${analysis.tickers.length} tickers',
          color: AppTheme.neutralColor,
          subtitle:
            '${analysis.stablePositive.length}+GEX  '
            '${analysis.trendingPositive.length}↑  '
            '${analysis.trendingNegative.length}↓  '
            '${analysis.stableNegative.length}−GEX',
        ),
      ],
    );
  }

  Color _macroColor(MacroRegime r) => switch (r) {
    MacroRegime.riskOn        => AppTheme.profitColor,
    MacroRegime.neutralBullish => const Color(0xFF86EFAC),
    MacroRegime.neutral        => const Color(0xFFFBBF24),
    MacroRegime.caution        => const Color(0xFFFCA5A5),
    MacroRegime.crisis         => AppTheme.lossColor,
  };
}

class _ContextChip extends StatelessWidget {
  final String  label;
  final String  value;
  final Color   color;
  final String? subtitle;

  const _ContextChip({
    required this.label,
    required this.value,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    constraints: const BoxConstraints(minWidth: 110),
    decoration: BoxDecoration(
      color:        AppTheme.cardColor,
      borderRadius: BorderRadius.circular(10),
      border:       Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
        const SizedBox(height: 3),
        Text(value,
          style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!,
            style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ],
    ),
  );
}

// ── Model Info Card ───────────────────────────────────────────────────────────

class _ModelInfoCard extends StatelessWidget {
  final MlModelMetadata meta;
  const _ModelInfoCard({required this.meta});

  @override
  Widget build(BuildContext context) {
    if (!meta.available) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: Colors.white38, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No trained model — using 14-feature heuristic scoring. '
                'Call POST /regime/train to fit a supervised model.',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    final trainedAt = meta.trainedAt != null
        ? DateTime.tryParse(meta.trainedAt!) : null;
    final typeLabel = switch (meta.modelType) {
      'xgboost'  => 'XGBoost',
      'logistic' => 'Logistic Regression',
      _          => meta.modelType ?? 'Unknown',
    };
    final flipRate = meta.nSamples > 0
        ? (meta.nPositive / meta.nSamples * 100).toStringAsFixed(1) : '—';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Pill(typeLabel, AppTheme.profitColor),
              const SizedBox(width: 8),
              if (trainedAt != null)
                Text(
                  'Trained ${DateFormat('MMM d, HH:mm').format(trainedAt.toLocal())}',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MetricBadge('AUC-ROC',   meta.aucRoc.toStringAsFixed(3)),
              const SizedBox(width: 12),
              _MetricBadge('Accuracy',  '${(meta.accuracy  * 100).toStringAsFixed(1)}%'),
              const SizedBox(width: 12),
              _MetricBadge('Precision', '${(meta.precision * 100).toStringAsFixed(1)}%'),
              const SizedBox(width: 12),
              _MetricBadge('Recall',    '${(meta.recall    * 100).toStringAsFixed(1)}%'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${meta.nSamples} samples · ${meta.nPositive} flip events ($flipRate% base rate)',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MetricBadge extends StatelessWidget {
  final String label, value;
  const _MetricBadge(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
      Text(value,
        style: const TextStyle(
          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
    ],
  );
}

// ── Feature Weight Legend ─────────────────────────────────────────────────────

class _FeatureWeightLegend extends StatelessWidget {
  final MlModelMetadata meta;

  // (label, heuristic weight, description)
  static const _features = [
    ('ZGL Level',        0.22, 'Spot distance above/below zero-gamma level'),
    ('ZGL Trend',        0.17, 'Momentum of ZGL distance over 5 observations'),
    ('SMA Cross',        0.17, 'SMA10 vs SMA50 — price trend alignment'),
    ('HMM State',        0.13, 'Hidden Markov vol regime + posterior probability'),
    ('IVP Trend',        0.08, 'IV percentile direction (rising = vol building)'),
    ('VIX Stress',       0.08, 'VIX deviation from 10-day MA'),
    ('Term Structure',   0.06, 'VIX/VIX3M ratio — backwardation signals stress'),
    ('ROC5',             0.06, '5-day price rate-of-change (momentum)'),
    ('Breadth',          0.05, 'RSP/SPY return z-score — market participation'),
    ('VT Distance',      0.04, 'Distance from Volatility Trigger level'),
    ('0DTE Pct',         0.04, '0DTE share of total GEX — intraday instability'),
  ];

  const _FeatureWeightLegend({required this.meta});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.cardColor,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Feature Importance',
              style: TextStyle(color: Colors.white70, fontSize: 12,
                  fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text(
              meta.available ? '(supervised model active)' : '(heuristic weights)',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ..._features.map((f) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              SizedBox(
                width: 100,
                child: Text(f.$1,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: f.$2 / 0.22,  // normalise to tallest bar
                    backgroundColor: AppTheme.elevatedColor,
                    color: AppTheme.profitColor.withValues(alpha: 0.7),
                    minHeight: 5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 32,
                child: Text(
                  '${(f.$2 * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(f.$3,
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 10),
                  overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        )),
      ],
    ),
  );
}

// ── Bucket Glossary ───────────────────────────────────────────────────────────

class _BucketGlossary extends StatelessWidget {
  const _BucketGlossary();

  static const _entries = [
    (
      RegimeBucket.stablePositive,
      'Positive Gamma (Stable)',
      'Dealers are long gamma — they buy dips and sell rips, actively dampening volatility. Spot is comfortably above the zero-gamma level.',
      'Optimal for: premium selling, directional long, theta strategies.',
    ),
    (
      RegimeBucket.trendingPositive,
      'Recovering → Positive',
      'Currently in negative gamma but ML signals are improving. Spot may be reclaiming the zero-gamma level. Transition not yet confirmed.',
      'Watch for: ZGL reclaim. Entry on confirmed breakout above flip level.',
    ),
    (
      RegimeBucket.trendingNegative,
      'Deteriorating → Negative',
      'Currently in positive gamma but momentum is weakening. Risk of dropping below the zero-gamma level is elevated. Structural support eroding.',
      'Action: Tighten stops. Reduce net-short premium. Prepare for amplification.',
    ),
    (
      RegimeBucket.stableNegative,
      'Negative Gamma (Stable)',
      'Dealers are short gamma — they must hedge by amplifying price moves, not dampening them. Both up and down moves are magnified.',
      'Avoid: naked premium. Use only: long straddles, defined-risk spreads, or directional with tight stops.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Column(
    children: _entries.map((e) {
      final color = _bucketColor(e.$1);
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 12, height: 12,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.$2,
                    style: TextStyle(
                      color: color, fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(e.$3,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(e.$4,
                    style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11,
                      fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          ],
        ),
      );
    }).toList(),
  );
}

// ── Ticker Matrix ─────────────────────────────────────────────────────────────

class _TickerMatrix extends StatelessWidget {
  final RegimeMlAnalysis analysis;
  const _TickerMatrix({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final columns = [
      (RegimeBucket.stablePositive,   analysis.stablePositive),
      (RegimeBucket.trendingPositive, analysis.trendingPositive),
      (RegimeBucket.trendingNegative, analysis.trendingNegative),
      (RegimeBucket.stableNegative,   analysis.stableNegative),
    ];
    return Column(
      children: columns.map((col) {
        if (col.$2.isEmpty) return const SizedBox.shrink();
        return _BucketSection(bucket: col.$1, tickers: col.$2);
      }).toList(),
    );
  }
}

class _BucketSection extends StatelessWidget {
  final RegimeBucket           bucket;
  final List<TickerRegimeResult> tickers;
  const _BucketSection({required this.bucket, required this.tickers});

  @override
  Widget build(BuildContext context) {
    final color = _bucketColor(bucket);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(bucket.label,
                  style: TextStyle(
                    color: color, fontSize: 14, fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color:        color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${tickers.length}',
                    style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          // Ticker cards
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tickers.map((t) => _TickerCard(result: t)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Ticker Card ───────────────────────────────────────────────────────────────

class _TickerCard extends StatelessWidget {
  final TickerRegimeResult result;
  const _TickerCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final color      = _bucketColor(result.bucket);
    final biasColor  = _biasColor(result.strategyBias);
    final f          = result.features;
    final hasBackw   = f.isBackwardation;
    final has0dte    = f.has0DteDominance;
    final hasBreadth = f.hasBreadthDivergence && (f.breadthProxy ?? 0) < 0;

    return GestureDetector(
      onTap: () => _showTickerDetail(context, result),
      child: Container(
        constraints: const BoxConstraints(minWidth: 110, maxWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: ticker + score
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(result.ticker,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(width: 5),
                Text(_score(result.mlScore),
                  style: TextStyle(
                    color: result.mlScore >= 0
                        ? AppTheme.profitColor : AppTheme.lossColor,
                    fontSize: 11, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            // Row 2: strategy bias badge + risk dots
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Pill(_biasShortLabel(result.strategyBias), biasColor,
                    fontSize: 9, padH: 5, padV: 2),
                const SizedBox(width: 4),
                if (hasBackw)
                  _RiskDot('B', const Color(0xFFFB923C)),
                if (has0dte)
                  _RiskDot('0', const Color(0xFFFBBF24)),
                if (hasBreadth)
                  _RiskDot('↓', AppTheme.lossColor),
              ],
            ),
            const SizedBox(height: 4),
            // Confidence bar
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value:           result.confidence.clamp(0.0, 1.0),
                backgroundColor: AppTheme.cardColor,
                color:           color.withValues(alpha: 0.8),
                minHeight:       3,
              ),
            ),
            const SizedBox(height: 3),
            // Row 3: flip prob + scoring method
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'flip ${(result.transitionProb * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
                const SizedBox(width: 5),
                _ScoringBadge(result.scoringMethod),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskDot extends StatelessWidget {
  final String label;
  final Color  color;
  const _RiskDot(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 2),
    width: 14, height: 14,
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(3),
      border:       Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Center(
      child: Text(label,
        style: TextStyle(color: color, fontSize: 7, fontWeight: FontWeight.w800)),
    ),
  );
}

// ── Scoring Badge ─────────────────────────────────────────────────────────────

class _ScoringBadge extends StatelessWidget {
  final String method;
  const _ScoringBadge(this.method);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (method) {
      String s when s.contains('xgb')      => ('XGB', const Color(0xFF60A5FA)),
      String s when s.contains('logistic') => ('LR',  const Color(0xFF818CF8)),
      _                                    => ('H',   Colors.white24),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label,
        style: TextStyle(
          color: color, fontSize: 8, fontWeight: FontWeight.w700)),
    );
  }
}

// ── Shared pill widget ────────────────────────────────────────────────────────

class _Pill extends StatelessWidget {
  final String label;
  final Color  color;
  final double fontSize;
  final double padH, padV;

  const _Pill(this.label, this.color,
      {this.fontSize = 11, this.padH = 8, this.padV = 3});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label,
      style: TextStyle(
        color: color, fontSize: fontSize, fontWeight: FontWeight.w700)),
  );
}

// ── Detail bottom sheet ───────────────────────────────────────────────────────

void _showTickerDetail(BuildContext context, TickerRegimeResult result) {
  showModalBottomSheet(
    context:         context,
    backgroundColor: AppTheme.elevatedColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize:     0.5,
      maxChildSize:     0.95,
      expand:           false,
      builder: (_, scrollCtrl) => _TickerDetailSheet(
        result:     result,
        scrollCtrl: scrollCtrl,
      ),
    ),
  );
}

class _TickerDetailSheet extends StatelessWidget {
  final TickerRegimeResult result;
  final ScrollController   scrollCtrl;

  const _TickerDetailSheet({required this.result, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    final color = _bucketColor(result.bucket);
    final f     = result.features;

    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
      children: [
        // Handle
        Center(
          child: Container(
            width: 36, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color:        Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // ── Header ────────────────────────────────────────────────────────
        Row(
          children: [
            Text(result.ticker,
              style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            _Pill(result.bucket.label, color),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                context.go('/ticker/${result.ticker}');
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('Full Detail', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.neutralColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _Pill(_biasShortLabel(result.strategyBias),
                _biasColor(result.strategyBias), fontSize: 10),
            const SizedBox(width: 8),
            Text(
              'Score ${_score(result.mlScore)}  '
              'Flip ${(result.transitionProb * 100).toStringAsFixed(0)}%  '
              'Conf ${(result.confidence * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Interpretation ─────────────────────────────────────────────────
        _InterpretationCard(result: result),
        const SizedBox(height: 12),

        // ── Risk Flags ─────────────────────────────────────────────────────
        _RiskFlagsRow(features: f),
        const SizedBox(height: 12),

        // ── All Signals ────────────────────────────────────────────────────
        _SignalsList(signals: result.signals),
        const SizedBox(height: 12),

        // ── Feature Snapshot ───────────────────────────────────────────────
        _FeatureSnapshot(features: f),
      ],
    );
  }
}

// ── Interpretation Card ───────────────────────────────────────────────────────

class _InterpretationCard extends StatelessWidget {
  final TickerRegimeResult result;
  const _InterpretationCard({required this.result});

  static String _bucketNarrative(RegimeBucket b) => switch (b) {
    RegimeBucket.stablePositive =>
      'Dealers are long gamma — they hedge by buying dips and selling rips, '
      'actively dampening volatility. Spot is comfortably above the zero-gamma '
      'level (ZGL). ML confirms regime stability.',
    RegimeBucket.trendingPositive =>
      'Currently in negative gamma, but ML signals are improving toward a '
      'positive flip. Spot may be reclaiming the ZGL. The transition is not '
      'yet structurally confirmed — treat as early recovery.',
    RegimeBucket.trendingNegative =>
      'Currently in positive gamma, but momentum is weakening. Risk of '
      'crossing below the ZGL is elevated. Structural support is eroding — '
      'ML registers increasing flip probability.',
    RegimeBucket.stableNegative =>
      'Dealers are short gamma — they must amplify price moves to stay hedged. '
      'Both up and down moves get magnified. Spot is below the ZGL. '
      'Volatility expansion is the structural expectation.',
    RegimeBucket.unknown =>
      'Insufficient historical data to classify this ticker\'s regime. '
      'Signals are unreliable — do not trade on this output.',
  };

  static String _biasNarrative(String bias) => switch (bias) {
    'directional_bullish' =>
      'Strategy: Long calls or call spreads (delta 0.30–0.50). '
      'Enter on SMA10 pullbacks. Stop-loss below SMA50.',
    'directional_bearish' =>
      'Strategy: Long puts or put spreads. Sell into rips. '
      'Stop-loss above recent resistance.',
    'straddle_only' =>
      'Strategy: Buy volatility — long straddle or strangle near ATM. '
      'Neither directional side is structurally safer; profit from the move itself.',
    'premium_sell' =>
      'Strategy: Sell premium — iron condors, credit spreads, or short iron '
      'butterfly. Collect theta. Exit at 50% of max profit.',
    _ =>
      'No high-conviction structural edge. Hold flat or reduce size. '
      'Wait for ZGL or SMA alignment before initiating new positions.',
  };

  @override
  Widget build(BuildContext context) {
    final color      = _bucketColor(result.bucket);
    final biasColor  = _biasColor(result.strategyBias);
    final narrative  = _bucketNarrative(result.bucket);
    final guidance   = _biasNarrative(result.strategyBias);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('What\'s Happening',
                style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(narrative,
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
          const Divider(color: Colors.white12, height: 20),
          Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(color: biasColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('What to Trade',
                style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(guidance,
            style: TextStyle(
              color: biasColor.withValues(alpha: 0.9), fontSize: 13, height: 1.5)),
        ],
      ),
    );
  }
}

// ── Risk Flags Row ────────────────────────────────────────────────────────────

class _RiskFlagsRow extends StatelessWidget {
  final RegimeMlFeatures features;
  const _RiskFlagsRow({required this.features});

  @override
  Widget build(BuildContext context) {
    final f = features;
    final tsRatio = f.vixTermStructureRatio;
    final dte     = f.gex0DtePct;
    final breadth = f.breadthProxy;
    final vt      = f.spotToVtPct;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Risk Environment',
            style: TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FlagChip(
                label:   'Term Structure',
                value:   tsRatio != null ? tsRatio.toStringAsFixed(3) : '—',
                active:  f.isBackwardation,
                color:   f.isBackwardation
                    ? const Color(0xFFFB923C) : AppTheme.neutralColor,
                tooltip: f.isBackwardation
                    ? 'Backwardation: near-term stress priced above long-term. Premium selling window is narrowed.'
                    : 'Contango: market pricing is calm. Normal premium-selling environment.',
              ),
              _FlagChip(
                label:   '0DTE Share',
                value:   dte != null ? '${dte.toStringAsFixed(0)}%' : '—',
                active:  f.has0DteDominance,
                color:   f.has0DteDominance
                    ? const Color(0xFFFBBF24) : AppTheme.neutralColor,
                tooltip: f.has0DteDominance
                    ? '0DTE options dominate GEX (≥50%). Gamma exposure resets at close — structural support is intraday only.'
                    : '0DTE share is within normal range. Structural gamma carries into tomorrow.',
              ),
              _FlagChip(
                label:   'Breadth',
                value:   breadth != null
                    ? 'z ${_signed(breadth, decimals: 1)}' : '—',
                active:  f.hasBreadthDivergence,
                color:   breadth != null && breadth < -1.5
                    ? AppTheme.lossColor
                    : breadth != null && breadth > 1.5
                      ? AppTheme.profitColor
                      : AppTheme.neutralColor,
                tooltip: f.hasBreadthDivergence
                    ? (breadth! < 0
                        ? 'RSP underperforming SPY — narrow rally, elevated mean-reversion risk.'
                        : 'RSP outperforming SPY — broad participation, structurally supportive.')
                    : 'Breadth is neutral. Market participation is balanced.',
              ),
              _FlagChip(
                label:   'VT Corridor',
                value:   vt != null ? _pct(vt) : '—',
                active:  vt != null && vt > 0 && (f.spotToZglPct ?? 1) < 0,
                color:   (vt != null && vt > 0 && (f.spotToZglPct ?? 1) < 0)
                    ? const Color(0xFFFCA5A5) : AppTheme.neutralColor,
                tooltip: (vt != null && vt > 0 && (f.spotToZglPct ?? 1) < 0)
                    ? 'In VT–ZGL transition corridor: below zero-gamma but above Volatility Trigger. Dealer hedging asymmetric — bearish bias elevated.'
                    : 'Outside the VT–ZGL corridor. Normal gamma structure applies.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final String label, value, tooltip;
  final bool   active;
  final Color  color;

  const _FlagChip({
    required this.label,
    required this.value,
    required this.active,
    required this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    triggerMode: TooltipTriggerMode.tap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: 0.12)
            : AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.5) : Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
            style: TextStyle(
              color: active ? color : Colors.white38, fontSize: 10)),
          const SizedBox(height: 2),
          Text(value,
            style: TextStyle(
              color: active ? color : Colors.white54,
              fontSize: 13, fontWeight: FontWeight.w700)),
          if (active)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, color: color, size: 10),
                  const SizedBox(width: 2),
                  Text('Active · tap for info',
                    style: TextStyle(color: color, fontSize: 9)),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

// ── Signals List ──────────────────────────────────────────────────────────────

enum _SignalCategory { risk, regime, ml, gamma, technical }

_SignalCategory _categorizeSignal(String s) {
  if (s.startsWith('VVIX') || s.startsWith('0DTE') ||
      s.startsWith('Scope guard') ||
      s.startsWith('Breadth divergence') ||
      s.startsWith('Breadth confirmation')) {
    return _SignalCategory.risk;
  }
  if (s.startsWith('HMM') || s.startsWith('VIX') ||
      s.startsWith('Risk-off') || s.startsWith('Risk-on')) {
    return _SignalCategory.regime;
  }
  if (s.startsWith('ML [') || s.startsWith('ZGL distance') ||
      s.startsWith('IVP') || s.startsWith('Regime tenure')) {
    return _SignalCategory.ml;
  }
  if (s.startsWith('IV-GEX')) {
    return _SignalCategory.gamma;
  }
  return _SignalCategory.technical;
}

class _SignalsList extends StatefulWidget {
  final List<String> signals;
  const _SignalsList({required this.signals});

  @override
  State<_SignalsList> createState() => _SignalsListState();
}

class _SignalsListState extends State<_SignalsList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.signals.isEmpty) return const SizedBox.shrink();

    final categorized = <_SignalCategory, List<String>>{};
    for (final s in widget.signals) {
      categorized.putIfAbsent(_categorizeSignal(s), () => []).add(s);
    }

    final order = [
      _SignalCategory.risk,
      _SignalCategory.regime,
      _SignalCategory.gamma,
      _SignalCategory.ml,
      _SignalCategory.technical,
    ];

    final preview = widget.signals.take(3).toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Signal Breakdown',
                style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${widget.signals.length} signals',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),

          if (!_expanded) ...[
            ...preview.map((s) => _SignalRow(signal: s)),
            if (widget.signals.length > 3) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => setState(() => _expanded = true),
                child: Row(
                  children: [
                    Text(
                      'Show all ${widget.signals.length} signals',
                      style: TextStyle(
                        color: AppTheme.neutralColor,
                        fontSize: 12, decoration: TextDecoration.underline),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more_rounded,
                        color: AppTheme.neutralColor, size: 16),
                  ],
                ),
              ),
            ],
          ] else ...[
            ...order.expand((cat) {
              final sigs = categorized[cat];
              if (sigs == null || sigs.isEmpty) return <Widget>[];
              final (catLabel, catColor) = _categoryMeta(cat);
              return [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(catLabel,
                    style: TextStyle(
                      color: catColor, fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
                ),
                ...sigs.map((s) => _SignalRow(signal: s)),
              ];
            }),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => setState(() => _expanded = false),
              child: Row(
                children: [
                  Text('Collapse',
                    style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12,
                      decoration: TextDecoration.underline)),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_less_rounded,
                      color: AppTheme.neutralColor, size: 16),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  (String, Color) _categoryMeta(_SignalCategory cat) => switch (cat) {
    _SignalCategory.risk      => ('RISK FLAGS',  const Color(0xFFFB923C)),
    _SignalCategory.regime    => ('VOL REGIME',  const Color(0xFF60A5FA)),
    _SignalCategory.ml        => ('ML ANALYSIS', const Color(0xFF818CF8)),
    _SignalCategory.gamma     => ('GAMMA SIGNAL', const Color(0xFF4ADE80)),
    _SignalCategory.technical => ('TECHNICAL',   Colors.white54),
  };
}

class _SignalRow extends StatelessWidget {
  final String signal;
  const _SignalRow({required this.signal});

  @override
  Widget build(BuildContext context) {
    final cat = _categorizeSignal(signal);
    final (_, color) = switch (cat) {
      _SignalCategory.risk      => ('', const Color(0xFFFB923C)),
      _SignalCategory.regime    => ('', const Color(0xFF60A5FA)),
      _SignalCategory.ml        => ('', const Color(0xFF818CF8)),
      _SignalCategory.gamma     => ('', const Color(0xFF4ADE80)),
      _SignalCategory.technical => ('', Colors.white38),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 5, height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(signal,
              style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

// ── Feature Snapshot ──────────────────────────────────────────────────────────

class _FeatureSnapshot extends StatelessWidget {
  final RegimeMlFeatures features;
  const _FeatureSnapshot({required this.features});

  @override
  Widget build(BuildContext context) {
    final f = features;

    final rows = <(String, String, String, Color?)>[
      // (label, value, interpretation, color hint)
      (
        'ZGL Distance',
        _pct(f.spotToZglPct),
        f.spotToZglPct == null ? '—'
            : f.spotToZglPct! > 0 ? 'Above ZGL — positive gamma zone'
            : 'Below ZGL — negative gamma zone',
        f.spotToZglPct == null ? null
            : f.spotToZglPct! > 0 ? AppTheme.profitColor : AppTheme.lossColor,
      ),
      (
        'ZGL Trend',
        _signed(f.spotToZglTrend, suffix: '/obs'),
        f.spotToZglTrend == null ? '—'
            : f.spotToZglTrend! > 0 ? 'Rising — moving away from flip'
            : 'Falling — approaching flip',
        f.spotToZglTrend == null ? null
            : f.spotToZglTrend! > 0 ? AppTheme.profitColor : AppTheme.lossColor,
      ),
      (
        'IVP',
        _pct(f.ivp),
        f.ivp == null ? '—'
            : f.ivp! > 70 ? 'Elevated — vol is expensive; put premiums rich'
            : f.ivp! < 25 ? 'Compressed — vol cheap; spike risk higher'
            : 'Normal range',
        f.ivp == null ? null
            : f.ivp! > 70 ? AppTheme.lossColor
            : f.ivp! < 25 ? const Color(0xFFFBBF24)
            : null,
      ),
      (
        'IVP Trend',
        _signed(f.ivpTrend, suffix: '/obs'),
        f.ivpTrend == null ? '—'
            : f.ivpTrend! > 0 ? 'Rising — vol building; straddle bias'
            : 'Falling — vol deflating; premium-sell bias',
        null,
      ),
      (
        'HMM State',
        f.hmmState ?? '—',
        f.hmmState == 'high_vol'
            ? 'Risk-off: ${f.hmmProbability != null ? '${(f.hmmProbability! * 100).toStringAsFixed(0)}% confidence' : ''}'
            : f.hmmState == 'low_vol'
              ? 'Risk-on: ${f.hmmProbability != null ? '${(f.hmmProbability! * 100).toStringAsFixed(0)}% confidence' : ''}'
              : '—',
        f.hmmState == 'high_vol' ? AppTheme.lossColor
            : f.hmmState == 'low_vol' ? AppTheme.profitColor : null,
      ),
      (
        'SMA Aligned',
        f.smaAligned == null ? '—'
            : f.smaAligned! ? 'Yes — SMA10 > SMA50' : 'No — SMA10 < SMA50',
        f.smaAligned == null ? '—'
            : f.smaAligned! ? 'Bullish medium-term trend'
            : 'Bearish medium-term trend',
        f.smaAligned == null ? null
            : f.smaAligned! ? AppTheme.profitColor : AppTheme.lossColor,
      ),
      (
        'VIX Dev',
        _pct(f.vixDevPct),
        f.vixDevPct == null ? '—'
            : f.vixDevPct! > 10 ? 'VIX spiking — vol expanding rapidly'
            : f.vixDevPct! < -5 ? 'VIX compressed — spike risk elevated'
            : 'VIX near 10-day average',
        null,
      ),
      (
        'Term Structure',
        f.vixTermStructureRatio != null
            ? f.vixTermStructureRatio!.toStringAsFixed(3) : '—',
        f.isBackwardation
            ? 'Backwardation — near-term stress premium'
            : 'Contango — calm near-term structure',
        f.isBackwardation ? const Color(0xFFFB923C) : AppTheme.profitColor,
      ),
      (
        'VT Distance',
        _pct(f.spotToVtPct),
        f.spotToVtPct == null ? '—'
            : f.spotToVtPct! > 0 ? 'Above Volatility Trigger — structural support'
            : 'Below VT — elevated vol hedging triggered',
        null,
      ),
      (
        'Breadth',
        f.breadthProxy != null
            ? 'z ${_signed(f.breadthProxy, decimals: 1)}' : '—',
        f.breadthProxy == null ? '—'
            : f.breadthProxy! < -1.5 ? 'Narrow rally — breadth diverging'
            : f.breadthProxy! > 1.5 ? 'Broad participation — confirmed'
            : 'Normal breadth',
        null,
      ),
      (
        '0DTE Share',
        _pct(f.gex0DtePct),
        f.gex0DtePct == null ? '—'
            : f.gex0DtePct! > 50 ? 'Dominant — gamma resets at close'
            : f.gex0DtePct! > 30 ? 'Elevated — watch intraday reversals'
            : 'Normal',
        f.has0DteDominance ? const Color(0xFFFBBF24) : null,
      ),
      (
        'Price ROC5',
        _pct(f.priceRoc5),
        f.priceRoc5 == null ? '—'
            : f.priceRoc5! > 1.0 ? 'Bullish momentum — +1% 5-day'
            : f.priceRoc5! < -1.0 ? 'Bearish momentum — −1% 5-day'
            : 'Flat momentum',
        f.priceRoc5 == null ? null
            : f.priceRoc5! > 1 ? AppTheme.profitColor
            : f.priceRoc5! < -1 ? AppTheme.lossColor : null,
      ),
      (
        'Regime Duration',
        '${features.regimeDurationDays} days',
        features.regimeDurationDays >= 15
            ? 'Extended — mean-reversion pressure building'
            : 'Recent — regime is young',
        features.regimeDurationDays >= 15
            ? const Color(0xFFFBBF24) : null,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Feature Snapshot',
            style: TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...rows.map((r) => _FeatureRow(
            label:          r.$1,
            value:          r.$2,
            interpretation: r.$3,
            valueColor:     r.$4,
          )),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String  label, value, interpretation;
  final Color?  valueColor;

  const _FeatureRow({
    required this.label,
    required this.value,
    required this.interpretation,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ),
        SizedBox(
          width: 80,
          child: Text(value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(interpretation,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
            overflow: TextOverflow.ellipsis, maxLines: 2),
        ),
      ],
    ),
  );
}

// ── Error body ────────────────────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  final String error;
  const _ErrorBody({required this.error});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppTheme.lossColor, size: 40),
          const SizedBox(height: 12),
          const Text('Failed to load regime data',
            style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(error,
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            textAlign: TextAlign.center),
          const SizedBox(height: 16),
          const Text('Ensure the Python API is running and reachable.',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    ),
  );
}
