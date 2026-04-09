// =============================================================================
// features/options/widgets/option_score_sheet.dart
// Bottom sheet — score breakdown + greeks + IV analytics + "Log Trade" prefill
// =============================================================================
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_analytics_service.dart';
import '../../../services/iv/iv_models.dart';
import '../../../services/iv/iv_providers.dart';
import '../../../services/schwab/schwab_models.dart';
import '../services/option_scoring_engine.dart';

class OptionScoreSheet extends ConsumerWidget {
  final SchwabOptionContract contract;
  final double underlyingPrice;
  final String symbol;
  const OptionScoreSheet({
    super.key,
    required this.contract,
    required this.underlyingPrice,
    required this.symbol,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final score   = OptionScoringEngine.score(contract, underlyingPrice);
    final isCall  = contract.symbol.contains('C');
    final color   = isCall ? AppTheme.profitColor : AppTheme.lossColor;
    final ivAsync = ref.watch(ivAnalysisProvider(symbol));
    final greeks  = IvAnalyticsService.contractGreeks(contract, underlyingPrice);

    return DraggableScrollableSheet(
      initialChildSize: 0.90,
      minChildSize:     0.5,
      maxChildSize:     0.97,
      expand:           false,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color:        AppTheme.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header — contract identity
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$symbol  \$${contract.strikePrice.toStringAsFixed(0)}  ${isCall ? 'CALL' : 'PUT'}',
                        style: TextStyle(
                          color:      color,
                          fontSize:   22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Contract identity chips
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _tag('EXP ${contract.expirationDate}', AppTheme.neutralColor),
                          _tag('${contract.daysToExpiration}d DTE',
                              contract.daysToExpiration <= 7
                                  ? AppTheme.lossColor
                                  : AppTheme.neutralColor),
                          _tag('IV ${contract.impliedVolatility.toStringAsFixed(1)}%',
                              AppTheme.neutralColor),
                          _tag(contract.inTheMoney ? 'ITM' : 'OTM',
                              contract.inTheMoney ? color : AppTheme.neutralColor),
                        ],
                      ),
                    ],
                  ),
                ),
                _GradeBadge(score: score),
              ],
            ),

            const SizedBox(height: 20),

            // ── Score breakdown ──────────────────────────────────────────
            _sectionLabel('Score Breakdown'),
            const SizedBox(height: 8),
            _ScoreBarChart(score: score),

            const SizedBox(height: 4),
            if (score.flags.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                children: score.flags
                    .map((f) => Chip(
                          label:     Text(f, style: const TextStyle(fontSize: 10)),
                          padding:   EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          backgroundColor:
                              AppTheme.lossColor.withValues(alpha: 0.12),
                          side: BorderSide(
                            color: AppTheme.lossColor.withValues(alpha: 0.4),
                          ),
                          labelStyle:
                              const TextStyle(color: AppTheme.lossColor),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 8),
            ],

            const SizedBox(height: 16),

            // ── IV Environment ───────────────────────────────────────────
            _sectionLabel('IV Environment'),
            const SizedBox(height: 8),
            ivAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (_, _) => const SizedBox.shrink(),
              data:  (iv)   => _IvEnvironmentSection(
                iv:      iv,
                contract: contract,
                greeks:  greeks,
                isCall:  isCall,
              ),
            ),

            const SizedBox(height: 16),

            // ── Pricing ──────────────────────────────────────────────────
            _sectionLabel('Pricing'),
            const SizedBox(height: 8),
            _GridRow(items: [
              _kv('Bid',    '\$${contract.bid.toStringAsFixed(2)}'),
              _kv('Ask',    '\$${contract.ask.toStringAsFixed(2)}'),
              _kv('Last',   '\$${contract.last.toStringAsFixed(2)}'),
              _kv('Mid',    '\$${contract.midpoint.toStringAsFixed(2)}'),
              _kv('Spread', '${(contract.spreadPct * 100).toStringAsFixed(1)}%'),
              _kv('IV',     '${contract.impliedVolatility.toStringAsFixed(1)}%'),
            ]),

            const SizedBox(height: 16),

            // ── Greeks ───────────────────────────────────────────────────
            _sectionLabel('Greeks'),
            const SizedBox(height: 8),
            _GridRow(items: [
              _kv('Delta', contract.delta.toStringAsFixed(3)),
              _kv('Gamma', contract.gamma.toStringAsFixed(4)),
              _kv('Theta', contract.theta.toStringAsFixed(3)),
              _kv('Vega',  contract.vega.toStringAsFixed(4)),
              _kv('Rho',   contract.rho.toStringAsFixed(4)),
              _kv('OI',    _fmtInt(contract.openInterest)),
            ]),

            const SizedBox(height: 16),

            // ── Market ───────────────────────────────────────────────────
            _sectionLabel('Market'),
            const SizedBox(height: 8),
            _GridRow(items: [
              _kv('Volume',   _fmtInt(contract.totalVolume)),
              _kv('OI',       _fmtInt(contract.openInterest)),
              _kv('DTE',      '${contract.daysToExpiration}d'),
              _kv('ITM',      contract.inTheMoney ? 'Yes' : 'No'),
              _kv('Intrinsic',
                  '\$${_intrinsic(contract, underlyingPrice, isCall).toStringAsFixed(2)}'),
              _kv('Time Val', '\$${contract.timeValue.toStringAsFixed(2)}'),
            ]),

            const SizedBox(height: 16),

            // Formula check
            _FormulaCheck(
              contract:        contract,
              underlyingPrice: underlyingPrice,
              isCall:          isCall,
              ivAnalysis:      ivAsync.valueOrNull,
              greeks:          greeks,
            ),

            const SizedBox(height: 28),

            // Log Trade CTA
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon:  const Icon(Icons.add_chart_rounded, size: 18),
                label: const Text('Log This Trade'),
                onPressed: () {
                  Navigator.pop(context);
                  context.push('/trades/add', extra: {
                    'prefill': {
                      'ticker':     symbol,
                      'optionType': isCall ? 'call' : 'put',
                      'strike':     contract.strikePrice,
                      'expiration': contract.expirationDate,
                      'entryPrice': contract.ask,
                      'delta':      contract.delta.abs(),
                      'impliedVol': contract.impliedVolatility,
                    },
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(
        t,
        style: const TextStyle(
          fontSize:   12,
          fontWeight: FontWeight.w700,
          color:      AppTheme.neutralColor,
          letterSpacing: 0.8,
        ),
      );

  static Widget _tag(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(5),
      border:       Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );

  static Map<String, String> _kv(String k, String v) => {'k': k, 'v': v};

  static double _intrinsic(
    SchwabOptionContract c, double ul, bool isCall,
  ) {
    if (isCall) return (ul - c.strikePrice).clamp(0, double.infinity);
    return (c.strikePrice - ul).clamp(0, double.infinity);
  }

  static String _fmtInt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}

// ── IV Environment section ────────────────────────────────────────────────────

class _IvEnvironmentSection extends StatelessWidget {
  final IvAnalysis iv;
  final SchwabOptionContract contract;
  final ({double vanna, double charm, double volga}) greeks;
  final bool isCall;

  const _IvEnvironmentSection({
    required this.iv,
    required this.contract,
    required this.greeks,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    final ivrColor = iv.ivRank == null
        ? AppTheme.neutralColor
        : iv.ivRank! >= 80
            ? AppTheme.lossColor
            : iv.ivRank! >= 50
                ? const Color(0xFFFBBF24)
                : iv.ivRank! >= 25
                    ? const Color(0xFF60A5FA)
                    : AppTheme.profitColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── IVR / IVP / Rating row ──────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: _ivStat(
                label: 'IV Rank',
                value: iv.ivRank != null
                    ? '${iv.ivRank!.toStringAsFixed(0)}%'
                    : '—',
                color: ivrColor,
                sub:   iv.rating.label,
              ),
            ),
            Expanded(
              child: _ivStat(
                label: 'IV Percentile',
                value: iv.ivPercentile != null
                    ? '${iv.ivPercentile!.toStringAsFixed(0)}%'
                    : '—',
                color: ivrColor,
                sub:   iv.historyDays < 10
                    ? '${iv.historyDays}/10d data'
                    : '${iv.historyDays}d history',
              ),
            ),
            Expanded(
              child: _ivStat(
                label: 'Skew',
                value: iv.skew != null
                    ? '${iv.skew! >= 0 ? '+' : ''}${iv.skew!.toStringAsFixed(1)}pp'
                    : '—',
                color: iv.skew != null && iv.skew! > 2
                    ? AppTheme.lossColor
                    : AppTheme.neutralColor,
                sub: iv.skew != null && iv.skew! > 2
                    ? 'Put fear premium'
                    : iv.skew != null && iv.skew! < -1
                        ? 'Call premium'
                        : 'Neutral',
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // ── Gamma regime banner ─────────────────────────────────────────
        Container(
          width:   double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color:        (iv.gammaRegime == GammaRegime.positive
                    ? AppTheme.profitColor
                    : AppTheme.lossColor)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (iv.gammaRegime == GammaRegime.positive
                      ? AppTheme.profitColor
                      : AppTheme.lossColor)
                  .withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                iv.gammaRegime == GammaRegime.positive
                    ? Icons.compress_rounded
                    : Icons.open_in_full_rounded,
                size:  14,
                color: iv.gammaRegime == GammaRegime.positive
                    ? AppTheme.profitColor
                    : AppTheme.lossColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  iv.gammaRegime.description,
                  style: TextStyle(
                    color:    iv.gammaRegime == GammaRegime.positive
                        ? AppTheme.profitColor
                        : AppTheme.lossColor,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // ── IV recommendation ───────────────────────────────────────────
        _ivRecommendation(iv, isCall),

        const SizedBox(height: 12),

        // ── This contract's second-order Greeks ─────────────────────────
        Container(
          padding:    const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:        AppTheme.cardColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'THIS CONTRACT — 2nd ORDER GREEKS',
                style: TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _greek2('Vanna', greeks.vanna, 3,
                      'Δ sensitivity to IV change'),
                  _greek2('Charm', greeks.charm, 4,
                      'Δ decay per day'),
                  _greek2('Volga', greeks.volga, 3,
                      'Vega sensitivity to IV'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _greekInterpretation(greeks, isCall),
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ivStat({
    required String label,
    required String value,
    required Color  color,
    required String sub,
  }) =>
      Container(
        margin:  const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 16, fontWeight: FontWeight.w800)),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 2),
            Text(sub,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );

  Widget _greek2(String label, double val, int dp, String sub) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${val >= 0 ? '+' : ''}${val.toStringAsFixed(dp)}',
              style: TextStyle(
                color:      val.abs() < 1e-6
                    ? AppTheme.neutralColor
                    : val > 0
                        ? AppTheme.profitColor
                        : AppTheme.lossColor,
                fontSize:   13,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.w600)),
            Text(sub,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9)),
          ],
        ),
      );

  Widget _ivRecommendation(IvAnalysis iv, bool isCall) {
    String text;
    Color  color;

    if (iv.ivRank == null) {
      return const SizedBox.shrink();
    }

    final rank = iv.ivRank!;
    if (rank >= 80) {
      text  = isCall
          ? 'IV is extreme — buying calls is expensive. Consider selling premium or using spreads.'
          : 'IV is extreme — puts carry a heavy premium. Selling puts or using put spreads may offer better risk/reward.';
      color = AppTheme.lossColor;
    } else if (rank >= 50) {
      text  = isCall
          ? 'IV is elevated — call buyers pay above-average premium. Favor spreads over naked longs.'
          : 'IV is elevated — put premium is above average. Good environment for put spreads or cash-secured puts.';
      color = const Color(0xFFFBBF24);
    } else if (rank >= 25) {
      text  = 'IV is in a fair range — option pricing is reasonable. Standard directional plays apply.';
      color = const Color(0xFF60A5FA);
    } else {
      text  = isCall
          ? 'IV is cheap — calls are inexpensive relative to recent history. Good environment for long calls or debit spreads.'
          : 'IV is cheap — puts are inexpensive. Consider long puts or debit put spreads for directional downside exposure.';
      color = AppTheme.profitColor;
    }

    return Container(
      padding:    const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline_rounded, color: color, size: 15),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  String _greekInterpretation(
      ({double vanna, double charm, double volga}) g, bool isCall) {
    final parts = <String>[];

    // Vanna
    if (g.vanna.abs() > 0.01) {
      parts.add(g.vanna > 0
          ? 'Positive Vanna: delta rises if IV rises — ${isCall ? 'call' : 'put'} gains if market moves and vol spikes together.'
          : 'Negative Vanna: delta falls if IV rises — vol expansion works against your delta.');
    }

    // Charm
    if (g.charm.abs() > 0.001) {
      parts.add(g.charm < 0
          ? 'Negative Charm: delta bleeds away each day — time decay erodes your directional exposure.'
          : 'Positive Charm: delta grows each day — a favorable time-decay effect on positioning.');
    }

    // Volga
    if (g.volga.abs() > 0.05) {
      parts.add(g.volga > 0
          ? 'Positive Volga: vega accelerates as IV moves — benefits from volatility-of-volatility.'
          : 'Negative Volga: vega shrinks as IV moves — exposure decreases in high-vol regimes.');
    }

    if (parts.isEmpty) return 'Second-order effects are small for this contract.';
    return parts.join(' ');
  }
}

// ── Score badge ───────────────────────────────────────────────────────────────

class _GradeBadge extends StatelessWidget {
  final OptionScore score;
  const _GradeBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    final color = _gradeColor(score.grade);
    return Column(
      children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            shape:  BoxShape.circle,
            border: Border.all(color: color, width: 2.5),
            color:  color.withValues(alpha: 0.1),
          ),
          child: Center(
            child: Text(
              '${score.total}',
              style: TextStyle(
                color:      color,
                fontSize:   20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          score.grade,
          style: TextStyle(
            color:      color,
            fontSize:   13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Color _gradeColor(String g) => switch (g) {
        'A' => AppTheme.profitColor,
        'B' => const Color(0xFF60A5FA),
        'C' => const Color(0xFFFBBF24),
        _   => AppTheme.lossColor,
      };
}

// ── Score bar chart ───────────────────────────────────────────────────────────

class _ScoreBarChart extends StatelessWidget {
  final OptionScore score;
  const _ScoreBarChart({required this.score});

  @override
  Widget build(BuildContext context) {
    final bars = [
      ('Delta',     score.deltaScore,     20),
      ('DTE',       score.dteScore,       20),
      ('Spread',    score.spreadScore,    15),
      ('IV',        score.ivScore,        20),
      ('OI',        score.oiScore,        10),
      ('Moneyness', score.moneynessScore, 15),
    ];

    return SizedBox(
      height: 120,
      child: BarChart(
        BarChartData(
          alignment:    BarChartAlignment.spaceAround,
          maxY:         20,
          barTouchData: BarTouchData(enabled: false),
          borderData:   FlBorderData(show: false),
          gridData:     FlGridData(show: false),
          titlesData: FlTitlesData(
            leftTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles:   true,
                reservedSize: 28,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= bars.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      bars[i].$1,
                      style: const TextStyle(
                        color:    AppTheme.neutralColor,
                        fontSize: 8,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: List.generate(bars.length, (i) {
            final val = bars[i].$2.toDouble();
            final max = bars[i].$3.toDouble();
            final pct = max == 0 ? 0.0 : val / max;
            final color = pct >= 0.75
                ? AppTheme.profitColor
                : pct >= 0.5
                    ? const Color(0xFF60A5FA)
                    : pct >= 0.25
                        ? const Color(0xFFFBBF24)
                        : AppTheme.lossColor;
            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY:           val,
                  color:         color,
                  width:         22,
                  borderRadius:  BorderRadius.circular(4),
                  backDrawRodData: BackgroundBarChartRodData(
                    show:  true,
                    toY:   max,
                    color: AppTheme.cardColor,
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

// ── 2-col kv grid ─────────────────────────────────────────────────────────────

class _GridRow extends StatelessWidget {
  final List<Map<String, String>> items;
  const _GridRow({required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount:    3,
      shrinkWrap:        true,
      physics:           const NeverScrollableScrollPhysics(),
      crossAxisSpacing:  8,
      mainAxisSpacing:   8,
      childAspectRatio:  2.2,
      children: items.map((m) {
        return Container(
          padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color:        AppTheme.cardColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment:  MainAxisAlignment.center,
            children: [
              Text(
                m['v']!,
                style: const TextStyle(
                  color:      Colors.white,
                  fontSize:   13,
                  fontWeight: FontWeight.w700,
                ),
                maxLines:  1,
                overflow:  TextOverflow.ellipsis,
              ),
              Text(
                m['k']!,
                style: const TextStyle(
                  color:    AppTheme.neutralColor,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Formula Check ─────────────────────────────────────────────────────────────
//
//  BASE:  X = |Strike − Price|   Y = DTE / ATR   K = |Δ| / X
//         (X / Y) > K  →  feasibility > efficiency = Good Trade
//
//  ADVANCED FILTERS (from formulas.md):
//  1. Gamma Gravity   — Y / (1 + GEX_norm)       suppression check
//  2. Ice Cube        — K / (|Charm| × DTE)       decay vs leverage
//  3. Vanna-Speed     — (K × Vanna) × IVR         vol-coil / squeeze potential
//  4. Tail Stress     — (Volga × Skew) / IVP       black-swan premium burden

class _FormulaCheck extends StatefulWidget {
  final SchwabOptionContract contract;
  final double underlyingPrice;
  final bool   isCall;
  final IvAnalysis? ivAnalysis;
  final ({double vanna, double charm, double volga}) greeks;

  const _FormulaCheck({
    required this.contract,
    required this.underlyingPrice,
    required this.isCall,
    required this.ivAnalysis,
    required this.greeks,
  });

  @override
  State<_FormulaCheck> createState() => _FormulaCheckState();
}

class _FormulaCheckState extends State<_FormulaCheck> {
  late TextEditingController _atrCtrl;

  static double _estimateAtr(double price, double ivPct) {
    final dailyVol = (ivPct / 100) / math.sqrt(252);
    return price * dailyVol * math.sqrt(14);
  }

  @override
  void initState() {
    super.initState();
    _atrCtrl = TextEditingController(
        text: _estimateAtr(
          widget.underlyingPrice,
          widget.contract.impliedVolatility,
        ).toStringAsFixed(2));
  }

  @override
  void dispose() {
    _atrCtrl.dispose();
    super.dispose();
  }

  // ── GEX helpers ─────────────────────────────────────────────────────────

  double _gexAtStrike() {
    final iv  = widget.ivAnalysis;
    if (iv == null || iv.gexStrikes.isEmpty) return 0;
    final strike = widget.contract.strikePrice;
    final spot   = widget.underlyingPrice;
    final closest = iv.gexStrikes.reduce((a, b) =>
        (a.strike - strike).abs() < (b.strike - strike).abs() ? a : b);
    return closest.dealerGex(spot);
  }

  // Normalize GEX to [0..∞) by dividing by max absolute GEX across all strikes.
  double _gexNormalized() {
    final iv = widget.ivAnalysis;
    if (iv == null || iv.gexStrikes.isEmpty) return 0;
    final spot   = widget.underlyingPrice;
    final values = iv.gexStrikes.map((g) => g.dealerGex(spot).abs()).toList();
    final maxGex = values.reduce(math.max);
    if (maxGex < 1e-6) return 0;
    return _gexAtStrike().abs() / maxGex;
  }

  @override
  Widget build(BuildContext context) {
    final price  = widget.underlyingPrice;
    final strike = widget.contract.strikePrice;
    final delta  = widget.contract.delta.abs();
    final dte    = widget.contract.daysToExpiration;
    final atr    = double.tryParse(_atrCtrl.text) ?? 1.0;
    final iv     = widget.ivAnalysis;
    final g      = widget.greeks;

    // ── Base variables ──────────────────────────────────────────────────────
    final x     = (strike - price).abs();        // distance to target ($)
    final y     = atr > 0 ? dte / atr : 0.0;   // movement potential
    final k     = x > 0  ? delta / x  : 0.0;   // probability efficiency
    final ratio = y > 0  ? x / y      : 0.0;   // feasibility (X/Y)
    final baseGood = ratio > k;

    // ── Advanced filter computations ────────────────────────────────────────

    // 1. Gamma Gravity — adjusted movement potential after GEX suppression
    final gexNorm         = _gexNormalized();
    final adjPotential    = y > 0 ? y / (1 + gexNorm) : 0.0;
    final gravityOk       = adjPotential > k; // still passes after GEX damping?

    // 2. Ice Cube — how fast is leverage melting vs price closing the gap?
    //    K / (|Charm| × DTE): < 1 → charm decay outpaces delta efficiency
    final absCharm        = g.charm.abs();
    final efficiencyDecay = (absCharm > 0 && dte > 0)
        ? k / (absCharm * dte)
        : double.infinity;
    final iceOk           = efficiencyDecay >= 1.0;

    // 3. Vanna-Speed — vol-coil score: does an IV spike supercharge delta?
    //    (K × Vanna) × IVR  — high & positive = squeeze setup
    final ivr             = iv?.ivRank ?? 0.0;
    final convexityScore  = k * g.vanna * ivr;
    final isCoiled        = convexityScore > 0.05;

    // 4. Tail Stress — is the market pricing a black-swan event?
    //    (Volga × Skew) / IVP — high = OTMs expensive for a reason
    final skew            = iv?.skew ?? 0.0;
    final ivp             = (iv?.ivPercentile ?? 50.0).clamp(1.0, 100.0);
    final tailStress      = (g.volga * skew.abs()) / ivp;
    final tailHigh        = tailStress > 0.05;

    // Overall score: how many green lights?
    final greenCount = [baseGood, gravityOk, iceOk, isCoiled && !tailHigh]
        .where((b) => b).length;
    final overallColor = greenCount >= 3
        ? AppTheme.profitColor
        : greenCount == 2
            ? const Color(0xFFFBBF24)
            : AppTheme.lossColor;

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: overallColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          _header(overallColor, greenCount),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── ATR input ────────────────────────────────────────────
                _atrInput(),
                const SizedBox(height: 14),

                // ── Base variables ────────────────────────────────────────
                _varRow('X', '|Strike − Price|',
                    '\$${x.toStringAsFixed(2)}', 'Distance to target',
                    const Color(0xFF60A5FA)),
                const SizedBox(height: 6),
                _varRow('Y', 'DTE / ATR  =  $dte / \$${atr.toStringAsFixed(2)}',
                    y.toStringAsFixed(3), 'Movement potential (days per ATR)',
                    const Color(0xFFFBBF24)),
                const SizedBox(height: 6),
                _varRow('K', '|Δ| / X  =  ${delta.toStringAsFixed(3)} / \$${x.toStringAsFixed(2)}',
                    k.toStringAsFixed(4), 'Probability efficiency (delta per \$)',
                    const Color(0xFFA78BFA)),

                const SizedBox(height: 14),
                _divider(),
                const SizedBox(height: 14),

                // ── BASE: (X/Y) > K ───────────────────────────────────────
                _filterBlock(
                  icon:    '⚡',
                  title:   'BASE CHECK  ·  (X/Y) > K',
                  color:   baseGood ? AppTheme.profitColor : AppTheme.lossColor,
                  verdict: baseGood ? 'GOOD TRADE' : 'PASS',
                  isGood:  baseGood,
                  calc:    '${ratio.toStringAsFixed(3)}  ${baseGood ? '>' : '<'}  ${k.toStringAsFixed(4)}',
                  body:    baseGood
                      ? 'The stock has enough speed (ATR \$${atr.toStringAsFixed(2)}) relative to '
                        'the distance (\$${x.toStringAsFixed(2)}) and time ($dte days). '
                        'Feasibility outweighs probability efficiency — realistic path to profit.'
                      : 'Distance (\$${x.toStringAsFixed(2)}) is too large for the current ATR '
                        'and $dte days remaining. Try a closer strike or longer expiry.',
                ),

                const SizedBox(height: 10),

                // ── 1. GAMMA GRAVITY ──────────────────────────────────────
                _filterBlock(
                  icon:    '🌊',
                  title:   'GAMMA GRAVITY  ·  Y / (1 + GEX_norm)',
                  color:   gravityOk ? AppTheme.profitColor : const Color(0xFFFBBF24),
                  verdict: gravityOk ? 'BREAKOUT OK' : 'PINNED',
                  isGood:  gravityOk,
                  calc:    '${y.toStringAsFixed(3)} / (1 + ${gexNorm.toStringAsFixed(3)}) = ${adjPotential.toStringAsFixed(3)}',
                  body:    iv == null
                      ? 'Open IV Analytics for this ticker to compute GEX data.'
                      : gravityOk
                          ? 'GEX at this strike is ${gexNorm < 0.3 ? 'low' : 'moderate'} — market-maker hedging '
                            'is not strong enough to pin price. Your ATR-based speed survives the adjustment.'
                          : 'High positive GEX (${_gexAtStrike().toStringAsFixed(0)}M) at \$${strike.toStringAsFixed(0)} acts as '
                            '"market glue." Dealers will hedge against the move, suppressing your expected ATR. '
                            'The breakout may stall at this strike.',
                ),

                const SizedBox(height: 10),

                // ── 2. ICE CUBE ───────────────────────────────────────────
                _filterBlock(
                  icon:    '🧊',
                  title:   'ICE CUBE  ·  K / (|Charm| × DTE)',
                  color:   iceOk ? AppTheme.profitColor : AppTheme.lossColor,
                  verdict: iceOk ? 'SOLID' : 'MELTING',
                  isGood:  iceOk,
                  calc:    efficiencyDecay.isInfinite
                      ? 'Charm ≈ 0 — no decay pressure'
                      : '${k.toStringAsFixed(4)} / (${absCharm.toStringAsFixed(5)} × $dte) = ${efficiencyDecay.toStringAsFixed(3)}',
                  body:    iceOk
                      ? 'Your leverage efficiency (K=${k.toStringAsFixed(4)}) is holding up against '
                        'daily delta decay (Charm=${g.charm.toStringAsFixed(5)}). '
                        'The option is not melting faster than the stock is moving.'
                      : 'Charm (${g.charm.toStringAsFixed(5)}/day) is eating your delta efficiency faster '
                        'than the stock can close the \$${x.toStringAsFixed(2)} gap in $dte days. '
                        'This is a "melting ice cube" — the leverage you\'re paying for is evaporating.',
                ),

                const SizedBox(height: 10),

                // ── 3. VANNA-SPEED ────────────────────────────────────────
                _filterBlock(
                  icon:    '🔥',
                  title:   'VANNA-SPEED  ·  (K × Vanna) × IVR',
                  color:   isCoiled
                      ? AppTheme.profitColor
                      : convexityScore < 0
                          ? AppTheme.lossColor
                          : AppTheme.neutralColor,
                  verdict: isCoiled
                      ? 'COILED'
                      : convexityScore < 0
                          ? 'MISALIGNED'
                          : 'DORMANT',
                  isGood:  isCoiled,
                  calc:    '(${k.toStringAsFixed(4)} × ${g.vanna.toStringAsFixed(4)}) × '
                      '${ivr.toStringAsFixed(1)} = ${convexityScore.toStringAsFixed(4)}',
                  body:    isCoiled
                      ? 'Volatility coil detected. If IV spikes, Vanna (${g.vanna.toStringAsFixed(4)}) will '
                        'push delta in your favor non-linearly. IVR at ${ivr.toStringAsFixed(0)}% '
                        'means vol has room to expand — this could be a squeeze setup.'
                      : convexityScore < 0
                          ? 'Vanna (${g.vanna.toStringAsFixed(4)}) is working against you. An IV spike '
                            'would actually reduce your delta, making a vol expansion event harmful.'
                          : 'Low convexity score — IV and delta are not strongly coupled at this strike. '
                            'This trade relies on pure directional movement, not vol acceleration.',
                ),

                const SizedBox(height: 10),

                // ── 4. TAIL STRESS ────────────────────────────────────────
                _filterBlock(
                  icon:    '☠',
                  title:   'TAIL STRESS  ·  (Volga × Skew) / IVP',
                  color:   tailHigh ? AppTheme.lossColor : AppTheme.profitColor,
                  verdict: tailHigh ? 'ELEVATED' : 'NORMAL',
                  isGood:  !tailHigh,
                  calc:    iv == null
                      ? 'Requires IV history data'
                      : '(${g.volga.toStringAsFixed(3)} × ${skew.toStringAsFixed(2)}) / '
                        '${ivp.toStringAsFixed(0)} = ${tailStress.toStringAsFixed(4)}',
                  body:    iv == null
                      ? 'Open IV Analytics for this ticker to compute skew and IVP data.'
                      : tailHigh
                          ? 'The market is pricing a tail event. Volga (${g.volga.toStringAsFixed(3)}) '
                            '× Skew (${skew.toStringAsFixed(2)}pp) / IVP (${ivp.toStringAsFixed(0)}%) = ${tailStress.toStringAsFixed(4)}. '
                            'OTM options may look "cheap" on X/Y math but the market is paying a '
                            'black-swan premium. Standard trade math breaks down here.'
                          : 'Tail stress is within normal bounds. The market is not pricing an '
                            'extreme event — your X/Y feasibility check is not distorted by fear premium.',
                ),

                const SizedBox(height: 14),
                _divider(),
                const SizedBox(height: 10),

                // ── Summary scorecard ─────────────────────────────────────
                _scorecard(baseGood, gravityOk, iceOk, isCoiled, tailHigh, greenCount),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Sub-widgets ──────────────────────────────────────────────────────────

  Widget _header(Color color, int greenCount) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.2))),
        ),
        child: Row(
          children: [
            const Icon(Icons.functions_rounded, color: AppTheme.neutralColor, size: 15),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('FORMULA CHECK',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 11,
                      fontWeight: FontWeight.w800, letterSpacing: 1.0)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color:        color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border:       Border.all(color: color.withValues(alpha: 0.5)),
              ),
              child: Text('$greenCount / 4 GREEN',
                  style: TextStyle(color: color, fontSize: 11,
                      fontWeight: FontWeight.w900, letterSpacing: 0.5)),
            ),
          ],
        ),
      );

  Widget _atrInput() => Row(
        children: [
          const Text('ATR (14d)',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          SizedBox(
            width: 90, height: 32,
            child: TextField(
              controller:  _atrCtrl,
              onChanged:   (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white, fontSize: 13,
                  fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                prefixText:     '\$',
                prefixStyle:    const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 13),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                filled:         true,
                fillColor:      AppTheme.elevatedColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: AppTheme.borderColor.withValues(alpha: 0.5))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppTheme.profitColor)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'IV est. \$${_estimateAtr(widget.underlyingPrice, widget.contract.impliedVolatility).toStringAsFixed(2)}',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  Widget _varRow(String symbol, String formula, String value, String desc, Color color) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              color:        color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(5),
              border:       Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Center(child: Text(symbol,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(formula, style: const TextStyle(color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w600)),
              Text(desc, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
            ]),
          ),
          Text(value, style: TextStyle(color: color, fontSize: 13,
              fontWeight: FontWeight.w800, fontFamily: 'monospace')),
        ],
      );

  Widget _filterBlock({
    required String icon,
    required String title,
    required Color  color,
    required String verdict,
    required bool   isGood,
    required String calc,
    required String body,
  }) =>
      Container(
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(8),
          border:       Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Text(icon, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(color: AppTheme.neutralColor,
                            fontSize: 9, fontWeight: FontWeight.w700,
                            letterSpacing: 0.8)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color:        color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border:       Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Text(verdict,
                        style: TextStyle(color: color, fontSize: 9,
                            fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                  ),
                ],
              ),
            ),
            // Calculation line
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(calc,
                  style: TextStyle(color: color, fontSize: 11,
                      fontWeight: FontWeight.w700, fontFamily: 'monospace')),
            ),
            // Body
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                color:        color.withValues(alpha: 0.05),
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(8)),
              ),
              child: Text(body,
                  style: const TextStyle(color: AppTheme.neutralColor,
                      fontSize: 11, height: 1.4)),
            ),
          ],
        ),
      );

  Widget _scorecard(bool base, bool gravity, bool ice, bool coiled,
      bool tailHigh, int greenCount) {
    final items = [
      (label: 'Base (X/Y>K)',    ok: base),
      (label: 'Gamma Gravity',   ok: gravity),
      (label: 'Ice Cube',        ok: ice),
      (label: 'Vanna-Speed',     ok: coiled),
      (label: 'Tail Stress',     ok: !tailHigh),
    ];
    final total = items.where((i) => i.ok).length;
    final color = total >= 4
        ? AppTheme.profitColor
        : total >= 3
            ? const Color(0xFFFBBF24)
            : AppTheme.lossColor;
    final summary = total >= 4
        ? 'Strong setup — all major filters green. High-conviction entry.'
        : total == 3
            ? 'Moderate setup — most filters align. Manage size accordingly.'
            : total == 2
                ? 'Borderline — significant headwinds. Wait for better alignment.'
                : 'Weak setup — multiple filters failing. Avoid or paper-trade.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: items.map((item) => Column(
              children: [
                Icon(
                  item.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  color: item.ok ? AppTheme.profitColor : AppTheme.lossColor,
                  size: 18,
                ),
                const SizedBox(height: 3),
                Text(item.label,
                    style: const TextStyle(color: AppTheme.neutralColor,
                        fontSize: 8),
                    textAlign: TextAlign.center),
              ],
            )).toList(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('$total/5 FILTERS PASSED',
                  style: TextStyle(color: color, fontSize: 12,
                      fontWeight: FontWeight.w900)),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 4),
          Text(summary,
              style: const TextStyle(color: AppTheme.neutralColor,
                  fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.3));
}
