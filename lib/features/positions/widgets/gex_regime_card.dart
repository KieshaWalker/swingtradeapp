// =============================================================================
// features/positions/widgets/gex_regime_card.dart
// =============================================================================
// Extracted from the private _GexRegimeCard inside
// features/blotter/widgets/phase_panels/blotter_phase_panel.dart when the
// blotter/ideas trade-eval screens were removed. Un-privated and generalized
// for reuse on the Positions page — logic unchanged from the original.
//
// Shows a ticker's current gamma regime (positive/negative), gamma slope,
// vanna regime, net GEX, the GEX wall (max-GEX strike), and the regime
// multiplier breakdown (Gm × Vm) that option_scoring.py's regime-adjusted
// score is built from — sourced entirely from IvAnalysis
// (services/iv/iv_providers.dart), already fetched elsewhere in the app.
// =============================================================================

import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/iv/iv_models.dart';

class GexRegimeCard extends StatelessWidget {
  final IvAnalysis? ivAnalysis;
  final bool        loading;
  final String      ticker;
  final bool        isCall;

  const GexRegimeCard({
    super.key,
    required this.ivAnalysis,
    required this.loading,
    required this.ticker,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const _LoadingRow(label: 'Loading GEX data…'),
      );
    }

    final regime   = ivAnalysis?.gammaRegime ?? GammaRegime.unknown;
    final slope    = ivAnalysis?.gammaSlope   ?? GammaSlope.flat;
    final vr       = ivAnalysis?.vannaRegime  ?? VannaRegime.unknown;
    final totalGex = ivAnalysis?.totalGex;
    final flipPct  = ivAnalysis?.spotToZeroGammaPct;
    final gexWall  = ivAnalysis?.maxGexStrike;

    // ── Regime multipliers — single source of truth in RegimeMultipliers ────────
    final rm               = RegimeMultipliers.from(ivAnalysis);
    final gexMultiplier    = rm.gexMultiplier;
    final vannaMultiplier  = rm.vannaMultiplier;
    final regimeFail       = rm.regimeFail;
    final nearFlip         = rm.nearFlip;
    final regimeMultiplier = rm.regimeMultiplier;
    final gexKnown         = regime != GammaRegime.unknown;
    final gexMisaligned    = gexKnown &&
        ((isCall && regime == GammaRegime.negative) ||
         (!isCall && regime == GammaRegime.positive));

    final Color regimeColor;
    final IconData regimeIcon;
    switch (regime) {
      case GammaRegime.positive:
        regimeColor = AppTheme.profitColor;
        regimeIcon  = Icons.compress_rounded;
      case GammaRegime.negative:
        regimeColor = AppTheme.lossColor;
        regimeIcon  = Icons.expand_rounded;
      case GammaRegime.unknown:
        regimeColor = AppTheme.neutralColor;
        regimeIcon  = Icons.help_outline_rounded;
    }

    final Color slopeColor = switch (slope) {
      GammaSlope.rising  => AppTheme.profitColor,
      GammaSlope.flat    => AppTheme.neutralColor,
      GammaSlope.falling => const Color(0xFFFBBF24),
    };

