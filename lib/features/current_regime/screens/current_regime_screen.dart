// =============================================================================
// features/current_regime/screens/current_regime_screen.dart
// =============================================================================
// Current Regime — ML-enhanced market & individual stock regime dashboard.
//
// Layout:
//   1. Market Context strip  — VIX state, SPY gamma regime, macro score badge
//   2. ML Intelligence panel — feature breakdown, confidence, regime duration
//   3. Ticker Regime Matrix  — 4 columns: +GEX, →+GEX, →−GEX, −GEX
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

// ── Helpers ───────────────────────────────────────────────────────────────────

Color _bucketColor(RegimeBucket b) => switch (b) {
  RegimeBucket.stablePositive => const Color(0xFF4ADE80),
  RegimeBucket.trendingPositive => const Color(0xFF86EFAC),
  RegimeBucket.trendingNegative => const Color(0xFFFCA5A5),
  RegimeBucket.stableNegative => const Color(0xFFFF6B8A),
  RegimeBucket.unknown => Colors.white38,
};

Color _regimeColor(String regime) => switch (regime) {
  'positive' => AppTheme.profitColor,
  'negative' => AppTheme.lossColor,
  _ => AppTheme.neutralColor,
};

String _pct(double? v, {int decimals = 1}) =>
    v == null ? '—' : '${v.toStringAsFixed(decimals)}%';

String _score(double v) =>
    v >= 0 ? '+${v.toStringAsFixed(2)}' : v.toStringAsFixed(2);

// ── Root screen ───────────────────────────────────────────────────────────────

class CurrentRegimeScreen extends ConsumerWidget {
  const CurrentRegimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mlAsync = ref.watch(regimeMlProvider);
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
        error: (e, _) => _ErrorBody(error: e.toString()),
        data: (analysis) => _Body(analysis: analysis, macroAsync: macroAsync),
      ),
    );
  }
}

