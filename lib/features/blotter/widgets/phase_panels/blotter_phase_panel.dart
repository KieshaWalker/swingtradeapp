// =============================================================================
// features/blotter/widgets/phase_panels/blotter_phase_panel.dart
// =============================================================================
// Phase 3 of 5 — Blotter (Pricing) Gate
//
// Runs the internal pricing stack (BS → SABR → Heston) on the trade and
// computes portfolio-level risk impact.  Answers four questions:
//
//   1. What is this contract actually worth?     (model fair value)
//   2. Are you getting an edge or paying up?     (edge in bps vs broker mid)
//   3. How much can this lose in a tail event?   (ES₉₅)
//   4. What does this do to the existing book?   (portfolio what-if)
//
// All pricing is synchronous (pure Dart math).  Only the portfolio state load
// (existing committed/sent positions from Supabase) is async — while it loads
// the panel renders trade-level data immediately and fills in book impact once
// the query resolves.
//
// Inputs (from parent's trade form + Schwab contract):
//   spot          — underlying last price
//   strike        — option strike price
//   impliedVol    — decimal (0.21 = 21%); divide Schwab's percentage by 100
//   daysToExpiry  — integer DTE
//   isCall        — true = call, false = put
//   brokerMid     — (bid + ask) / 2
//   delta/gamma/vega — from Schwab contract
//   quantity      — number of contracts
//
// Pass/Warn/Fail:
//   PASS  edgeBps > +5  AND  ES₉₅ < $300  AND  delta within threshold
//   WARN  edgeBps 0..+5  OR  ES₉₅ $300–$700  OR  delta near threshold (>80%)
//   FAIL  edgeBps < 0  OR  delta threshold exceeded  OR  ES₉₅ > $700
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme.dart';
import '../../../../services/iv/iv_models.dart';
import '../../../../services/iv/iv_providers.dart';
import '../../../../services/python_api/python_api_client.dart';
import '../../../vol_surface/providers/sabr_calibration_provider.dart';
import '../../models/blotter_models.dart';
import '../../models/phase_result.dart';
import '../../services/fair_value_engine.dart';

// ── Portfolio state provider ──────────────────────────────────────────────────
// autoDispose so it reloads fresh each time the panel is mounted.

final _portfolioProvider = FutureProvider.autoDispose<PortfolioState>(
    (_) => FairValueEngine.loadPortfolioState());

// ── Panel widget ──────────────────────────────────────────────────────────────

class BlotterPhasePanel extends ConsumerStatefulWidget {
  final String  ticker;
  final double  spot;
  final double  strike;
  /// Pass as decimal — e.g. 0.21 for 21% IV.
  /// If your source is Schwab (percent), divide by 100 before passing.
  final double  impliedVol;
  final int     daysToExpiry;
  final bool    isCall;
  final double  brokerMid;
  final double  delta;
  final double  gamma;
  final double  vega;
  final int     quantity;
  final void Function(PhaseResult)? onResult;

  const BlotterPhasePanel({
    super.key,
    required this.ticker,
    required this.spot,
    required this.strike,
    required this.impliedVol,
    required this.daysToExpiry,
    required this.isCall,
    required this.brokerMid,
    required this.delta,
    required this.gamma,
    required this.vega,
    required this.quantity,
    this.onResult,
  });

  @override
  ConsumerState<BlotterPhasePanel> createState() => _BlotterPhasePanelState();
}

class _BlotterPhasePanelState extends ConsumerState<BlotterPhasePanel> {
  PhaseResult?    _lastResult;
  FairValueResult? _fv;
  String?          _lastFvKey;

  Future<void> _fetchFairValue({double? rho, double? nu}) async {
    try {
      final raw = await PythonApiClient.fairValueCompute(
        spot:          widget.spot,
        strike:        widget.strike,
        impliedVol:    widget.impliedVol,
        daysToExpiry:  widget.daysToExpiry,
        isCall:        widget.isCall,
        brokerMid:     widget.brokerMid,
        calibratedRho: rho,
        calibratedNu:  nu,
      );
      if (mounted) {
        setState(() => _fv = FairValueResult.fromJson(raw) ?? FairValueResult(
          bsFairValue:    widget.brokerMid,
          sabrFairValue:  widget.brokerMid,
          modelFairValue: widget.brokerMid,
          brokerMid:      widget.brokerMid,
          edgeBps:        0,
          sabrVol:        widget.impliedVol,
          impliedVol:     widget.impliedVol,
        ));
      }
    } catch (_) {}
  }

  bool get _hasData =>
      widget.spot > 0 &&
      widget.brokerMid > 0 &&
      widget.daysToExpiry > 0 &&
      widget.impliedVol > 0;

  @override
  Widget build(BuildContext context) {
    if (!_hasData) {
      final r = PhaseResult(
        status: PhaseStatus.warn,
        headline: 'Waiting for pricing data',
        signals: ['Enter spot, mid price, DTE, and IV to evaluate Phase 3.'],
      );
      _notifyIfChanged(r);
      return const _NotReadyTile();
    }

    // ── Surface-calibrated SABR params (non-blocking) ──────────────────────
    final sabrSlice = ref.watch(
        sabrSliceProvider((widget.ticker, widget.daysToExpiry)));

    // ── Async pricing — re-fetch when inputs change ────────────────────────
    final fvKey = '${widget.spot}:${widget.strike}:${widget.impliedVol}:'
        '${widget.daysToExpiry}:${widget.isCall}:${widget.brokerMid}:'
        '${sabrSlice?.rho}:${sabrSlice?.nu}';
    if (fvKey != _lastFvKey) {
      _lastFvKey = fvKey;
      _fv = null;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fetchFairValue(rho: sabrSlice?.rho, nu: sabrSlice?.nu));
    }

