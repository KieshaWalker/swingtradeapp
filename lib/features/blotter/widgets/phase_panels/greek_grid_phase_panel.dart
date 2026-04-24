// =============================================================================
// features/blotter/widgets/phase_panels/greek_grid_phase_panel.dart
// =============================================================================
// Phase 5 — Greek Grid Gate
//
// Answers: Does the options market structure (gamma regime, ATM gamma trend,
// gamma wall proximity, IV term structure) support the user's directional trade?
//
// Gate logic:
//   PASS  — gamma environment aligns with trade direction
//   WARN  — near zero-gamma level, unknown regime, or weak/mixed alignment
//   FAIL  — gamma environment directly opposes trade direction:
//              • Long PUT  in stable positive gamma (dealers buy dips → suppresses downside)
//              • Long CALL in classic short-gamma  (dealers sell rallies → suppresses upside)
//
// Inputs:
//   ticker        — to fetch greek grid + IV analysis
//   isCall        — true = long call (bullish); false = long put (bearish)
//   daysToExpiry  — selects the expiry bucket to evaluate
//   spot          — underlying last price (used for wall/ZGL proximity %)
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme.dart';
import '../../../../services/iv/iv_models.dart';
import '../../../../services/iv/iv_providers.dart';
import '../../../greek_grid/models/greek_grid_models.dart';
import '../../../greek_grid/providers/greek_grid_providers.dart';
import '../../models/phase_result.dart';

// ── Panel widget ──────────────────────────────────────────────────────────────

class GreekGridPhasePanel extends ConsumerStatefulWidget {
  final String ticker;
  final bool   isCall;
  final int    daysToExpiry;
  final double spot;
  final void Function(PhaseResult)? onResult;

  const GreekGridPhasePanel({
    super.key,
    required this.ticker,
    required this.isCall,
    required this.daysToExpiry,
    required this.spot,
    this.onResult,
  });

  @override
  ConsumerState<GreekGridPhasePanel> createState() =>
      _GreekGridPhasePanelState();
}

