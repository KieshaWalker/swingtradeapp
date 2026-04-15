// =============================================================================
// features/blotter/screens/trade_blotter_analysis_widgets.dart
// =============================================================================
// Analysis/result display widgets used by TradeBlotterScreen:
//   ModelVsMarketCard, PriceCell, GreekCell, EdgeBar,
//   WhatIfMatrixCard, MatrixRow
// =============================================================================

import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/schwab/schwab_models.dart';
import '../models/blotter_models.dart';
import 'trade_blotter_form_widgets.dart' show SectionCard;

// ── Model vs Market card ──────────────────────────────────────────────────────

class ModelVsMarketCard extends StatelessWidget {
  final FairValueResult fv;
  final SchwabOptionContract contract;
  const ModelVsMarketCard({super.key, required this.fv, required this.contract});

  @override
  Widget build(BuildContext context) {
    final edgeColor = fv.edgeColor;

    return SectionCard(
      label: 'MODEL vs MARKET',
      accent: const Color(0xFFFBBF24),
      child: Column(
        children: [
          // Price comparison grid
          Row(
            children: [
              Expanded(
                child: PriceCell(
                  label: 'BROKER MID',
                  value: '\$${fv.brokerMid.toStringAsFixed(3)}',
                  sub: 'Live (bid+ask)/2',
                  color: Colors.white,
                  tooltip:
                      'The midpoint between the broker\'s bid and ask prices, representing the current market price for the option.',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PriceCell(
                  label: 'BS BASELINE',
                  value: '\$${fv.bsFairValue.toStringAsFixed(3)}',
                  sub: 'Black-Scholes',
                  color: const Color(0xFF94A3B8),
                  tooltip:
                      'Fair value calculated using the classic Black-Scholes model, which assumes constant volatility and lognormal stock prices.',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PriceCell(
                  label: 'SABR IV',
                  value: '${(fv.sabrVol * 100).toStringAsFixed(2)}%',
                  sub: 'vs mkt ${(fv.impliedVol * 100).toStringAsFixed(2)}%',
                  color: const Color(0xFF60A5FA),
                  tooltip:
                      'Implied volatility calibrated using the SABR (Stochastic Alpha Beta Rho) model, which better fits the volatility smile in options markets.',
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Internal model fair value + edge
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: edgeColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: edgeColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'HESTON/SABR FAIR VALUE',
                            style: TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 9,
                              letterSpacing: 1.0,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message:
                                'Advanced fair value combining Heston stochastic volatility model with SABR calibration for more accurate pricing of options with complex volatility dynamics.',
                            child: const Icon(
                              Icons.info_outline,
                              size: 10,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '\$${fv.modelFairValue.toStringAsFixed(3)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${fv.edgeBps >= 0 ? '+' : ''}${fv.edgeBps.toStringAsFixed(1)} bps',
                      style: TextStyle(
                        color: edgeColor,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: edgeColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: edgeColor.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        fv.edgeLabel,
                        style: TextStyle(
                          color: edgeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Edge bar
          EdgeBar(edgeBps: fv.edgeBps),

          const SizedBox(height: 10),

          // Greeks summary row
          Row(
            children: [
              Expanded(
                child: GreekCell('Δ', contract.delta.toStringAsFixed(3)),
              ),
              Expanded(
                child: GreekCell('Γ', contract.gamma.toStringAsFixed(5)),
              ),
              Expanded(
                child: GreekCell('Θ', contract.theta.toStringAsFixed(3)),
              ),
              Expanded(
                child: GreekCell('ν', contract.vega.toStringAsFixed(4)),
              ),
              Expanded(child: GreekCell('ρ', contract.rho.toStringAsFixed(4))),
              Expanded(
                child: GreekCell(
                  'IV',
                  '${contract.impliedVolatility.toStringAsFixed(1)}%',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PriceCell extends StatelessWidget {
  final String label, value, sub;
  final Color color;
  final String? tooltip;
  const PriceCell({
    super.key,
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cell = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(6),
        border: const Border(
          left: BorderSide(color: Color(0xFF2A2A38), width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontSize: 8,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: tooltip,
                  child: const Icon(
                    Icons.info_outline,
                    size: 10,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            sub,
            style: const TextStyle(color: Color(0xFF4B5563), fontSize: 9),
          ),
        ],
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: cell) : cell;
  }
}

class GreekCell extends StatelessWidget {
  final String symbol, value;
  const GreekCell(this.symbol, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        symbol,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    ],
  );
}

class EdgeBar extends StatelessWidget {
  final double edgeBps;
  const EdgeBar({super.key, required this.edgeBps});

  @override
  Widget build(BuildContext context) {
    const maxEdge = 100.0;
    final clamped = edgeBps.clamp(-maxEdge, maxEdge);
    final pct = (clamped + maxEdge) / (maxEdge * 2); // 0..1
    final color = edgeBps >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '−100 bps',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 9),
            ),
            const Text(
              'EDGE',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const Text(
              '+100 bps',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 9),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            // Track
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A38),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Centre line
            Positioned(
              left: MediaQuery.sizeOf(context).width / 2 - 14 - 1,
              child: Container(
                width: 1,
                height: 6,
                color: const Color(0xFF4B5563),
              ),
            ),
            // Fill
            FractionallySizedBox(
              widthFactor: pct.clamp(0.01, 1.0),
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── What-If Matrix card ───────────────────────────────────────────────────────

class WhatIfMatrixCard extends StatelessWidget {
  final PortfolioState portfolio;
  final WhatIfResult whatIf;
  const WhatIfMatrixCard({super.key, required this.portfolio, required this.whatIf});

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      label: 'PRE-TRADE WHAT-IF MATRIX',
      accent: whatIf.exceedsDeltaThreshold
          ? AppTheme.lossColor
          : const Color(0xFF34D399),
      child: Column(
        children: [
          // Header row
          MatrixRow(
            isHeader: true,
            greek: 'METRIC',
            current: 'CURRENT',
            impact: 'IMPACT',
            newVal: 'NEW TOTAL',
          ),

          const SizedBox(height: 6),

          // Delta row
          MatrixRow(
            greek: 'Delta (Δ)',
            current: _fmt(portfolio.totalDelta, 1),
            impact: _fmtSigned(whatIf.deltaImpact, 1),
            newVal: _fmt(whatIf.newDelta, 1),
            heat: _deltaHeat(whatIf.newDelta, whatIf.deltaThreshold),
          ),

          const SizedBox(height: 4),

          // Vega row
          MatrixRow(
            greek: 'Vega (ν)',
            current: _fmt(portfolio.totalVega, 1),
            impact: _fmtSigned(whatIf.vegaImpact, 1),
            newVal: _fmt(whatIf.newVega, 1),
            heat: _vegaHeat(whatIf.newVega),
          ),

          const SizedBox(height: 4),

          // ES₉₅ row
          MatrixRow(
            greek: 'ES₉₅ (95%)',
            current: '\$${_fmtK(portfolio.totalEs95)}',
            impact: '+\$${_fmtK(whatIf.es95Impact)}',
            newVal: '\$${_fmtK(whatIf.newEs95)}',
            heat: _esHeat(whatIf.newEs95),
          ),

          if (whatIf.exceedsDeltaThreshold) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.lossColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppTheme.lossColor.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: AppTheme.lossColor,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Portfolio delta would reach ${whatIf.newDelta.toStringAsFixed(0)}, '
                      'exceeding the ±${whatIf.deltaThreshold.toStringAsFixed(0)} limit. '
                      'Commit is blocked. Reduce size or add a hedge.',
                      style: const TextStyle(
                        color: AppTheme.lossColor,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Heatmap colour helpers
  Color _deltaHeat(double delta, double limit) {
    final ratio = delta.abs() / limit;
    if (ratio > 1.0) return AppTheme.lossColor;
    if (ratio > 0.75) return const Color(0xFFFBBF24);
    if (ratio > 0.50) return const Color(0xFF86EFAC);
    return const Color(0xFF34D399);
  }

  Color _vegaHeat(double vega) {
    final abs = vega.abs();
    if (abs > 5000) return AppTheme.lossColor;
    if (abs > 2000) return const Color(0xFFFBBF24);
    return const Color(0xFF34D399);
  }

  Color _esHeat(double es) {
    if (es > 50000) return AppTheme.lossColor;
    if (es > 20000) return const Color(0xFFFBBF24);
    return const Color(0xFF34D399);
  }

  static String _fmt(double v, int dp) =>
      v >= 0 ? v.toStringAsFixed(dp) : v.toStringAsFixed(dp);

  static String _fmtSigned(double v, int dp) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(dp)}';

  static String _fmtK(double v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);
}

class MatrixRow extends StatelessWidget {
  final String greek, current, impact, newVal;
  final bool isHeader;
  final Color heat;

  const MatrixRow({
    super.key,
    required this.greek,
    required this.current,
    required this.impact,
    required this.newVal,
    this.isHeader = false,
    this.heat = Colors.transparent,
  });

  @override
  Widget build(BuildContext context) {
    final style = isHeader
        ? const TextStyle(
            color: Color(0xFF6B7280),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          )
        : const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isHeader ? Colors.transparent : const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(5),
        border: isHeader
            ? null
            : Border(left: BorderSide(color: heat, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(greek, style: style)),
          Expanded(
            flex: 2,
            child: Text(current, style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text(
              impact,
              style: style.copyWith(
                color: isHeader
                    ? const Color(0xFF6B7280)
                    : impact.startsWith('+')
                    ? const Color(0xFFFbBF24)
                    : const Color(0xFF94A3B8),
              ),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              newVal,
              style: style.copyWith(
                color: isHeader ? const Color(0xFF6B7280) : heat,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