    final fv = _fv;
    if (fv == null) return const _NotReadyTile();

    // ── ES₉₅ component decomposition ──────────────────────────────────────
    final T      = widget.daysToExpiry / 365.0;
    final sigma  = widget.impliedVol;
    final sqrtT  = math.sqrt(T);
    final posDelta = widget.delta * widget.quantity * 100;
    final posGamma = widget.gamma * widget.quantity * 100;

    const es95Mult = 2.063; // φ(1.645) / 0.05
    final deltaEs  = posDelta.abs() * widget.spot * sigma * sqrtT * es95Mult;
    final gammaEs  =
        0.5 * posGamma.abs() * widget.spot * widget.spot * sigma * sigma * T * 1.5;

    // Cap ES₉₅ at max loss for a long option = premium paid × 100 shares × lots
    final maxLoss   = widget.brokerMid * widget.quantity * 100;
    final tradeEs95 = (deltaEs + gammaEs).clamp(0.0, maxLoss);

    // ── Portfolio what-if (async portfolio state, fallback to empty) ───────
    final portfolioAsync = ref.watch(_portfolioProvider);
    final portfolio = portfolioAsync.value ?? PortfolioState.empty;

    // ── IV analytics — GEX regime (non-blocking) ───────────────────────────
    final ivAsync = ref.watch(ivAnalysisProvider(widget.ticker));
    final ivAnalysis = ivAsync.valueOrNull;

    final whatIf = FairValueEngine.computeWhatIf(
      current:      portfolio,
      delta:        widget.delta,
      gamma:        widget.gamma,
      vega:         widget.vega,
      spot:         widget.spot,
      quantity:     widget.quantity,
      impliedVol:   widget.impliedVol,
      daysToExpiry: widget.daysToExpiry,
    );

    final result = _computeResult(
      fv:         fv,
      whatIf:     whatIf,
      tradeEs95:  tradeEs95,
      deltaEs:    deltaEs,
      gammaEs:    gammaEs,
      ivAnalysis: ivAnalysis,
    );
    _notifyIfChanged(result);