class _GreekGridPhasePanelState
    extends ConsumerState<GreekGridPhasePanel> {
  PhaseResult? _lastResult;

  @override
  Widget build(BuildContext context) {
    final gridAsync = ref.watch(greekGridProvider(widget.ticker));
    final ivAsync   = ref.watch(ivAnalysisProvider(widget.ticker));

    if (gridAsync.isLoading || ivAsync.isLoading) {
      return _NotReadyTile(
        icon:    Icons.grid_view_rounded,
        message: 'Loading greek grid…',
      );
    }

    final allPoints  = gridAsync.valueOrNull ?? [];
    final ivAnalysis = ivAsync.valueOrNull;

    final bucket  = _bucketForDte(widget.daysToExpiry);
    final latest  = _latestSnapshot(allPoints, widget.ticker);
    final atmCell = latest?.cell(StrikeBand.atm, bucket);
    final trend   = _atm14dTrend(allPoints, bucket);

    final result = _computeResult(
      isCall:     widget.isCall,
      ivAnalysis: ivAnalysis,
      atmCell:    atmCell,
      trend:      trend,
      spot:       widget.spot,
      bucket:     bucket,
    );
    _notifyIfChanged(result);

    return _PanelBody(
      result:     result,
      isCall:     widget.isCall,
      ivAnalysis: ivAnalysis,
      atmCell:    atmCell,
      trend:      trend,
      bucket:     bucket,
      spot:       widget.spot,
    );
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

// ── Core computation (pure) ───────────────────────────────────────────────────

ExpiryBucket _bucketForDte(int dte) {
  if (dte <= 7)  return ExpiryBucket.weekly;
  if (dte <= 30) return ExpiryBucket.nearMonthly;
  if (dte <= 60) return ExpiryBucket.monthly;
  if (dte <= 90) return ExpiryBucket.farMonthly;
  return ExpiryBucket.quarterly;
}

GreekGridSnapshot? _latestSnapshot(
    List<GreekGridPoint> points, String ticker) {
  if (points.isEmpty) return null;
  final sorted = points.map((p) => p.obsDate).toSet().toList()..sort();
  final latest = sorted.last;
  final filtered = points
      .where((p) =>
          p.obsDate.year  == latest.year &&
          p.obsDate.month == latest.month &&
          p.obsDate.day   == latest.day)
      .toList();
  return GreekGridSnapshot(ticker: ticker, obsDate: latest, points: filtered);
}

/// Returns (first, last, count) of ATM gamma over the last 14 days.
({double? first, double? last, int count}) _atm14dTrend(
    List<GreekGridPoint> all, ExpiryBucket bucket) {
  final cutoff = DateTime.now().subtract(const Duration(days: 14));
  final series = all
      .where((p) =>
          p.strikeBand   == StrikeBand.atm &&
          p.expiryBucket == bucket &&
          p.obsDate.isAfter(cutoff) &&
          p.gamma != null)
      .toList()
    ..sort((a, b) => a.obsDate.compareTo(b.obsDate));

  if (series.isEmpty) return (first: null, last: null, count: 0);
  if (series.length == 1) {
    return (first: series.first.gamma, last: series.first.gamma, count: 1);
  }
  return (first: series.first.gamma, last: series.last.gamma, count: series.length);
}

PhaseResult _computeResult({
  required bool           isCall,
  required IvAnalysis?    ivAnalysis,
  required GreekGridPoint? atmCell,
  required ({double? first, double? last, int count}) trend,
  required double         spot,
  required ExpiryBucket   bucket,
}) {
  // No data at all — soft warn, don't block
  if (ivAnalysis == null && atmCell == null) {
    return PhaseResult(
      status:  PhaseStatus.warn,
      headline: 'No greek grid data yet',
      signals: ['Greek grid snapshots populate after the next Schwab pull (every 8 h).'],
    );
  }

  final regime    = ivAnalysis?.gammaRegime   ?? GammaRegime.unknown;
  final gexSignal = ivAnalysis?.ivGexSignal   ?? IvGexSignal.unknown;
  final gexWall   = ivAnalysis?.maxGexStrike;
  final zgl       = ivAnalysis?.zeroGammaLevel;
  final zglPct    = ivAnalysis?.spotToZeroGammaPct; // spot pct ABOVE zero-gamma
  final totalGex  = ivAnalysis?.totalGex ?? 0.0;

  final signals = <String>[];
  PhaseStatus status;

  // ── 1. Direction × regime alignment (core gate) ───────────────────────────
  //
  // Positive gamma: dealers are long gamma.
  //   They sell strength / buy weakness → vol suppression, range-bound action.
  //   • Calls: slow directional grind possible — PASS (but note environment)
  //   • Puts:  dealers actively fight downside — FAIL (stable) / WARN (event)
  //
  // Negative gamma: dealers are short gamma.
  //   They sell weakness / buy strength → vol amplification, trending action.
  //   • Puts:  amplified downside — PASS
  //   • Calls: amplified downside bleeds delta — FAIL (classic) / WARN (regime shift)

  if (!isCall && regime == GammaRegime.positive &&
      gexSignal == IvGexSignal.stableGamma) {
    status = PhaseStatus.fail;
    signals.add(
      '✗ Long put in STABLE POSITIVE gamma — dealers are long gamma and will '
      'mechanically buy every dip. The downside your put needs is directly '
      'suppressed by dealer hedging flows.',
    );
  } else if (isCall && regime == GammaRegime.negative &&
      gexSignal == IvGexSignal.classicShortGamma) {
    status = PhaseStatus.fail;
    signals.add(
      '✗ Long call in CLASSIC SHORT-GAMMA regime — dealers are short gamma and '
      'will sell every rally to re-hedge. The upside your call needs is '
      'mechanically capped by dealer flow.',
    );
  } else if (!isCall && regime == GammaRegime.positive) {
    // Post-event or transitional positive gamma
    status = PhaseStatus.warn;
    signals.add(
      '⚠ Long put in positive gamma (${gexSignal.label}) — dealer support '
      'for dips may be softening. Position sizing should be conservative.',
    );
  } else if (isCall && regime == GammaRegime.negative) {
    status = PhaseStatus.warn;
    signals.add(
      '⚠ Long call in negative gamma (${gexSignal.label}) — vol amplification '
      'works against the directional delta. Prefer shorter DTE or debit spreads.',
    );
  } else if (regime == GammaRegime.unknown) {
    status = PhaseStatus.warn;
    signals.add('⚠ Gamma regime unknown — insufficient GEX data to confirm alignment.');
  } else {
    status = PhaseStatus.pass;
    if (isCall) {
      signals.add(
        '✓ Long call in ${regime.label} gamma — ${
          regime == GammaRegime.positive
            ? 'rangebound/grinding conditions favor slow upside. '
              'Positive gamma suppresses vol; use wider strikes or debit spreads.'
            : 'negative gamma amplifies trending moves. Directional momentum aligns.'
        }',
      );
    } else {
      signals.add(
        '✓ Long put in ${regime.label} gamma — ${
          regime == GammaRegime.negative
            ? 'negative gamma amplifies downside moves. Dealer re-hedging '
              'adds fuel to sell-offs.'
            : 'positive gamma transitioning — structural support weakening.'
        }',
      );
    }
  }

  // ── 2. Gamma wall ─────────────────────────────────────────────────────────
  if (gexWall != null && spot > 0) {
    final wallPct = (gexWall - spot) / spot * 100;
    final above   = wallPct >= 0;
    final absWall = wallPct.abs();
    final proximity = absWall < 1.5
        ? 'immediately at spot — expect strong pinning'
        : absWall < 3
            ? 'very close — near-term magnet'
            : absWall < 6
                ? 'moderate distance — key S/R level'
                : 'distant — less immediate influence';
    signals.add(
      'Gamma wall: \$${gexWall.toStringAsFixed(gexWall == gexWall.truncateToDouble() ? 0 : 1)}'
      '  (${absWall.toStringAsFixed(1)}% ${above ? 'above' : 'below'} spot)  — $proximity',
    );
    // Direction-specific gamma wall commentary
    if (isCall && above && absWall < 4) {
      signals.add(
        'Gamma wall is above spot — acts as a resistance ceiling for calls. '
        'Market makers will sell into that level.',
      );
      if (status == PhaseStatus.pass) status = PhaseStatus.warn;
    } else if (!isCall && !above && absWall < 4) {
      signals.add(
        'Gamma wall is below spot — acts as a support floor for puts. '
        'Market makers will buy into that level.',
      );
      if (status == PhaseStatus.pass) status = PhaseStatus.warn;
    }
  }

  // ── 3. Zero-gamma level (regime flip risk) ────────────────────────────────
  if (zgl != null && zglPct != null && spot > 0) {
    final nearFlip = zglPct.abs() < 2.0;
    if (nearFlip) {
      signals.add(
        '⚠ Spot is ${zglPct.abs().toStringAsFixed(1)}% from the zero-gamma '
        'level (\$${zgl.toStringAsFixed(0)}) — regime flip risk. '
        '${zglPct > 0 ? 'A move lower could flip dealers to short gamma.' : 'A move higher could flip dealers to long gamma.'}  '
        'Wait for spot to establish a clear side before entering.',
      );
      if (status == PhaseStatus.pass) status = PhaseStatus.warn;
    } else {
      final dir = zglPct > 0 ? 'below' : 'above';
      signals.add(
        'Zero-gamma level: \$${zgl.toStringAsFixed(0)}'
        '  (${zglPct.abs().toStringAsFixed(1)}% $dir spot)  — '
        'regime boundary. Spot is safely ${zglPct > 0 ? 'above' : 'below'} '
        'the flip point.',
      );
    }
  }

  // ── 4. ATM gamma 14-day trend ─────────────────────────────────────────────
  if (trend.count >= 3) {
    final first   = trend.first!;
    final last    = trend.last!;
    final delta   = last - first;
    final pctChng = first.abs() > 1e-8 ? (delta / first.abs() * 100) : 0.0;
    final dir     = delta > 0 ? 'rising' : 'falling';
    // For calls: rising gamma is more suppressive (warn); for puts: rising is headwind
    String trendNote;
    if (delta > 0) {
      trendNote = isCall
          ? 'Gamma rising → environment becoming more rangebound. '
            'Calls face stronger pinning headwind.'
          : 'Gamma rising → dealers gaining more cushion to absorb dips. '
            'Headwind for puts growing.';
    } else {
      trendNote = isCall
          ? 'Gamma falling → dealers losing cushion; vol amplification risk rising. '
            'Calls may face choppier upside.'
          : 'Gamma falling → vol amplification regime strengthening. '
            'Tailwind for put positions growing.';
    }
    signals.add(
      'ATM gamma (${bucket.label}, 14d): $dir '
      '${first.toStringAsFixed(4)} → ${last.toStringAsFixed(4)} '
      '(${pctChng >= 0 ? '+' : ''}${pctChng.toStringAsFixed(0)}%)'
      '  —  $trendNote',
    );
  } else if (trend.count > 0) {
    signals.add(
      'ATM gamma trend: only ${trend.count} obs in past 14 days (need ≥3). '
      'More data after the next few Schwab pulls.',
    );
  }

  // ── 5. ATM cell snapshot ──────────────────────────────────────────────────
  if (atmCell != null) {
    if (atmCell.iv != null) {
      signals.add(
        'ATM IV in ${bucket.label} bucket: ${(atmCell.iv! * 100).toStringAsFixed(1)}%'
        '  ·  OI ${atmCell.openInterest ?? '—'}'
        '  ·  Vol ${atmCell.volume ?? '—'}'
        '  ·  ${atmCell.contractCount} contracts aggregated',
      );
    }
    if (atmCell.vanna != null && atmCell.vanna!.abs() > 0.005) {
      final vannaDir = atmCell.vanna! < 0
          ? 'delta falls if IV drops (double pain on vol crush)'
          : 'delta rises if IV rises (double benefit on vol pop)';
      signals.add(
        'ATM Vanna ${atmCell.vanna!.toStringAsFixed(4)} — $vannaDir',
      );
    }
    if (atmCell.charm != null && atmCell.charm!.abs() > 0.001) {
      signals.add(
        'ATM Charm ${atmCell.charm!.toStringAsFixed(4)} — '
        'delta decays ~${(atmCell.charm!.abs() * 1000).toStringAsFixed(1)}‰/day from time alone',
      );
    }
  }

  // ── 6. GEX magnitude context ──────────────────────────────────────────────
  if (totalGex != 0) {
    final gexBillions = totalGex / 1e9;
    final gexStr = gexBillions.abs() >= 0.1
        ? '${gexBillions >= 0 ? '+' : ''}${gexBillions.toStringAsFixed(2)}B'
        : '${(totalGex / 1e6) >= 0 ? '+' : ''}${(totalGex / 1e6).toStringAsFixed(0)}M';
    signals.add('Total GEX: $gexStr  (${regime.label} regime, ${gexSignal.label})');
  }

  final headline = switch (status) {
    PhaseStatus.fail => '${isCall ? 'Call' : 'Put'} opposes ${regime.label} gamma — '
        '${regime == GammaRegime.positive ? 'dealer dip-buying suppresses downside' : 'dealer rally-selling suppresses upside'}',
    PhaseStatus.warn => 'Gamma environment — ${regime.label} regime, caution advised',
    PhaseStatus.pass => '${isCall ? 'Call' : 'Put'} aligns with ${regime.label} gamma environment',
    PhaseStatus.pending => 'Evaluating greek grid…',
  };

  return PhaseResult(status: status, headline: headline, signals: signals);
}

