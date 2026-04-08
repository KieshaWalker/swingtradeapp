// =============================================================================
// features/options/widgets/option_score_sheet.dart
// Bottom sheet — score breakdown + greeks + "Log Trade" prefill
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/schwab/schwab_models.dart';
import '../services/option_scoring_engine.dart';

class OptionScoreSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final score  = OptionScoringEngine.score(contract, underlyingPrice);
    final isCall = contract.symbol.contains('C');
    final color  = isCall ? AppTheme.profitColor : AppTheme.lossColor;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize:     0.5,
      maxChildSize:     0.95,
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

            // Header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '\$${contract.strikePrice.toStringAsFixed(0)} '
                        '${isCall ? 'CALL' : 'PUT'}',
                        style: TextStyle(
                          color:      color,
                          fontSize:   22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        '${contract.daysToExpiration}d to exp  ·  '
                        '${contract.expirationDate}',
                        style: const TextStyle(
                          color:    AppTheme.neutralColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _GradeBadge(score: score),
              ],
            ),

            const SizedBox(height: 20),

            // Score bar chart
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

            // Pricing
            _sectionLabel('Pricing'),
            const SizedBox(height: 8),
            _GridRow(items: [
              _kv('Bid',  '\$${contract.bid.toStringAsFixed(2)}'),
              _kv('Ask',  '\$${contract.ask.toStringAsFixed(2)}'),
              _kv('Last', '\$${contract.last.toStringAsFixed(2)}'),
              _kv('Mid',  '\$${contract.midpoint.toStringAsFixed(2)}'),
              _kv('Spread',
                  '${(contract.spreadPct * 100).toStringAsFixed(1)}%'),
              _kv('IV',
                  '${contract.impliedVolatility.toStringAsFixed(1)}%'),
            ]),

            const SizedBox(height: 16),

            // Greeks
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

            // Volume / value
            _sectionLabel('Market'),
            const SizedBox(height: 8),
            _GridRow(items: [
              _kv('Volume',  _fmtInt(contract.totalVolume)),
              _kv('OI',      _fmtInt(contract.openInterest)),
              _kv('DTE',     '${contract.daysToExpiration}d'),
              _kv('ITM',     contract.inTheMoney ? 'Yes' : 'No'),
              _kv('Intrinsic',
                  '\$${_intrinsic(contract, underlyingPrice, isCall).toStringAsFixed(2)}'),
              _kv('Time Val', '\$${contract.timeValue.toStringAsFixed(2)}'),
            ]),

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
                      'ticker':      symbol,
                      'optionType':  isCall ? 'call' : 'put',
                      'strike':      contract.strikePrice,
                      'expiration':  contract.expirationDate,
                      'entryPrice':  contract.ask,
                      'delta':       contract.delta.abs(),
                      'impliedVol':  contract.impliedVolatility,
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