    return _PanelBody(
      fv:               fv,
      whatIf:           whatIf,
      portfolio:        portfolio,
      portfolioLoading: portfolioAsync.isLoading,
      deltaEs:          deltaEs,
      gammaEs:          gammaEs,
      result:           result,
      spot:             widget.spot,
      impliedVol:       widget.impliedVol,
      daysToExpiry:     widget.daysToExpiry,
      isCall:           widget.isCall,
      ticker:           widget.ticker,
      delta:            widget.delta,
      quantity:         widget.quantity,
      ivAnalysis:       ivAnalysis,
      ivLoading:        ivAsync.isLoading,
    );
  }

  // ── Phase result computation ──────────────────────────────────────────────

  PhaseResult _computeResult({
    required FairValueResult fv,
    required WhatIfResult    whatIf,
    required double          tradeEs95,
    required double          deltaEs,
    required double          gammaEs,
    IvAnalysis?              ivAnalysis,
  }) {
    final edgeBps = fv.edgeBps;
    final isCall  = widget.isCall;

    // ── Regime multipliers — mirror Python option_scoring.py exactly ──────────
    // Gm (GEX multiplier): negative=0.50 FAIL, near-flip=0.70, pos+deep=1.20,
    //   pos+rising=1.10, pos+flat=1.00, pos+falling=0.85
    // Vm (Vanna multiplier): falling slope + bearish vanna = 0.60
    double gexMultiplier   = 1.0;
    double vannaMultiplier = 1.0;
    bool   regimeFail      = false;
    bool   nearFlip        = false;
    String? slopeSignal;
    String? vannaSignal;

    if (ivAnalysis != null) {
      final gr       = ivAnalysis.gammaRegime;
      final slope    = ivAnalysis.gammaSlope;
      final flipPct  = ivAnalysis.spotToZeroGammaPct;
      final totalGex = ivAnalysis.totalGex;
      final vr       = ivAnalysis.vannaRegime;

      if (gr == GammaRegime.negative) {
        regimeFail    = true;
        gexMultiplier = 0.50;
      } else if (flipPct != null && flipPct.abs() <= 0.5) {
        nearFlip      = true;
        gexMultiplier = 0.70;
      } else if (gr == GammaRegime.positive) {
        if (totalGex != null && totalGex >= 1000.0) {
          gexMultiplier = 1.20;
        } else if (slope == GammaSlope.rising) {
          gexMultiplier = 1.10;
        } else if (slope == GammaSlope.falling) {
          gexMultiplier = 0.85;
        }
        slopeSignal = 'Gamma slope ${slope.label}  →  Gm ${gexMultiplier.toStringAsFixed(2)}×';
      }

      final slopeFalling = slope == GammaSlope.falling;
      final vannaBearish = vr == VannaRegime.bearishOnVolCrush ||
                           vr == VannaRegime.bearishOnVolSpike;
      if (slopeFalling && vannaBearish) {
        vannaMultiplier = 0.60;
        vannaSignal = 'Vanna Divergence: declining slope + bearish dealer hedge — '
            'fragile rally; reversal risk elevated  (Vm 0.60×)';
      }
    }

    final regimeMultiplier = gexMultiplier * vannaMultiplier;

    // ── Direction alignment ───────────────────────────────────────────────────
    final gr = ivAnalysis?.gammaRegime ?? GammaRegime.unknown;
    final gexKnown = gr != GammaRegime.unknown;
    final gexMisaligned = gexKnown &&
        ((isCall && gr == GammaRegime.negative) ||
         (!isCall && gr == GammaRegime.positive));

    // ── Hard fails ────────────────────────────────────────────────────────────
    final deltaBreached = whatIf.exceedsDeltaThreshold;
    final es95High      = tradeEs95 > 1500;

    final PhaseStatus status;
    if (deltaBreached || es95High) {
      status = PhaseStatus.fail;
    } else if (edgeBps < 0 ||
               tradeEs95 > 500 ||
               whatIf.newDelta.abs() > whatIf.deltaThreshold * 0.80 ||
               regimeFail ||
               nearFlip ||
               gexMisaligned ||
               vannaMultiplier < 1.0) {
      status = PhaseStatus.warn;
    } else {
      status = PhaseStatus.pass;
    }

    // ── Signals ───────────────────────────────────────────────────────────────
    final signals = <String>[
      '${fv.edgeLabel}  ${edgeBps >= 0 ? '+' : ''}${edgeBps.toStringAsFixed(1)} bps  '
          '(model \$${fv.modelFairValue.toStringAsFixed(3)} vs mid \$${fv.brokerMid.toStringAsFixed(3)})',
      'SABR vol: ${(fv.sabrVol * 100).toStringAsFixed(1)}%  '
          '(market IV: ${(fv.impliedVol * 100).toStringAsFixed(1)}%)',
      'ES₉₅ this trade: \$${tradeEs95.toStringAsFixed(0)}  '
          '(Δ \$${deltaEs.toStringAsFixed(0)} + Γ \$${gammaEs.toStringAsFixed(0)})',
      if (ivAnalysis != null)
        'Regime multiplier: Gm ${gexMultiplier.toStringAsFixed(2)}× · '
        'Vm ${vannaMultiplier.toStringAsFixed(2)}× = ${regimeMultiplier.toStringAsFixed(2)}×'
        '${regimeFail ? " [REGIME FAIL — capped at 35]" : ""}',
      if (fv.vanna != null)
        'Vanna ${fv.vanna!.toStringAsFixed(4)} · '
        'Charm ${fv.charm?.toStringAsFixed(4) ?? '—'} · '
        'Volga ${fv.volga?.toStringAsFixed(4) ?? '—'}',
      if (deltaBreached)
        '⚠ Portfolio delta \$${whatIf.newDelta.toStringAsFixed(0)} '
            'exceeds \$${whatIf.deltaThreshold.toStringAsFixed(0)} threshold',
      if (regimeFail)
        '⚠ REGIME FAIL: Short Gamma — dealers amplify moves; score capped at 35 (Gm 0.50×)',
      if (nearFlip)
        '⚠ Near Zero Gamma flip (${ivAnalysis!.spotToZeroGammaPct!.abs().toStringAsFixed(2)}% from ZGL) — '
            'regime-shift probability elevated (Gm 0.70×)',
      ?slopeSignal,
      if (vannaSignal case final s?) '⚠ $s',
      if (gexMisaligned && !regimeFail)
        '⚠ GEX direction mismatch — ${isCall ? "Negative GEX (Short Gamma) opposes calls; strong buy requires positive GEX" : "Positive GEX (Long Gamma) opposes puts; strong buy requires negative GEX"}',
      if (!gexMisaligned && gexKnown && !regimeFail)
        '✓ GEX aligned — ${isCall ? "Positive GEX (Long Gamma) supports calls" : "Negative GEX (Short Gamma) supports puts"}',
      if (!gexKnown)
        '⚠ GEX regime unavailable — cannot confirm directional alignment',
    ];

    final multiplierTag = ivAnalysis != null
        ? '  ·  ×${regimeMultiplier.toStringAsFixed(2)}'
        : '';
    final headline =
        '${fv.edgeLabel}  '
        '${edgeBps >= 0 ? '+' : ''}${edgeBps.toStringAsFixed(0)} bps  ·  '
        'ES₉₅ \$${tradeEs95.toStringAsFixed(0)}$multiplierTag';

    return PhaseResult(status: status, headline: headline, signals: signals);
  }

  void _notifyIfChanged(PhaseResult result) {
    if (_lastResult == null || _lastResult!.status != result.status) {
      _lastResult = result;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onResult?.call(result);
      });
    }
  }
}

// ── Panel body ────────────────────────────────────────────────────────────────