// ── Panel body ────────────────────────────────────────────────────────────────

class _PanelBody extends StatelessWidget {
  final PhaseResult     result;
  final bool            isCall;
  final IvAnalysis?     ivAnalysis;
  final GreekGridPoint? atmCell;
  final ({double? first, double? last, int count}) trend;
  final ExpiryBucket    bucket;
  final double          spot;

  const _PanelBody({
    required this.result,
    required this.isCall,
    required this.ivAnalysis,
    required this.atmCell,
    required this.trend,
    required this.bucket,
    required this.spot,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Phase header
          _PhaseHeader(result: result),
          const SizedBox(height: 14),

          // Gamma environment card
          _SectionLabel('Gamma Regime'),
          const SizedBox(height: 8),
          _GammaRegimeCard(
            ivAnalysis: ivAnalysis,
            isCall:     isCall,
            spot:       spot,
          ),
          const SizedBox(height: 16),

          // ATM gamma trend card
          _SectionLabel('ATM Gamma Trend  (${bucket.label}, 14d)'),
          const SizedBox(height: 8),
          _GammaTrendCard(trend: trend, isCall: isCall, bucket: bucket),
          const SizedBox(height: 16),

          // ATM cell detail card
          if (atmCell != null) ...[
            _SectionLabel('ATM Cell  ·  ${bucket.label}'),
            const SizedBox(height: 8),
            _AtmCellCard(cell: atmCell!),
            const SizedBox(height: 16),
          ],

          // Signals list
          if (result.signals.isNotEmpty) ...[
            _SectionLabel('Signals'),
            const SizedBox(height: 8),
            _SignalsCard(signals: result.signals),
          ],
        ],
      ),
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

// ── Gamma regime card ─────────────────────────────────────────────────────────

class _GammaRegimeCard extends StatelessWidget {
  final IvAnalysis? ivAnalysis;
  final bool        isCall;
  final double      spot;
  const _GammaRegimeCard({
    required this.ivAnalysis,
    required this.isCall,
    required this.spot,
  });

