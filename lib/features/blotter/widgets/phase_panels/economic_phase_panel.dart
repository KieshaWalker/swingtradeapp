// =============================================================================
// features/blotter/widgets/phase_panels/economic_phase_panel.dart
// =============================================================================
// Phase 1 of 5 — Economic Gate
//
// Answers three questions before the trade is evaluated further:
//   1. VIX level   → are options cheap or expensive? (buy vs sell premium)
//   2. Macro regime → does the broad market support calls or puts?
//   3. Sector overlay → does the ticker's underlying economy confirm or fight?
//
// Providers consumed (all already cached — no wasted network calls):
//   macroScoreProvider      — composite regime score + sub-components
//   fredVixProvider         — VIXCLS daily history
//   fredSpreadProvider      — T10Y2Y yield curve spread
//   fredFedFundsProvider    — DFF fed funds rate
//   blsEmploymentProvider   — U3 unemployment + avg hourly earnings
//   eiaCrudeStocksProvider  — crude oil inventory (oil-sector tickers only)
//   eiaCrudeProdProvider    — crude oil production (oil-sector tickers only)
//   eiaRefineryUtilProvider — refinery utilization (oil-sector tickers only)
//
// Emits PhaseResult via [onResult] whenever the computed status changes.
// The parent (FivePhaseBlotterScreen) uses this to gate lifecycle transitions.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme.dart';
import '../../../../services/macro/macro_score_model.dart';
import '../../../../services/macro/macro_score_provider.dart';
import '../../../../services/fred/fred_providers.dart';
import '../../../../services/bls/bls_models.dart';
import '../../../economy/providers/api_data_providers.dart';
import '../../../macro/macro_score_screen.dart';
import '../../models/blotter_models.dart';
import '../../models/phase_result.dart';

// ── Sector classification ─────────────────────────────────────────────────────

enum _Sector { oil, ratesSensitive, consumer, tech, broadIndex, other }

_Sector _classifyTicker(String ticker) {
  final t = ticker.toUpperCase();
  const oil = {
    'XOM',  'CVX',  'OXY',  'COP',  'SLB',  'HAL',  'USO',  'XLE',
    'UCO',  'OIH',  'DVN',  'MRO',  'VLO',  'PSX',  'MPC',  'FANG',
    'EOG',  'HES',  'PXD',  'APA',  'BKR',  'NOV',  'PDCE', 'SM',
  };
  const rates = {
    'JPM',  'BAC',  'GS',   'MS',   'WFC',  'C',    'USB',  'PNC',
    'TFC',  'BRK',  'BRKB', 'KRE',  'XLF',  'TLT',  'IEF',  'SHY',
    'XLU',  'O',    'AMT',  'SCHW', 'BX',   'KKR',  'AGNC', 'NLY',
  };
  const consumer = {
    'AMZN', 'WMT',  'TGT',  'COST', 'HD',   'LOW',  'XRT',  'XLP',
    'XLY',  'MCD',  'SBUX', 'NKE',  'TJX',  'ROST', 'DG',   'DLTR',
    'BBY',  'GME',  'DKS',  'LULU',
  };
  const tech = {
    'AAPL', 'MSFT', 'GOOGL','GOOG', 'META', 'NVDA', 'AMD',  'TSM',
    'AVGO', 'ORCL', 'CRM',  'ADBE', 'QCOM', 'QQQ',  'XLK',  'SMH',
    'SOXX', 'INTC', 'MU',   'AMAT', 'LRCX', 'KLAC', 'SNPS', 'CDNS',
  };
  const index = {
    'SPY',  'SPX',  'IWM',  'DIA',  'MDY',  'VXX',  'VIXY', 'UVXY', 'SVXY',
  };

  if (oil.contains(t))      return _Sector.oil;
  if (rates.contains(t))    return _Sector.ratesSensitive;
  if (consumer.contains(t)) return _Sector.consumer;
  if (tech.contains(t))     return _Sector.tech;
  if (index.contains(t))    return _Sector.broadIndex;
  return _Sector.other;
}

// ── Computed data holder ──────────────────────────────────────────────────────