class _PanelBody extends StatelessWidget {
  final FairValueResult fv;
  final WhatIfResult    whatIf;
  final PortfolioState  portfolio;
  final bool            portfolioLoading;
  final double          deltaEs;
  final double          gammaEs;
  final PhaseResult     result;
  final double          spot;
  final double          impliedVol;
  final int             daysToExpiry;
  final bool            isCall;
  final String          ticker;
  final double          delta;
  final int             quantity;
  final IvAnalysis?     ivAnalysis;
  final bool            ivLoading;

  const _PanelBody({
    required this.fv,
    required this.whatIf,
    required this.portfolio,
    required this.portfolioLoading,
    required this.deltaEs,
    required this.gammaEs,
    required this.result,
    required this.spot,
    required this.impliedVol,
    required this.daysToExpiry,
    required this.isCall,
    required this.ticker,
    required this.delta,
    required this.quantity,
    required this.ivLoading,
    this.ivAnalysis,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Phase header
        _PhaseHeader(result: result),
        const SizedBox(height: 14),

        // 2. Pricing model stack
        _SectionLabel('Pricing Model Stack'),
        const SizedBox(height: 8),
        _PricingStackCard(fv: fv, isCall: isCall, gammaRegime: ivAnalysis?.gammaRegime),
        const SizedBox(height: 16),

        // 3. Second-order Greeks
        if (fv.vanna != null) ...[
          _SectionLabel('Second-Order Greeks'),
          const SizedBox(height: 8),
          _SecondOrderGreeksCard(fv: fv),
          const SizedBox(height: 16),
        ],

        // 4. ES₉₅ breakdown
        _SectionLabel('Expected Shortfall  (ES₉₅)'),
        const SizedBox(height: 8),
        _Es95Card(
          deltaEs:      deltaEs,
          gammaEs:      gammaEs,
          portfolioBefore: portfolio.totalEs95,
          portfolioAfter:  whatIf.newEs95,
          loading:      portfolioLoading,
        ),
        const SizedBox(height: 16),

        // 5. Portfolio what-if
        _SectionLabel('Portfolio Impact'),
        const SizedBox(height: 8),
        _WhatIfCard(
          whatIf:   whatIf,
          loading:  portfolioLoading,
          openPositions: portfolio.openPositions,
        ),
        const SizedBox(height: 16),

        // 6. GEX regime
        _SectionLabel('Systemic GEX  (Gamma Exposure)'),
        const SizedBox(height: 8),
        _GexRegimeCard(
          ivAnalysis: ivAnalysis,
          loading:    ivLoading,
          ticker:     ticker,
          isCall:     isCall,
        ),
        const SizedBox(height: 16),

        // 7. Beta-adjusted notional
        _SectionLabel('Beta-Adjusted Notional'),
        const SizedBox(height: 8),
        _BetaNotionalCard(
          ticker:  ticker,
          spot:    spot,
          delta:   delta,
          quantity: quantity,
        ),
        const SizedBox(height: 16),

      ],
    );
  }
}

// ── Phase header ──────────────────────────────────────────────────────────────

class _PhaseHeader extends StatelessWidget {
  final PhaseResult result;
  const _PhaseHeader({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.status.color;
    return Row(
      children: [
        Icon(result.status.icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            result.headline,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:        color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(
            result.status.label.toUpperCase(),
            style: TextStyle(
                color: color, fontSize: 10,
                fontWeight: FontWeight.w800, letterSpacing: 0.8),
          ),
        ),
      ],
    );
  }
}

// ── Pricing model stack card ──────────────────────────────────────────────────

class _PricingStackCard extends StatelessWidget {
  final FairValueResult fv;
  final bool            isCall;
  final GammaRegime?    gammaRegime;
  const _PricingStackCard({required this.fv, required this.isCall, this.gammaRegime});

  @override
  Widget build(BuildContext context) {
    final sabrDelta  = fv.sabrFairValue - fv.bsFairValue;
    final hestonDelta = fv.modelFairValue - fv.sabrFairValue;

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          // Black-Scholes
          _PricingRow(
            label:    'Black-Scholes',
            sublabel: 'Baseline — constant vol, log-normal',
            value:    '\$${fv.bsFairValue.toStringAsFixed(3)}',
            delta:    null,
            color:    AppTheme.neutralColor,
            isFirst:  true,
          ),
          // SABR
          _PricingRow(
            label:    'SABR',
            sublabel: 'Smile/skew adjusted  '
                '(β=0.5, ρ=−0.7, ν=0.40)  '
                'σ_SABR=${(fv.sabrVol * 100).toStringAsFixed(1)}%',
            value:    '\$${fv.sabrFairValue.toStringAsFixed(3)}',
            delta:    sabrDelta,
            color:    sabrDelta >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          // Heston
          _PricingRow(
            label:    'Model  (SABR + Heston)',
            sublabel: 'Stochastic vol correction  (κ=2.0, ξ=0.5, ρ=−0.7)',
            value:    '\$${fv.modelFairValue.toStringAsFixed(3)}',
            delta:    hestonDelta,
            color:    hestonDelta >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          // Divider
          Divider(
            height: 1,
            color: AppTheme.borderColor.withValues(alpha: 0.6),
          ),
          // Broker mid
          _PricingRow(
            label:    'Broker Mid',
            sublabel: 'What you actually pay',
            value:    '\$${fv.brokerMid.toStringAsFixed(3)}',
            delta:    null,
            color:    AppTheme.neutralColor,
          ),
          // Edge banner
          _EdgeBanner(fv: fv, isCall: isCall, gammaRegime: gammaRegime),
        ],
      ),
    );
  }
}