  @override
  Widget build(BuildContext context) {
    if (ivAnalysis == null) {
      return _EmptyCard('No IV analysis data available.');
    }

    final regime   = ivAnalysis!.gammaRegime;
    final gexWall  = ivAnalysis!.maxGexStrike;
    final zgl      = ivAnalysis!.zeroGammaLevel;
    final zglPct   = ivAnalysis!.spotToZeroGammaPct;

    final Color regimeColor = switch (regime) {
      GammaRegime.positive => AppTheme.profitColor,
      GammaRegime.negative => AppTheme.lossColor,
      GammaRegime.unknown  => AppTheme.neutralColor,
    };
    final IconData regimeIcon = switch (regime) {
      GammaRegime.positive => Icons.compress_rounded,
      GammaRegime.negative => Icons.expand_rounded,
      GammaRegime.unknown  => Icons.help_outline_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(
          color: regime == GammaRegime.negative
              ? AppTheme.lossColor.withValues(alpha: 0.4)
              : regime == GammaRegime.positive
                  ? AppTheme.profitColor.withValues(alpha: 0.3)
                  : AppTheme.borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Regime label row
          Row(
            children: [
              Icon(regimeIcon, size: 16, color: regimeColor),
              const SizedBox(width: 8),
              Text(
                regime.label,
                style: TextStyle(
                    color: regimeColor, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                ivAnalysis!.ivGexSignal.label,
                style: TextStyle(
                    color: regimeColor.withValues(alpha: 0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            regime.description,
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 10),

          // Best-fit environment description
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:        AppTheme.elevatedColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _envDescription(regime, isCall),
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11, height: 1.4),
            ),
          ),
          const SizedBox(height: 10),

          // Gamma wall + ZGL row
          if (gexWall != null || zgl != null)
            Row(
              children: [
                if (gexWall != null) ...[
                  const Icon(Icons.fence_rounded,
                      size: 13, color: AppTheme.neutralColor),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Wall \$${gexWall.toStringAsFixed(gexWall == gexWall.truncateToDouble() ? 0 : 1)}'
                      '  (${_pctFromSpot(gexWall, spot)}% ${gexWall >= spot ? 'above' : 'below'})',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11),
                    ),
                  ),
                ],
                if (zgl != null && zglPct != null) ...[
                  const Icon(Icons.swap_vert_rounded,
                      size: 13, color: AppTheme.neutralColor),
                  const SizedBox(width: 4),
                  Text(
                    'ZGL \$${zgl.toStringAsFixed(0)}'
                    '  (${zglPct.abs().toStringAsFixed(1)}% ${zglPct > 0 ? 'below' : 'above'})',
                    style: TextStyle(
                        color: zglPct.abs() < 2
                            ? const Color(0xFFFBBF24)
                            : AppTheme.neutralColor,
                        fontSize: 11),
                  ),
                ],
              ],
            ),

          // GEX magnitude
          const SizedBox(height: 6),
          Text(
            'Net GEX  ${ivAnalysis!.gexLabel}',
            style: TextStyle(
                color: regimeColor.withValues(alpha: 0.7),
                fontSize: 11,
                fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  static String _envDescription(GammaRegime regime, bool isCall) {
    if (regime == GammaRegime.positive) {
      return isCall
          ? 'Works best in: Grinding bull trends, low-vol consolidation, '
            'post-correction bounces. Positive gamma compresses vol — '
            'prefer debit spreads over naked longs to offset slow premium decay.'
          : 'Challenging environment for puts: Dealers are long gamma and will '
            'mechanically buy weakness, absorbing sell pressure. '
            'Best avoided unless near ZGL flip or strong macro catalyst expected.';
    }
    if (regime == GammaRegime.negative) {
      return isCall
          ? 'Challenging environment for calls: Dealers are short gamma and will '
            'sell into rallies, capping upside. Vol amplification hurts delta '
            'as moves become choppy and directionless. Prefer puts or straddles.'
          : 'Works best in: Trending bear moves, vol expansion events, '
            'post-support breaks. Negative gamma amplifies downside — '
            'dealers add fuel to sell-offs by selling more as spot falls.';
    }
    return 'Regime unclear — insufficient GEX data. '
        'Wait for a confirmed positive or negative gamma reading before entering.';
  }

  static String _pctFromSpot(double level, double spot) {
    if (spot <= 0) return '—';
    return ((level - spot) / spot * 100).abs().toStringAsFixed(1);
  }
}

// ── ATM gamma trend card ──────────────────────────────────────────────────────

class _GammaTrendCard extends StatelessWidget {
  final ({double? first, double? last, int count}) trend;
  final bool         isCall;
  final ExpiryBucket bucket;
  const _GammaTrendCard({
    required this.trend,
    required this.isCall,
    required this.bucket,
  });

  @override
  Widget build(BuildContext context) {
    if (trend.count == 0) {
      return _EmptyCard(
        'No ATM gamma history yet for the ${bucket.label} bucket. '
        'Data accumulates with each Schwab pull.',
      );
    }

    final first  = trend.first!;
    final last   = trend.last!;
    final rising = last > first;
    final delta  = last - first;
    final pctChng = first.abs() > 1e-8 ? delta / first.abs() * 100 : 0.0;

    final Color trendColor = rising ? AppTheme.profitColor : AppTheme.lossColor;
    final IconData trendIcon = rising
        ? Icons.trending_up_rounded
        : Icons.trending_down_rounded;

    // Interpret trend direction relative to trade direction
    final String implication;
    if (rising && isCall) {
      implication = 'Rising gamma → more rangebound. Calls face stronger pinning headwind.';
    } else if (rising && !isCall) {
      implication = 'Rising gamma → dealers gaining more cushion. Headwind for puts growing.';
    } else if (!rising && isCall) {
      implication = 'Falling gamma → dealers losing cushion, vol amplification risk rising. '
          'Calls may face choppier upside.';
    } else {
      implication = 'Falling gamma → vol amplification strengthening. Tailwind for puts growing.';
    }

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
          Row(
            children: [
              Icon(trendIcon, size: 18, color: trendColor),
              const SizedBox(width: 8),
              Text(
                rising ? 'Rising' : 'Falling',
                style: TextStyle(
                    color: trendColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Text(
                '${pctChng >= 0 ? '+' : ''}${pctChng.toStringAsFixed(0)}%  '
                'over ${trend.count} obs',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '${first.toStringAsFixed(4)} → ${last.toStringAsFixed(4)}',
                style: TextStyle(
                    color: trendColor,
                    fontSize: 11,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Mini bar chart (first vs last)
          _GammaTrendBar(first: first, last: last),
          const SizedBox(height: 8),
          Text(
            implication,
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _GammaTrendBar extends StatelessWidget {
  final double first;
  final double last;
  const _GammaTrendBar({required this.first, required this.last});

  @override
  Widget build(BuildContext context) {
    final max  = [first.abs(), last.abs(), 1e-8].reduce((a, b) => a > b ? a : b);
    final fPct = (first.abs() / max).clamp(0.0, 1.0);
    final lPct = (last.abs() / max).clamp(0.0, 1.0);
    final rising = last > first;
    final barColor = rising ? AppTheme.profitColor : AppTheme.lossColor;

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(
              width: 40,
              child: Text('14d ago',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value:           fPct,
                  minHeight:       6,
                  backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                  valueColor:      const AlwaysStoppedAnimation(AppTheme.neutralColor),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const SizedBox(
              width: 40,
              child: Text('Today',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value:           lPct,
                  minHeight:       6,
                  backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                  valueColor:      AlwaysStoppedAnimation(barColor),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── ATM cell detail card ──────────────────────────────────────────────────────

class _AtmCellCard extends StatelessWidget {
  final GreekGridPoint cell;
  const _AtmCellCard({required this.cell});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          _CellMetricRow(
            label: 'IV',
            value: cell.iv != null ? '${(cell.iv! * 100).toStringAsFixed(1)}%' : '—',
            sub:   'Median implied vol across ATM contracts in bucket',
          ),
          _CellDivider(),
          _CellMetricRow(
            label: 'Gamma',
            value: cell.gamma?.toStringAsFixed(5) ?? '—',
            sub:   'Median Γ — rate of delta change per \$1 move',
          ),
          _CellDivider(),
          _CellMetricRow(
            label: 'Vanna',
            value: cell.vanna?.toStringAsFixed(5) ?? '—',
            sub:   cell.vanna != null
                ? (cell.vanna! < 0
                    ? 'Negative — delta falls when IV drops'
                    : 'Positive — delta rises when IV rises')
                : 'Not available',
            valueColor: cell.vanna != null
                ? (cell.vanna! < 0 ? AppTheme.lossColor : AppTheme.profitColor)
                : AppTheme.neutralColor,
          ),
          _CellDivider(),
          _CellMetricRow(
            label: 'Charm',
            value: cell.charm?.toStringAsFixed(5) ?? '—',
            sub:   cell.charm != null
                ? 'Delta decays ~${(cell.charm!.abs() * 1000).toStringAsFixed(1)}‰/day from time alone'
                : 'Not available',
          ),
          _CellDivider(),
          Row(
            children: [
              Expanded(
                child: _CellMetricRow(
                  label: 'Open Interest',
                  value: _fmtInt(cell.openInterest),
                  sub:   'Total OI in ATM band',
                ),
              ),
              Expanded(
                child: _CellMetricRow(
                  label: 'Volume',
                  value: _fmtInt(cell.volume),
                  sub:   'Today\'s volume in ATM band',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtInt(int? v) {
    if (v == null) return '—';
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toString();
  }
}

class _CellMetricRow extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color  valueColor;
  const _CellMetricRow({
    required this.label,
    required this.value,
    required this.sub,
    this.valueColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
                const SizedBox(height: 2),
                Text(sub,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10, height: 1.3)),
              ],
            ),
          ),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _CellDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.4));
}

// ── Signals card ──────────────────────────────────────────────────────────────

class _SignalsCard extends StatelessWidget {
  final List<String> signals;
  const _SignalsCard({required this.signals});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: signals.map((s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(s,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11, height: 1.4)),
        )).toList(),
      ),
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

// ── Empty / not-ready tile ────────────────────────────────────────────────────

class _NotReadyTile extends StatelessWidget {
  final IconData icon;
  final String   message;
  const _NotReadyTile({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.all(14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(message,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 12)),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String message;
  const _EmptyCard(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Text(message,
          style: const TextStyle(
              color: AppTheme.neutralColor, fontSize: 11, height: 1.4)),
    );
  }
}