class _EcoData {
  final MacroScore?   macro;
  final double?       vixNow;
  final double?       vixPrev;
  final double?       yieldNow;
  final double?       fedNow;
  final double?       fedSixMo;
  final double?       u3Now;
  final double?       u3Prev;
  final _Sector       sector;
  final String        ticker;
  final ContractType  contractType;
  // Oil overlay
  final double?       crudeNow;
  final double?       crudeAvg;
  final double?       crudeProdNow;
  final double?       crudeProdPrev;
  final double?       refineryNow;

  const _EcoData({
    required this.macro,
    required this.vixNow,
    required this.vixPrev,
    required this.yieldNow,
    required this.fedNow,
    required this.fedSixMo,
    required this.u3Now,
    required this.u3Prev,
    required this.sector,
    required this.ticker,
    required this.contractType,
    this.crudeNow,
    this.crudeAvg,
    this.crudeProdNow,
    this.crudeProdPrev,
    this.refineryNow,
  });
}

// ── Panel widget ──────────────────────────────────────────────────────────────

class EconomicPhasePanel extends ConsumerStatefulWidget {
  final String       ticker;
  final ContractType contractType;

  /// Called whenever the computed [PhaseResult] status changes.
  final void Function(PhaseResult)? onResult;

  const EconomicPhasePanel({
    super.key,
    required this.ticker,
    required this.contractType,
    this.onResult,
  });

  @override
  ConsumerState<EconomicPhasePanel> createState() => _EconomicPhasePanelState();
}

class _EconomicPhasePanelState extends ConsumerState<EconomicPhasePanel> {
  PhaseResult? _lastResult;

  @override
  Widget build(BuildContext context) {
    // Watch all providers — they are Riverpod-cached; no extra network calls.
    final macroAsync        = ref.watch(macroScoreProvider);
    final vixAsync          = ref.watch(fredVixProvider);
    final spreadAsync       = ref.watch(fredSpreadProvider);
    final fedAsync          = ref.watch(fredFedFundsProvider);
    final blsAsync          = ref.watch(blsEmploymentProvider);
    final crudeStocksAsync  = ref.watch(eiaCrudeStocksProvider);
    final crudeProdAsync    = ref.watch(eiaCrudeProdProvider);
    final refineryAsync     = ref.watch(eiaRefineryUtilProvider);

    final sector = _classifyTicker(widget.ticker);

    // Show skeleton while the two core providers load.
    if (macroAsync.isLoading || vixAsync.isLoading) {
      return const _LoadingSkeleton();
    }
    if (macroAsync.hasError) {
      return _ErrorTile(message: '${macroAsync.error}');
    }

    // ── Unwrap values ─────────────────────────────────────────────────────────

    final macro     = macroAsync.value;
    final vixObs    = vixAsync.value?.observations ?? [];
    final spreadObs = spreadAsync.value?.observations ?? [];
    final fedObs    = fedAsync.value?.observations ?? [];
    final blsData   = blsAsync.value;

    // VIX (FRED observations are chronological — last = most recent)
    final vixNow  = vixObs.isNotEmpty ? vixObs.last.value : null;
    final vixPrev = vixObs.length >= 2 ? vixObs[vixObs.length - 2].value : null;

    // 2s10s yield curve spread
    final yieldNow = spreadObs.isNotEmpty ? spreadObs.last.value : null;

    // Fed funds trajectory — compare latest to ~6 months ago (≈130 daily obs)
    final fedNow   = fedObs.isNotEmpty ? fedObs.last.value : null;
    final fedSixMo = fedObs.length >= 130
        ? fedObs[fedObs.length - 130].value
        : null;

    // U3 unemployment (series LNS14000000 inside blsEmploymentProvider)
    final u3Series = blsData?.series
        .where((s) => s.seriesId == BlsSeriesIds.unemploymentRateU3)
        .firstOrNull;
    final u3Now  = u3Series?.latest?.value;
    final u3Prev = (u3Series?.data.length ?? 0) > 1
        ? u3Series!.data[1].value
        : null;

    // Oil overlay (crude stocks in thousands of barrels)
    final crudeData    = crudeStocksAsync.value?.data ?? [];
    final crudeNow     = crudeData.isNotEmpty ? crudeData.first.value : null;
    final validCrude   = crudeData.where((d) => d.value != null).take(52).toList();
    final crudeAvg     = validCrude.isNotEmpty
        ? validCrude.fold<double>(0, (s, d) => s + d.value!) / validCrude.length
        : null;
    final prodData     = crudeProdAsync.value?.data ?? [];
    final crudeProdNow  = prodData.isNotEmpty ? prodData.first.value : null;
    final crudeProdPrev = prodData.length >= 2 ? prodData[1].value : null;
    final refineryNow  = refineryAsync.value?.latest?.value;

    // ── Assemble data bag ─────────────────────────────────────────────────────

    final d = _EcoData(
      macro:        macro,
      vixNow:       vixNow,
      vixPrev:      vixPrev,
      yieldNow:     yieldNow,
      fedNow:       fedNow,
      fedSixMo:     fedSixMo,
      u3Now:        u3Now,
      u3Prev:       u3Prev,
      sector:       sector,
      ticker:       widget.ticker,
      contractType: widget.contractType,
      crudeNow:     crudeNow,
      crudeAvg:     crudeAvg,
      crudeProdNow:  crudeProdNow,
      crudeProdPrev: crudeProdPrev,
      refineryNow:  refineryNow,
    );

    final result = _computeResult(d);
    _notifyIfChanged(result);

    return _PanelBody(d: d, result: result);
  }