class _PricingRow extends StatelessWidget {
  final String  label;
  final String  sublabel;
  final String  value;
  final double? delta;   // diff from previous layer; null = first row
  final Color   color;
  final bool    isFirst;
  const _PricingRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.delta,
    required this.color,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sublabel,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 10)),
              ],
            ),
          ),
          if (delta != null) ...[
            Text(
              '${delta! >= 0 ? '+' : ''}\$${delta!.toStringAsFixed(3)}',
              style: TextStyle(color: color, fontSize: 11),
            ),
            const SizedBox(width: 8),
          ],
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _EdgeBanner extends StatelessWidget {
  final FairValueResult fv;
  final bool            isCall;
  final GammaRegime?    gammaRegime;
  const _EdgeBanner({required this.fv, required this.isCall, this.gammaRegime});

  @override
  Widget build(BuildContext context) {
    final color = fv.edgeColor;
    final edgeBps = fv.edgeBps;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(10)),
        border:       Border(top: BorderSide(
            color: color.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: [
          Icon(
            edgeBps > 0
                ? Icons.arrow_upward_rounded
                : edgeBps < 0
                    ? Icons.arrow_downward_rounded
                    : Icons.remove_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            fv.edgeLabel,
            style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5),
          ),
          const SizedBox(width: 10),
          Text(
            '${edgeBps >= 0 ? '+' : ''}${edgeBps.toStringAsFixed(1)} bps',
            style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Text(
            _edgeInterpretation(edgeBps, isCall: isCall, gammaRegime: gammaRegime),
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ── Second-order Greeks card ──────────────────────────────────────────────────

class _SecondOrderGreeksCard extends StatelessWidget {
  final FairValueResult fv;
  const _SecondOrderGreeksCard({required this.fv});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          if (fv.vanna != null)
            _GreekRow(
              symbol: 'Vanna',
              formula: '∂²V/∂S∂σ',
              value: fv.vanna!.toStringAsFixed(5),
              interpretation: _vannaInterpretation(fv.vanna!),
              color: fv.vanna! < 0
                  ? AppTheme.lossColor
                  : AppTheme.profitColor,
              isFirst: true,
            ),
          if (fv.charm != null)
            _GreekRow(
              symbol: 'Charm',
              formula: '∂Δ/∂T',
              value: fv.charm!.toStringAsFixed(5),
              interpretation: _charmInterpretation(fv.charm!),
              color: AppTheme.neutralColor,
            ),
          if (fv.volga != null)
            _GreekRow(
              symbol: 'Volga',
              formula: '∂²V/∂σ²',
              value: fv.volga!.toStringAsFixed(5),
              interpretation: _volgaInterpretation(fv.volga!),
              color: fv.volga! > 0
                  ? AppTheme.profitColor
                  : AppTheme.lossColor,
            ),
        ],
      ),
    );
  }
}

class _GreekRow extends StatelessWidget {
  final String symbol;
  final String formula;
  final String value;
  final String interpretation;
  final Color  color;
  final bool   isFirst;
  const _GreekRow({
    required this.symbol,
    required this.formula,
    required this.value,
    required this.interpretation,
    required this.color,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!isFirst) Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.5)),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(symbol,
                        style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                    Text(formula,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 10)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 80,
                child: Text(value,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace')),
              ),
              Expanded(
                child: Text(interpretation,
                    style: const TextStyle(
                        color: AppTheme.neutralColor,
                        fontSize: 11,
                        height: 1.4)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── ES₉₅ card ────────────────────────────────────────────────────────────────

class _Es95Card extends StatelessWidget {
  final double deltaEs;
  final double gammaEs;
  final double portfolioBefore;
  final double portfolioAfter;
  final bool   loading;
  const _Es95Card({
    required this.deltaEs,
    required this.gammaEs,
    required this.portfolioBefore,
    required this.portfolioAfter,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final total     = deltaEs + gammaEs;
    final riskColor = _es95RiskColor(total);
    final riskLabel = _es95RiskLabel(total);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // This trade's ES₉₅
          Row(
            children: [
              const Text('This trade',
                  style: TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 12)),
              const Spacer(),
              Text(
                '\$${total.toStringAsFixed(0)}',
                style: TextStyle(
                    color: riskColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color:        riskColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:       Border.all(color: riskColor.withValues(alpha: 0.4)),
                ),
                child: Text(riskLabel,
                    style: TextStyle(
                        color: riskColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Component breakdown
          Row(
            children: [
              _Es95Component(
                label: 'Delta (linear)',
                value: '\$${deltaEs.toStringAsFixed(0)}',
                detail: '|Δ|×S×σ×√T×2.063',
                pct: total > 0 ? deltaEs / total : 0,
                color: AppTheme.neutralColor,
              ),
              const SizedBox(width: 8),
              _Es95Component(
                label: 'Gamma (convexity)',
                value: '\$${gammaEs.toStringAsFixed(0)}',
                detail: '½|Γ|×S²×σ²×T×1.5',
                pct: total > 0 ? gammaEs / total : 0,
                color: const Color(0xFFFBBF24),
              ),
            ],
          ),

          // Portfolio impact (async)
          if (!loading) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Portfolio',
                    style: TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12)),
                const Spacer(),
                Text(
                  '\$${portfolioBefore.toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward_rounded,
                      size: 13, color: AppTheme.neutralColor),
                ),
                Text(
                  '\$${portfolioAfter.toStringAsFixed(0)}',
                  style: TextStyle(
                      color: _es95RiskColor(portfolioAfter),
                      fontSize: 14,
                      fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 12),
            const _LoadingRow(label: 'Loading portfolio ES₉₅…'),
          ],
        ],
      ),
    );
  }
}

class _Es95Component extends StatelessWidget {
  final String label;
  final String value;
  final String detail;
  final double pct;
  final Color  color;
  const _Es95Component({
    required this.label,
    required this.value,
    required this.detail,
    required this.pct,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(
              color: AppTheme.borderColor.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value:           pct.clamp(0.0, 1.0),
                minHeight:       3,
                backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                valueColor:      AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 3),
            Text(detail,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 9,
                    fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }
}

// ── Portfolio what-if card ────────────────────────────────────────────────────

class _WhatIfCard extends StatelessWidget {
  final WhatIfResult whatIf;
  final bool         loading;
  final int          openPositions;
  const _WhatIfCard({
    required this.whatIf,
    required this.loading,
    required this.openPositions,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: AppTheme.borderColor),
        ),
        child: const _LoadingRow(label: 'Loading portfolio positions…'),
      );
    }

    final deltaBeforeAbs = (whatIf.newDelta - whatIf.deltaImpact).abs();
    final deltaAfterAbs  = whatIf.newDelta.abs();
    final threshold      = whatIf.deltaThreshold;
    final deltaBreached  = whatIf.exceedsDeltaThreshold;
    final deltaWarnColor = deltaBreached
        ? AppTheme.lossColor
        : deltaAfterAbs > threshold * 0.80
            ? const Color(0xFFFBBF24)
            : AppTheme.profitColor;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(
            color: deltaBreached
                ? AppTheme.lossColor.withValues(alpha: 0.4)
                : AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Open positions caption
          Text(
            '$openPositions committed position${openPositions == 1 ? '' : 's'} in book',
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
          const SizedBox(height: 12),

          // Delta row
          _WhatIfRow(
            icon:   Icons.trending_flat_rounded,
            label:  'Portfolio Δ',
            before: _fmtDollar(deltaBeforeAbs),
            after:  _fmtDollar(deltaAfterAbs),
            impact: '${whatIf.deltaImpact >= 0 ? '+' : ''}\$${whatIf.deltaImpact.toStringAsFixed(0)}',
            color:  deltaWarnColor,
            detail: 'Limit: \$${threshold.toStringAsFixed(0)}',
          ),
          const SizedBox(height: 6),

          // Delta bar
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value:           (deltaAfterAbs / threshold).clamp(0.0, 1.0),
                  minHeight:       5,
                  backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                  valueColor:      AlwaysStoppedAnimation(deltaWarnColor),
                ),
              ),
              if (deltaBreached)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Delta threshold exceeded — reduce size or hedge before committing',
                    style: TextStyle(
                        color: AppTheme.lossColor, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Vega row
          _WhatIfRow(
            icon:   Icons.waves_rounded,
            label:  'Portfolio ν',
            before: _fmtDollar((whatIf.newVega - whatIf.vegaImpact).abs()),
            after:  _fmtDollar(whatIf.newVega.abs()),
            impact: '${whatIf.vegaImpact >= 0 ? '+' : ''}\$${whatIf.vegaImpact.toStringAsFixed(0)}',
            color:  AppTheme.neutralColor,
            detail: 'IV exposure',
          ),
          const SizedBox(height: 6),

          // ES₉₅ row
          _WhatIfRow(
            icon:   Icons.shield_outlined,
            label:  'Portfolio ES₉₅',
            before: _fmtDollar(portfolioEs95Before(whatIf)),
            after:  _fmtDollar(whatIf.newEs95),
            impact: '+\$${whatIf.es95Impact.toStringAsFixed(0)}',
            color:  _es95RiskColor(whatIf.newEs95),
            detail: _es95RiskLabel(whatIf.newEs95),
          ),
        ],
      ),
    );
  }

  static double portfolioEs95Before(WhatIfResult w) =>
      w.newEs95 - w.es95Impact;
}