    final Color alignColor = gexMisaligned
        ? AppTheme.lossColor
        : gexKnown
            ? AppTheme.profitColor
            : AppTheme.neutralColor;
    final String alignLabel = gexMisaligned
        ? (isCall ? 'GEX headwind for calls' : 'GEX headwind for puts')
        : gexKnown
            ? (isCall ? '✓ GEX tailwind — supports call' : '✓ GEX tailwind — supports put')
            : 'GEX regime unknown';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(
            color: regimeFail
                ? AppTheme.lossColor.withValues(alpha: 0.35)
                : AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Regime + net GEX row
          Row(
            children: [
              Icon(regimeIcon, size: 16, color: regimeColor),
              const SizedBox(width: 8),
              Text(
                regime.label,
                style: TextStyle(
                    color: regimeColor, fontSize: 14,
                    fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              // Slope chip
              if (gexKnown)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color:        slopeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                    border:       Border.all(color: slopeColor.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    slope.label,
                    style: TextStyle(
                        color: slopeColor, fontSize: 10,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              const Spacer(),
              if (totalGex != null) ...[
                Text('Net GEX  ',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
                Text(
                  ivAnalysis!.gexLabel,
                  style: TextStyle(
                      color: regimeColor, fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            regime.description,
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, height: 1.4),
          ),
          if (gexWall != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.fence_rounded,
                    size: 13, color: AppTheme.neutralColor),
                const SizedBox(width: 5),
                Text(
                  'Gamma wall at \$${gexWall.toStringAsFixed(gexWall == gexWall.truncateToDouble() ? 0 : 2)}'
                  '  — major support/resistance level for market makers',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          // ── Regime multiplier breakdown ─────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:        AppTheme.elevatedColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: ivAnalysis == null
                ? const Text(
                    'GEX data unavailable — regime multipliers not computed',
                    style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Gm row
                      _MultiplierRow(
                        label:  'Gm  (GEX multiplier)',
                        value:  '${gexMultiplier.toStringAsFixed(2)}×',
                        detail: regimeFail
                            ? 'Short Gamma — score capped at 35'
                            : nearFlip
                                ? 'Near flip (${flipPct!.abs().toStringAsFixed(2)}% from ZGL)'
                                : regime == GammaRegime.positive
                                    ? slope.description
                                    : '—',
                        color:  gexMultiplier >= 1.0
                            ? AppTheme.profitColor
                            : gexMultiplier >= 0.85
                                ? const Color(0xFFFBBF24)
                                : AppTheme.lossColor,
                      ),
                      const SizedBox(height: 6),
                      // Vm row
                      _MultiplierRow(
                        label:  'Vm  (Vanna multiplier)',
                        value:  '${vannaMultiplier.toStringAsFixed(2)}×',
                        detail: vannaMultiplier < 1.0
                            ? 'Divergence: falling slope + bearish dealer hedge'
                            : vr.label,
                        color:  vannaMultiplier < 1.0
                            ? AppTheme.lossColor
                            : AppTheme.neutralColor,
                      ),
                      Divider(
                          height: 14,
                          color: AppTheme.borderColor.withValues(alpha: 0.4)),
                      // Combined row
                      _MultiplierRow(
                        label:  'Combined  (Gm × Vm)',
                        value:  '${regimeMultiplier.toStringAsFixed(2)}×',
                        detail: regimeMultiplier >= 1.0
                            ? 'Regime amplifies score'
                            : 'Regime suppresses score',
                        color:  regimeMultiplier >= 1.0
                            ? AppTheme.profitColor
                            : regimeMultiplier >= 0.85
                                ? const Color(0xFFFBBF24)
                                : AppTheme.lossColor,
                        bold: true,
                      ),
                      const SizedBox(height: 8),
                      // Direction alignment chip
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color:        alignColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(5),
                          border:       Border.all(
                              color: alignColor.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          alignLabel,
                          style: TextStyle(
                              color: alignColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  final String label;
  const _LoadingRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 14, height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 12)),
      ],
    );
  }
}

class _MultiplierRow extends StatelessWidget {
  final String label;
  final String value;
  final String detail;
  final Color  color;
  final bool   bold;

  const _MultiplierRow({
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: bold ? Colors.white : AppTheme.neutralColor,
                      fontSize: 11,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
              if (detail.isNotEmpty)
                Text(detail,
                    style: const TextStyle(
                        color: AppTheme.neutralColor,
                        fontSize: 10,
                        height: 1.3)),
            ],
          ),
        ),
        Text(value,
            style: TextStyle(
                color:      color,
                fontSize:   bold ? 14 : 12,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace')),
      ],
    );
  }
}