  // ── Result computation ────────────────────────────────────────────────────

  PhaseResult _computeResult(_EcoData d) {
    final regime  = d.macro?.regime ?? MacroRegime.neutral;
    final score   = d.macro?.total ?? 50.0;
    final isCall  = d.contractType == ContractType.call;

    // Directional contradiction — trade direction opposes macro regime
    bool contradiction = false;
    if (isCall  && (regime == MacroRegime.crisis || regime == MacroRegime.caution)) {
      contradiction = true;
    }
    if (!isCall && regime == MacroRegime.riskOn) {
      contradiction = true;
    }

    // Oil-specific contradiction — calling calls when crude is in surplus
    bool oilBearish = false;
    if (d.sector == _Sector.oil &&
        d.crudeNow != null &&
        d.crudeAvg != null) {
      oilBearish = d.crudeNow! > d.crudeAvg! * 1.02; // >2% above 1-yr avg
      if (isCall && oilBearish) contradiction = true;
    }

    // Gate: score < 35 or explicit contradiction → FAIL
    // Gate: score < 55 or caution regime → WARN
    final PhaseStatus status;
    if (score < 35 || contradiction) {
      status = PhaseStatus.fail;
    } else if (score < 55 || regime == MacroRegime.caution) {
      status = PhaseStatus.warn;
    } else {
      status = PhaseStatus.pass;
    }

    // Build signal bullets
    final signals = <String>[
      if (d.vixNow != null)
        'VIX ${d.vixNow!.toStringAsFixed(1)} — ${_vixLabel(d.vixNow!)}',
      'Macro Score: ${score.toStringAsFixed(0)} — ${regime.label}',
      if (d.yieldNow != null)
        'Yield curve (2s10s): ${d.yieldNow!.toStringAsFixed(2)} — ${_yieldLabel(d.yieldNow!)}',
      if (d.u3Now != null)
        'Unemployment (U3): ${_u3Label(d.u3Now!, d.u3Prev)}',
      if (d.fedNow != null)
        'Fed Funds: ${_fedDetail(d.fedNow!, d.fedSixMo)}',
      if (d.sector == _Sector.oil && d.crudeNow != null)
        'Crude stocks: ${_fmtMbbl(d.crudeNow!)} — ${oilBearish ? "Surplus (bearish)" : "Tightening (bullish)"}',
    ];

    final vixTag = d.vixNow != null
        ? '  ·  VIX ${d.vixNow!.toStringAsFixed(1)}'
        : '';
    final headline = contradiction
        ? (isCall
            ? 'Macro headwinds — regime opposes calls'
            : 'Risk-On regime — regime opposes puts')
        : '${regime.label} (${score.toStringAsFixed(0)}/100)$vixTag';

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
  final _EcoData    d;
  final PhaseResult result;
  const _PanelBody({required this.d, required this.result});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Phase header
        _PhaseHeader(result: result),
        const SizedBox(height: 14),

        // 2. VIX strip
        if (d.vixNow != null) ...[
          _VixStrip(vixNow: d.vixNow!, vixPrev: d.vixPrev),
          const SizedBox(height: 12),
        ],

        // 3. Macro regime card
        _MacroRegimeCard(d: d),
        const SizedBox(height: 16),

        // 4. Supporting indicators
        _SectionLabel('Supporting Indicators'),
        const SizedBox(height: 8),
        _SupportingTable(d: d),

        // 5. Sector overlay
        if (d.sector == _Sector.oil) ...[
          const SizedBox(height: 16),
          _SectionLabel('Oil Sector Overlay'),
          const SizedBox(height: 8),
          _OilOverlay(d: d),
        ] else if (d.sector != _Sector.other) ...[
          const SizedBox(height: 16),
          _SectorNote(d: d),
        ],

        // 6. Deep link
        const SizedBox(height: 16),
        _DeepLinkButton(),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ── Phase header (status badge + headline) ────────────────────────────────────

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
              color:      color,
              fontSize:   13,
              fontWeight: FontWeight.w700,
            ),
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
              color:      color,
              fontSize:   10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }
}