class _WhatIfRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   before;
  final String   after;
  final String   impact;
  final Color    color;
  final String   detail;
  const _WhatIfRow({
    required this.icon,
    required this.label,
    required this.before,
    required this.after,
    required this.impact,
    required this.color,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: AppTheme.neutralColor),
        const SizedBox(width: 6),
        SizedBox(
          width: 90,
          child: Text(label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 12)),
        ),
        Text(before,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 12)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 5),
          child: Icon(Icons.arrow_forward_rounded,
              size: 11, color: AppTheme.neutralColor),
        ),
        Text(after,
            style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('($impact)',
            style: TextStyle(color: color, fontSize: 11)),
        const Spacer(),
        Text(detail,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 10)),
      ],
    );
  }
}

// ── Loading row ───────────────────────────────────────────────────────────────

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

// ── Not-ready / loading ───────────────────────────────────────────────────────

class _NotReadyTile extends StatelessWidget {
  const _NotReadyTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: const Row(
        children: [
          Icon(Icons.calculate_outlined, size: 16, color: AppTheme.neutralColor),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Enter spot price, strike, expiry, and IV to run '
              'the pricing model.',
              style: TextStyle(
                  color: AppTheme.neutralColor, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── GEX regime card ───────────────────────────────────────────────────────────

class _GexRegimeCard extends StatelessWidget {
  final IvAnalysis? ivAnalysis;
  final bool        loading;
  final String      ticker;
  final bool        isCall;

  const _GexRegimeCard({
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

    // ── Regime multipliers — mirror Python option_scoring.py ─────────────────
    double gexMultiplier   = 1.0;
    double vannaMultiplier = 1.0;
    bool   regimeFail      = false;
    bool   nearFlip        = false;

    if (ivAnalysis != null) {
      if (regime == GammaRegime.negative) {
        regimeFail    = true;
        gexMultiplier = 0.50;
      } else if (flipPct != null && flipPct.abs() <= 0.5) {
        nearFlip      = true;
        gexMultiplier = 0.70;
      } else if (regime == GammaRegime.positive) {
        if (totalGex != null && totalGex >= 1000.0) {
          gexMultiplier = 1.20;
        } else if (slope == GammaSlope.rising) {
          gexMultiplier = 1.10;
        } else if (slope == GammaSlope.falling) {
          gexMultiplier = 0.85;
        }
      }

      final slopeFalling = slope == GammaSlope.falling;
      final vannaBearish = vr == VannaRegime.bearishOnVolCrush ||
                           vr == VannaRegime.bearishOnVolSpike;
      if (slopeFalling && vannaBearish) vannaMultiplier = 0.60;
    }

    final regimeMultiplier = gexMultiplier * vannaMultiplier;
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

// ── Multiplier row (used inside _GexRegimeCard) ───────────────────────────────

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

// ── Beta-adjusted notional card ───────────────────────────────────────────────

class _BetaNotionalCard extends StatelessWidget {
  final String ticker;
  final double spot;
  final double delta;    // per-contract delta (e.g. 0.42)
  final int    quantity;

  const _BetaNotionalCard({
    required this.ticker,
    required this.spot,
    required this.delta,
    required this.quantity,
  });

  // Static beta table — update periodically.
  // Source: 2-year rolling regression vs SPY, as of early 2026.
  static double _betaFor(String t) {
    const betas = {
      // Broad index (β≈1 by definition)
      'SPY': 1.00, 'SPX': 1.00, 'IWM': 1.10, 'DIA': 0.95, 'MDY': 1.05,
      // Tech — high β
      'NVDA': 1.85, 'AMD': 1.90, 'TSLA': 1.75, 'META': 1.45, 'AAPL': 1.20,
      'MSFT': 1.15, 'GOOGL': 1.20, 'GOOG': 1.20, 'AMZN': 1.35,
      'AVGO': 1.50, 'MU': 1.80, 'AMAT': 1.65, 'LRCX': 1.60, 'KLAC': 1.55,
      'QCOM': 1.30, 'INTC': 1.25, 'CRM': 1.30, 'ADBE': 1.25,
      'QQQ': 1.15, 'XLK': 1.15, 'SMH': 1.60, 'SOXX': 1.60,
      // Financials — moderate/high β
      'JPM': 1.15, 'BAC': 1.30, 'GS': 1.40, 'MS': 1.35, 'C': 1.30,
      'WFC': 1.20, 'BX': 1.35, 'KKR': 1.30,
      // Consumer discretionary
      'NKE': 1.05, 'SBUX': 0.90, 'HD': 0.95, 'TGT': 1.00, 'LULU': 1.30,
      // Consumer staples — low β
      'WMT': 0.55, 'COST': 0.65, 'MCD': 0.65,
      // Energy
      'XOM': 0.85, 'CVX': 0.80, 'OXY': 1.40, 'COP': 1.10, 'XLE': 1.05,
      // Utilities / REITs — low β
      'XLU': 0.35, 'O': 0.50, 'AMT': 0.60,
      // Vol products
      'VXX': -4.00, 'UVXY': -7.00, 'SVXY': 3.50, 'VIXY': -4.20,
    };
    return betas[t.toUpperCase()] ?? 1.00;
  }

  @override
  Widget build(BuildContext context) {
    final beta        = _betaFor(ticker);
    final deltaDollar = delta.abs() * spot * quantity * 100;
    final betaAdj     = deltaDollar * beta;

    // Thresholds for context
    final Color adjColor;
    final String adjLabel;
    if (betaAdj < 5000) {
      adjColor = AppTheme.profitColor;
      adjLabel = 'LOW — minimal correlated SPY exposure';
    } else if (betaAdj < 15000) {
      adjColor = const Color(0xFF60A5FA);
      adjLabel = 'MODERATE — notable SPY correlation';
    } else if (betaAdj < 30000) {
      adjColor = const Color(0xFFFBBF24);
      adjLabel = 'ELEVATED — meaningful book beta risk';
    } else {
      adjColor = AppTheme.lossColor;
      adjLabel = 'HIGH — concentrated correlated exposure';
    }

    final betaIsHigh = beta.abs() > 1.5;
    final betaColor  = betaIsHigh ? const Color(0xFFFBBF24) : AppTheme.neutralColor;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          // Row 1: raw notional
          _NotionalRow(
            label:  'Option Δ Notional',
            value:  '\$${_fmtK(deltaDollar)}',
            detail: '|Δ| ${delta.abs().toStringAsFixed(2)} × \$${spot.toStringAsFixed(0)} × $quantity contracts × 100',
            color:  AppTheme.neutralColor,
          ),
          const SizedBox(height: 8),
          // Row 2: beta
          _NotionalRow(
            label:  'Beta  ($ticker vs SPY)',
            value:  beta >= 0
                ? '+${beta.toStringAsFixed(2)}'
                : beta.toStringAsFixed(2),
            detail: betaIsHigh
                ? 'High beta — moves ${beta.toStringAsFixed(1)}× SPY on average'
                : 'Moderate beta — reasonable SPY correlation',
            color:  betaColor,
          ),
          Divider(height: 18, color: AppTheme.borderColor.withValues(alpha: 0.5)),
          // Row 3: beta-adjusted
          _NotionalRow(
            label:  'Beta-Adjusted Notional',
            value:  '\$${_fmtK(betaAdj)}',
            detail: adjLabel,
            color:  adjColor,
            large:  true,
          ),
          const SizedBox(height: 10),
          Text(
            'This is your effective SPY-equivalent exposure. '
            'A \$${_fmtK(betaAdj)} beta-adjusted position moves the same '
            'as holding \$${_fmtK(betaAdj)} of SPY when the market moves.',
            style: const TextStyle(
                color: Colors.white38, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }

  static String _fmtK(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}

class _NotionalRow extends StatelessWidget {
  final String label;
  final String value;
  final String detail;
  final Color  color;
  final bool   large;
  const _NotionalRow({
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11)),
              const SizedBox(height: 2),
              Text(detail,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10, height: 1.3)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: TextStyle(
              color:      color,
              fontSize:   large ? 18 : 14,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace'),
        ),
      ],
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          color:         AppTheme.neutralColor,
          fontSize:      10,
          fontWeight:    FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

// =============================================================================
// Helper functions
// =============================================================================

String _edgeInterpretation(double bps, {bool isCall = true, GammaRegime? gammaRegime}) {
  if (bps > 20) {
    final callAligned = isCall  && gammaRegime == GammaRegime.positive;
    final putAligned  = !isCall && gammaRegime == GammaRegime.negative;
    if (callAligned) return 'Strong buy — pricing edge + positive GEX supports call';
    if (putAligned)  return 'Strong buy — pricing edge + negative GEX supports put';
    if (gammaRegime == null || gammaRegime == GammaRegime.unknown) {
      return 'Pricing edge — GEX regime unknown, cannot confirm direction';
    }
    return isCall
        ? 'Pricing edge — GEX headwind (negative GEX opposes calls)'
        : 'Pricing edge — GEX headwind (positive GEX opposes puts)';
  }
  if (bps > 5)    return 'Model above mid — you have a pricing edge';
  if (bps > -5)   return 'Fairly priced — no systematic edge';
  if (bps > -20)  return 'Model below mid — paying above fair value';
  return 'Model well below mid — strongly overpriced';
}

String _vannaInterpretation(double vanna) {
  final abs = vanna.abs();
  final dir = vanna < 0
      ? 'Delta falls when IV drops (double pain on crush)'
      : 'Delta rises when IV rises (double benefit on vol pop)';
  if (abs < 0.01) return 'Low Vanna — minimal delta/vol interaction. $dir';
  if (abs < 0.05) return 'Moderate Vanna — $dir';
  return 'High Vanna — hedge delta aggressively when IV moves. $dir';
}

String _charmInterpretation(double charm) {
  final perDay = charm.abs();
  if (perDay < 0.001) return 'Low Charm — delta stable over time';
  if (perDay < 0.005) return 'Moderate Charm — delta erodes ~${(perDay * 1000).toStringAsFixed(1)}‰/day from time alone';
  return 'High Charm — delta decaying rapidly. Daily rebalancing needed';
}

String _volgaInterpretation(double volga) {
  if (volga > 0.01)  return 'Positive Volga — long vol convexity. Benefits from large IV moves in either direction';
  if (volga > 0)     return 'Small positive Volga — slight convexity benefit';
  if (volga > -0.01) return 'Small negative Volga — slight concavity risk';
  return 'Negative Volga — short vol convexity. Hurt by large IV moves';
}

Color _es95RiskColor(double es95) {
  if (es95 < 100) return AppTheme.profitColor;
  if (es95 < 300) return const Color(0xFF60A5FA);
  if (es95 < 700) return const Color(0xFFFBBF24);
  return AppTheme.lossColor;
}

String _es95RiskLabel(double es95) {
  if (es95 < 100) return 'LOW';
  if (es95 < 300) return 'MODERATE';
  if (es95 < 700) return 'ELEVATED';
  return 'HIGH';
}

String _fmtDollar(double v) => '\$${v.toStringAsFixed(0)}';