// ── Body ──────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final RegimeMlAnalysis analysis;
  final AsyncValue<MacroScore> macroAsync;

  const _Body({required this.analysis, required this.macroAsync});

  @override
  Widget build(BuildContext context) {
    final spyRegime = analysis.marketContext.spyRegime;
    final spyGamma = spyRegime?['gamma_regime'] as String? ?? 'unknown';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── 1. Market Context ──────────────────────────────────────────────
        _SectionHeader('Market Context'),
        const SizedBox(height: 8),
        _MarketContextStrip(
          analysis: analysis,
          macroAsync: macroAsync,
          spyGamma: spyGamma,
        ),

        const SizedBox(height: 20),

        // ── 2. ML Intelligence ─────────────────────────────────────────────
        _SectionHeader('ML Intelligence'),
        const SizedBox(height: 4),
        Text(
          'Scoring uses 9 feature dimensions derived from rolling regime history. '
          'Each ticker is scored −1 (strongly negative gamma) to +1 (strongly positive gamma).',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
        ),
        const SizedBox(height: 10),
        _ModelInfoCard(meta: analysis.modelMetadata),
        const SizedBox(height: 10),
        _FeatureWeightLegend(meta: analysis.modelMetadata),

        const SizedBox(height: 20),

        // ── 3. Ticker Regime Matrix ────────────────────────────────────────
        _SectionHeader('Ticker Regime Matrix'),
        const SizedBox(height: 4),
        Text(
          'Tickers classified by current gamma regime and ML transition score.',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _TickerMatrix(analysis: analysis),

        // ── Last updated ───────────────────────────────────────────────────
        const SizedBox(height: 20),
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
  final RegimeMlAnalysis analysis;
  final AsyncValue<MacroScore> macroAsync;
  final String spyGamma;

  const _MarketContextStrip({
    required this.analysis,
    required this.macroAsync,
    required this.spyGamma,
  });

  @override
  Widget build(BuildContext context) {
    final ctx = analysis.marketContext;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        // Macro score
        macroAsync.when(
          loading: () => _ContextChip(
            label: 'Macro',
            value: '…',
            color: AppTheme.neutralColor,
          ),
          error: (e, st) => _ContextChip(
            label: 'Macro',
            value: 'Error',
            color: AppTheme.lossColor,
            subtitle: e.toString().length > 50
                ? e.toString().substring(0, 50)
                : e.toString(),
          ),
          data: (macro) => _ContextChip(
            label: 'Macro',
            value: '${macro.total.toStringAsFixed(0)} ${macro.regime.label}',
            color: _macroColor(macro.regime),
            subtitle: macro.regime.description.length > 40
                ? macro.regime.description.substring(0, 40)
                : macro.regime.description,
          ),
        ),

        // VIX state
        _ContextChip(
          label: 'VIX Regime',
          value: ctx.vixState == 'high_vol'
              ? 'High Vol'
              : ctx.vixState == 'low_vol'
              ? 'Low Vol'
              : '—',
          color: ctx.vixState == 'high_vol'
              ? AppTheme.lossColor
              : AppTheme.profitColor,
          subtitle: ctx.vixCurrent != null
              ? 'VIX ${ctx.vixCurrent!.toStringAsFixed(1)}'
                    '  Dev ${_pct(ctx.vixDevPct, decimals: 1)}'
                    '  RSI ${ctx.vixRsi?.toStringAsFixed(0) ?? '—'}'
                    '  Conf ${ctx.vixHmmProb != null ? '${(ctx.vixHmmProb! * 100).toStringAsFixed(0)}%' : '—'}'
              : null,
        ),

        // SPY gamma regime
        _ContextChip(
          label: 'SPY Gamma',
          value: spyGamma == 'positive'
              ? 'Positive'
              : spyGamma == 'negative'
              ? 'Negative'
              : 'Unknown',
          color: _regimeColor(spyGamma),
          subtitle: analysis.marketContext.spyRegime != null
              ? 'ZGL: ${_pct((analysis.marketContext.spyRegime!['spot_to_zgl_pct'] as num?)?.toDouble())}'
              : null,
        ),

        // Ticker count summary
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
    MacroRegime.riskOn => AppTheme.profitColor,
    MacroRegime.neutralBullish => const Color(0xFF86EFAC),
    MacroRegime.neutral => const Color(0xFFFBBF24),
    MacroRegime.caution => const Color(0xFFFCA5A5),
    MacroRegime.crisis => AppTheme.lossColor,
  };
}

class _ContextChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
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
    constraints: const BoxConstraints(minWidth: 120),
    decoration: BoxDecoration(
      color: AppTheme.cardColor,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
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
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: Colors.white38,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No trained model — using heuristic scoring. '
                'Call POST /regime/train to fit a supervised model.',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    final trainedAt = meta.trainedAt != null
        ? DateTime.tryParse(meta.trainedAt!)
        : null;
    final typeLabel = switch (meta.modelType) {
      'xgboost' => 'XGBoost',
      'logistic' => 'Logistic Regression',
      _ => meta.modelType ?? 'Unknown',
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.profitColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  typeLabel,
                  style: TextStyle(
                    color: AppTheme.profitColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
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
              _MetricBadge('AUC-ROC', meta.aucRoc.toStringAsFixed(3)),
              const SizedBox(width: 12),
              _MetricBadge(
                'Accuracy',
                '${(meta.accuracy * 100).toStringAsFixed(1)}%',
              ),
              const SizedBox(width: 12),
              _MetricBadge(
                'Precision',
                '${(meta.precision * 100).toStringAsFixed(1)}%',
              ),
              const SizedBox(width: 12),
              _MetricBadge(
                'Recall',
                '${(meta.recall * 100).toStringAsFixed(1)}%',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${meta.nSamples} samples · ${meta.nPositive} flip events '
            '(${meta.nSamples > 0 ? (meta.nPositive / meta.nSamples * 100).toStringAsFixed(1) : "—"}% base rate)',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MetricBadge extends StatelessWidget {
  final String label;
  final String value;
  const _MetricBadge(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

// ── Feature Weight Legend ─────────────────────────────────────────────────────

class _FeatureWeightLegend extends StatelessWidget {
  final MlModelMetadata meta;
  static const _features = [
    ('ZGL Level', 0.25, 'Distance above/below zero-gamma level'),
    ('ZGL Trend', 0.20, 'Momentum of ZGL distance over 5 obs'),
    ('SMA Cross', 0.20, 'SMA10 vs SMA50 alignment'),
    ('HMM State', 0.15, 'Hidden Markov vol regime + probability'),
    ('IVP Trend', 0.10, 'IV percentile direction (rising = bearish)'),
    ('VIX Stress', 0.10, 'VIX deviation from 10-day MA'),
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
            Text(
              'Feature Importance',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              meta.available
                  ? '(6 heuristic features shown)'
                  : '(hand-tuned weights)',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ..._features.map(
          (f) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    f.$1,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: f.$2,
                      backgroundColor: AppTheme.elevatedColor,
                      color: AppTheme.profitColor.withValues(alpha: 0.7),
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(f.$2 * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    f.$3,
                    style: TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Ticker Matrix ─────────────────────────────────────────────────────────────

class _TickerMatrix extends StatelessWidget {
  final RegimeMlAnalysis analysis;

  const _TickerMatrix({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final columns = [
      (RegimeBucket.stablePositive, analysis.stablePositive),
      (RegimeBucket.trendingPositive, analysis.trendingPositive),
      (RegimeBucket.trendingNegative, analysis.trendingNegative),
      (RegimeBucket.stableNegative, analysis.stableNegative),
    ];

    return Column(
      children: columns.map((col) {
        final bucket = col.$1;
        final tickers = col.$2;
        if (tickers.isEmpty) return const SizedBox.shrink();
        return _BucketSection(bucket: bucket, tickers: tickers);
      }).toList(),
    );
  }
}

class _BucketSection extends StatelessWidget {
  final RegimeBucket bucket;
  final List<TickerRegimeResult> tickers;

  const _BucketSection({required this.bucket, required this.tickers});

  @override
  Widget build(BuildContext context) {
    final color = _bucketColor(bucket);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  bucket.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${tickers.length}',
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Ticker chips
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tickers.map((t) => _TickerChip(result: t)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TickerChip extends StatelessWidget {
  final TickerRegimeResult result;

  const _TickerChip({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = _bucketColor(result.bucket);

    return GestureDetector(
      onTap: () => context.go('/ticker/${result.ticker}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Ticker + score
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.ticker,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _score(result.mlScore),
                  style: TextStyle(
                    color: result.mlScore >= 0
                        ? AppTheme.profitColor
                        : AppTheme.lossColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            // Confidence bar
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: result.confidence.clamp(0.0, 1.0),
                  backgroundColor: AppTheme.cardColor,
                  color: color.withValues(alpha: 0.8),
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(height: 2),
            // Transition prob + scoring method
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'flip ${(result.transitionProb * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 10),
                ),
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

// ── Scoring method badge ──────────────────────────────────────────────────────

class _ScoringBadge extends StatelessWidget {
  final String method;
  const _ScoringBadge(this.method);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (method) {
      String s when s.startsWith('supervised_xgb') => (
        'XGB',
        const Color(0xFF60A5FA),
      ),
      String s when s.startsWith('supervised_lr') => (
        'LR',
        const Color(0xFF818CF8),
      ),
      _ => ('H', Colors.white24),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ── Detail bottom sheet ───────────────────────────────────────────────────────

// ignore: unused_element
void _showTickerDetail(BuildContext context, TickerRegimeResult result) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.elevatedColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _TickerDetailSheet(result: result),
  );
}

class _TickerDetailSheet extends StatelessWidget {
  final TickerRegimeResult result;

  const _TickerDetailSheet({required this.result});

  @override
  Widget build(BuildContext context) {
    final f = result.features;
    final color = _bucketColor(result.bucket);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title
          Row(
            children: [
              Text(
                result.ticker,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  result.bucket.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ML score + confidence
          _DetailRow('ML Score', _score(result.mlScore)),
          _DetailRow(
            'Transition Risk',
            '${(result.transitionProb * 100).toStringAsFixed(0)}%',
          ),
          _DetailRow(
            'Confidence',
            '${(result.confidence * 100).toStringAsFixed(0)}%',
          ),
          _DetailRow('Regime Duration', '${f.regimeDurationDays} days'),
          const Divider(color: Colors.white12, height: 20),
          _DetailRow('ZGL Distance', _pct(f.spotToZglPct)),
          _DetailRow(
            'ZGL Trend',
            f.spotToZglTrend != null
                ? '${f.spotToZglTrend! >= 0 ? '+' : ''}${f.spotToZglTrend!.toStringAsFixed(2)}%/obs'
                : '—',
          ),
          _DetailRow('IVP', _pct(f.ivp)),
          _DetailRow(
            'IVP Trend',
            f.ivpTrend != null
                ? '${f.ivpTrend! >= 0 ? '+' : ''}${f.ivpTrend!.toStringAsFixed(2)}/obs'
                : '—',
          ),
          _DetailRow('HMM State', f.hmmState ?? '—'),
          _DetailRow(
            'HMM Probability',
            _pct(f.hmmProbability != null ? f.hmmProbability! * 100 : null),
          ),
          _DetailRow(
            'SMA Aligned',
            f.smaAligned == null
                ? '—'
                : f.smaAligned
                ? 'Yes (bullish)'
                : 'No (bearish)',
          ),
          _DetailRow('VIX Dev', _pct(f.vixDevPct)),
          const Divider(color: Colors.white12, height: 20),
          const Text(
            'ML Signals',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (result.signals.where((s) => s.startsWith('ML:')).isEmpty)
            Text(
              'No ML signals',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            ...result.signals
                .where((s) => s.startsWith('ML:'))
                .map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $s',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
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
          const Icon(
            Icons.error_outline_rounded,
            color: AppTheme.lossColor,
            size: 40,
          ),
          const SizedBox(height: 12),
          const Text(
            'Failed to load regime data',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text(
            'Ensure the Python API is running and reachable.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