// ── VIX strip ─────────────────────────────────────────────────────────────────

class _VixStrip extends StatelessWidget {
  final double  vixNow;
  final double? vixPrev;
  const _VixStrip({required this.vixNow, required this.vixPrev});

  @override
  Widget build(BuildContext context) {
    final color    = _vixColor(vixNow);
    final isUp     = vixPrev != null && vixNow > vixPrev!;
    final isDown   = vixPrev != null && vixNow < vixPrev!;
    final arrow    = isUp ? '↑' : isDown ? '↓' : '→';
    final premLbl  = _vixPremiumLabel(vixNow);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'VIX',
                style: TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    vixNow.toStringAsFixed(1),
                    style: TextStyle(
                      color:      color,
                      fontSize:   30,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      arrow,
                      style: TextStyle(
                        color:    color,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _vixLabel(vixNow).toUpperCase(),
                  style: TextStyle(
                    color:      color,
                    fontSize:   11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  premLbl,
                  style: const TextStyle(
                    color:    AppTheme.neutralColor,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                // VIX progress bar (0–50 scale)
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value:           (vixNow / 50.0).clamp(0.0, 1.0),
                    minHeight:       5,
                    backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                    valueColor:      AlwaysStoppedAnimation(color),
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

// ── Macro regime card ─────────────────────────────────────────────────────────

class _MacroRegimeCard extends StatelessWidget {
  final _EcoData d;
  const _MacroRegimeCard({required this.d});

  @override
  Widget build(BuildContext context) {
    final macro   = d.macro;
    final regime  = macro?.regime ?? MacroRegime.neutral;
    final score   = macro?.total ?? 50.0;
    final color   = _regimeColor(regime);
    final biasText  = _biasText(regime, d.contractType);
    final biasColor = _biasColor(regime, d.contractType);

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
          // Score bar + regime
          Row(
            children: [
              Text(
                'Macro Score  ',
                style: const TextStyle(
                  color:      AppTheme.neutralColor,
                  fontSize:   12,
                ),
              ),
              Text(
                '${score.toStringAsFixed(0)} / 100',
                style: TextStyle(
                  color:      color,
                  fontSize:   14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              // Regime badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color:        color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  regime.label,
                  style: TextStyle(
                    color:      color,
                    fontSize:   11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value:           (score / 100).clamp(0.0, 1.0),
              minHeight:       6,
              backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
              valueColor:      AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 12),
          // Directional bias row
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:        biasColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(7),
              border:       Border.all(color: biasColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.arrow_forward_ios_rounded,
                    size: 11, color: biasColor),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    biasText,
                    style: TextStyle(
                      color:      biasColor,
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Regime strategies (top 2)
          if (regime.strategies.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...regime.strategies.take(2).map(
              (s) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '•  ',
                      style: TextStyle(
                        color:    AppTheme.neutralColor,
                        fontSize: 11,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        s,
                        style: const TextStyle(
                          color:    AppTheme.neutralColor,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Supporting indicators table ───────────────────────────────────────────────

class _SupportingTable extends StatelessWidget {
  final _EcoData d;
  const _SupportingTable({required this.d});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (d.yieldNow != null)
          _IndicatorRow(
            icon:   Icons.show_chart_rounded,
            label:  'Yield Curve (2s10s)',
            value:  '${d.yieldNow!.toStringAsFixed(2)}%',
            detail: _yieldLabel(d.yieldNow!),
            color:  d.yieldNow! >= 0
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
        if (d.u3Now != null)
          _IndicatorRow(
            icon:   Icons.people_outline_rounded,
            label:  'Unemployment (U3)',
            value:  '${d.u3Now!.toStringAsFixed(1)}%',
            detail: _u3Label(d.u3Now!, d.u3Prev),
            color: _u3Color(d.u3Now!, d.u3Prev),
          ),
        if (d.fedNow != null)
          _IndicatorRow(
            icon:   Icons.account_balance_outlined,
            label:  'Fed Funds Rate',
            value:  '${d.fedNow!.toStringAsFixed(2)}%',
            detail: _fedDetail(d.fedNow!, d.fedSixMo),
            color:  _fedColor(d.fedNow!, d.fedSixMo),
          ),
      ],
    );
  }
}

class _IndicatorRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final String   detail;
  final Color    color;
  const _IndicatorRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.neutralColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color:    AppTheme.neutralColor,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color:      color,
              fontSize:   13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              detail,
              style: const TextStyle(
                color:    AppTheme.neutralColor,
                fontSize: 11,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Oil sector overlay ────────────────────────────────────────────────────────

class _OilOverlay extends StatelessWidget {
  final _EcoData d;
  const _OilOverlay({required this.d});

  @override
  Widget build(BuildContext context) {
    // Compute verdict
    final oilBearish = d.crudeNow != null &&
        d.crudeAvg != null &&
        d.crudeNow! > d.crudeAvg! * 1.02;
    final lowRefinery = d.refineryNow != null && d.refineryNow! < 85;
    final prodRising  = d.crudeProdNow != null &&
        d.crudeProdPrev != null &&
        d.crudeProdNow! > d.crudeProdPrev!;

    final bearSignals = (oilBearish ? 1 : 0) +
        (lowRefinery ? 1 : 0) +
        (prodRising  ? 1 : 0);
    final verdictBearish = bearSignals >= 2;
    final verdictColor   = verdictBearish
        ? AppTheme.lossColor
        : AppTheme.profitColor;
    final verdictLabel   = verdictBearish
        ? 'BEARISH — avoid long calls on oil names'
        : 'BULLISH — supply tight, calls supported';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (d.crudeNow != null)
          _IndicatorRow(
            icon:   Icons.local_gas_station_outlined,
            label:  'Crude Stocks',
            value:  _fmtMbbl(d.crudeNow!),
            detail: d.crudeAvg != null
                ? '${oilBearish ? "↑ Surplus" : "↓ Tightening"} vs 1-yr avg (${_fmtMbbl(d.crudeAvg!)})'
                : '',
            color:  oilBearish ? AppTheme.lossColor : AppTheme.profitColor,
          ),
        if (d.crudeProdNow != null)
          _IndicatorRow(
            icon:   Icons.oil_barrel_outlined,
            label:  'Crude Production',
            value:  '${(d.crudeProdNow! / 1000).toStringAsFixed(1)}M bbl/d',
            detail: prodRising ? '↑ Rising (supply pressure)' : '→ Flat / falling',
            color:  prodRising ? AppTheme.lossColor : AppTheme.neutralColor,
          ),
        if (d.refineryNow != null)
          _IndicatorRow(
            icon:   Icons.factory_outlined,
            label:  'Refinery Utilization',
            value:  '${d.refineryNow!.toStringAsFixed(0)}%',
            detail: lowRefinery
                ? 'Below avg — demand soft'
                : 'Healthy — demand pulling',
            color:  lowRefinery ? AppTheme.lossColor : AppTheme.profitColor,
          ),
        const SizedBox(height: 8),
        // Verdict banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color:        verdictColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:       Border.all(color: verdictColor.withValues(alpha: 0.4)),
          ),
          child: Text(
            'Sector signal: $verdictLabel',
            style: TextStyle(
              color:      verdictColor,
              fontSize:   12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Sector context note (non-oil sectors) ─────────────────────────────────────

class _SectorNote extends StatelessWidget {
  final _EcoData d;
  const _SectorNote({required this.d});

  @override
  Widget build(BuildContext context) {
    final (icon, note) = switch (d.sector) {
      _Sector.ratesSensitive => (
          Icons.account_balance_outlined,
          'Rate-sensitive name — yield curve and Fed trajectory are the primary drivers. '
          'Inverted curve compresses bank margins; rising rates hurt bond-proxies.',
        ),
      _Sector.consumer => (
          Icons.shopping_bag_outlined,
          'Consumer name — employment strength and wage growth are the key signals. '
          'Strong U3 + rising hourly earnings = healthy consumer spending = bullish.',
        ),
      _Sector.tech => (
          Icons.developer_board_outlined,
          'Tech name — VIX and credit spreads drive multiple expansion/contraction. '
          'Low VIX + tight HY spreads = growth premium intact. Rising VIX = de-rate risk.',
        ),
      _Sector.broadIndex => (
          Icons.candlestick_chart_outlined,
          'Broad index — macro score IS the trade thesis. '
          'No sector overlay needed; all regime signals apply directly.',
        ),
      _ => (
          Icons.info_outline_rounded,
          'No sector-specific overlay available for this ticker. '
          'Use macro score and VIX level as the primary filters.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.neutralColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note,
              style: const TextStyle(
                color:    AppTheme.neutralColor,
                fontSize: 12,
                height:   1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Deep link button ──────────────────────────────────────────────────────────

class _DeepLinkButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const MacroScoreScreen(),
        ),
      ),
      icon: const Icon(Icons.open_in_new_rounded, size: 14),
      label: const Text('View Full Macro Score'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.neutralColor,
        side: const BorderSide(color: AppTheme.borderColor),
        minimumSize: const Size(double.infinity, 40),
        textStyle: const TextStyle(fontSize: 12),
      ),
    );
  }
}

// ── Loading / error states ────────────────────────────────────────────────────

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text(
              'Loading economic data…',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.lossColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.lossColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppTheme.lossColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Macro data error: $message',
              style: const TextStyle(
                color:    AppTheme.lossColor,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color:         AppTheme.neutralColor,
        fontSize:      10,
        fontWeight:    FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

// =============================================================================
// Helper functions
// =============================================================================

// ── VIX ───────────────────────────────────────────────────────────────────────

Color _vixColor(double vix) {
  if (vix < 15) return AppTheme.profitColor;
  if (vix < 20) return const Color(0xFF60A5FA); // blue-ish neutral
  if (vix < 30) return const Color(0xFFFBBF24); // amber
  return AppTheme.lossColor;
}

String _vixLabel(double vix) {
  if (vix < 15) return 'Low';
  if (vix < 20) return 'Normal';
  if (vix < 30) return 'Elevated';
  return 'Crisis';
}

String _vixPremiumLabel(double vix) {
  if (vix < 15) return 'Options cheap — prefer buying premium (debit spreads, long calls/puts)';
  if (vix < 20) return 'Fairly priced — either side is reasonable';
  if (vix < 30) return 'Options elevated — prefer selling premium (credit spreads, iron condors)';
  return 'Crisis volatility — sell premium (defined-risk only; gamma risk is extreme)';
}

// ── Yield curve ───────────────────────────────────────────────────────────────

String _yieldLabel(double spread) {
  if (spread > 0.5)   return 'Normal — expansion signal';
  if (spread > 0)     return 'Flat — slowing growth';
  if (spread > -0.5)  return 'Inverted — recession risk';
  return 'Deeply inverted — high recession probability';
}

// ── Fed funds ─────────────────────────────────────────────────────────────────

String _fedDetail(double now, double? sixMoAgo) {
  if (sixMoAgo == null) return 'Insufficient history';
  final delta = now - sixMoAgo;
  if (delta > 0.25)  return 'Hiking ↑ (+${delta.toStringAsFixed(2)}% in 6 mo)';
  if (delta < -0.25) return 'Cutting ↓ (${delta.toStringAsFixed(2)}% in 6 mo)';
  return 'Holding → (stable for 6 months)';
}

Color _fedColor(double now, double? sixMoAgo) {
  if (sixMoAgo == null) return AppTheme.neutralColor;
  final delta = now - sixMoAgo;
  if (delta > 0.25)  return AppTheme.lossColor;   // hiking = tightening
  if (delta < -0.25) return AppTheme.profitColor; // cutting = easing
  return AppTheme.neutralColor;
}

// ── Unemployment ──────────────────────────────────────────────────────────────

String _u3Label(double u3, double? prev) {
  if (prev == null) return '${u3.toStringAsFixed(1)}%';
  final delta = u3 - prev;
  if (delta > 0.2)  return 'Rising ↑ ${delta.toStringAsFixed(1)}pp (deteriorating)';
  if (delta < -0.2) return 'Improving ↓ ${delta.abs().toStringAsFixed(1)}pp';
  return 'Stable →';
}

Color _u3Color(double u3, double? prev) {
  if (prev == null) return AppTheme.neutralColor;
  final delta = u3 - prev;
  if (delta > 0.2)  return AppTheme.lossColor;
  if (delta < -0.2) return AppTheme.profitColor;
  return AppTheme.neutralColor;
}

// ── Macro regime color ────────────────────────────────────────────────────────

Color _regimeColor(MacroRegime r) => switch (r) {
      MacroRegime.riskOn         => AppTheme.profitColor,
      MacroRegime.neutralBullish => const Color(0xFF60A5FA),
      MacroRegime.neutral        => const Color(0xFFFBBF24),
      MacroRegime.caution        => const Color(0xFFF97316),
      MacroRegime.crisis         => AppTheme.lossColor,
    };

// ── Directional bias ──────────────────────────────────────────────────────────

String _biasText(MacroRegime regime, ContractType ct) {
  final isCall = ct == ContractType.call;
  return switch (regime) {
    MacroRegime.riskOn => isCall
        ? 'Strong bull backdrop — calls aligned with macro regime'
        : 'Risk-On: macro opposes puts — consider calls or wait',
    MacroRegime.neutralBullish => isCall
        ? 'Mild tailwinds — calls have macro support'
        : 'Mild bull bias works against puts — be very selective',
    MacroRegime.neutral =>
        'No directional edge — iron condors or wait for a quality setup',
    MacroRegime.caution => isCall
        ? 'Deteriorating conditions favor puts — reconsider calls'
        : 'Caution regime supports downside protection',
    MacroRegime.crisis =>
        'Crisis: avoid directional bets — sell premium (defined-risk) both sides',
  };
}

Color _biasColor(MacroRegime regime, ContractType ct) {
  final isCall = ct == ContractType.call;
  return switch (regime) {
    MacroRegime.riskOn         => isCall ? AppTheme.profitColor : AppTheme.lossColor,
    MacroRegime.neutralBullish => isCall ? AppTheme.profitColor : const Color(0xFFFBBF24),
    MacroRegime.neutral        => const Color(0xFFFBBF24),
    MacroRegime.caution        => isCall ? AppTheme.lossColor : const Color(0xFFFBBF24),
    MacroRegime.crisis         => AppTheme.lossColor,
  };
}

// ── Oil formatting ────────────────────────────────────────────────────────────

/// EIA crude stocks are in thousands of barrels — format as M bbl
String _fmtMbbl(double thousandBbl) =>
    '${(thousandBbl / 1000).toStringAsFixed(1)}M bbl';
