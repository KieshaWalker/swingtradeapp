// =============================================================================
// features/blotter/widgets/phase_panels/vol_surface_phase_panel.dart
// =============================================================================
// Phase 4 of 5 — Vol Surface Gate
//
// Five questions answered:
//   1. IV Level     → is this cell cheap or expensive vs the rest of the surface?
//   2. Term Structure → contango (normal) or backwardation (event/panic)?
//   3. Smile Shape  → does skew at this DTE support or fight the direction?
//   4. Earnings     → does an earnings date fall inside the trade's DTE window?
//   5. Interpretation → plain-language summary of what the surface says to do.
//
// Pass   IV < 80th pct AND contango AND no earnings in window
// Warn   IV 60–80th pct OR mild backwardation BUT smile supports direction
//         OR earnings in window but strike is far OTM
// Fail   IV crush setup: strong backwardation (>5% spread) AND buying premium
//         OR earnings inside DTE window AND ATM/near-ATM strike
//         OR IV > 90th pct while buying premium
//
// Providers consumed:
//   volSurfaceProvider              — List<VolSnapshot> from Supabase
//   tickerNextEarningsProvider(s)   — FmpEarningsDate? (FMP earnings calendar)
// =============================================================================

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme.dart';
import '../../../../services/fmp/fmp_models.dart';
import '../../../../services/fmp/fmp_providers.dart';
import '../../../vol_surface/models/vol_surface_models.dart';
import '../../../vol_surface/providers/vol_surface_provider.dart';
import '../../../vol_surface/widgets/vol_heatmap.dart';
import '../../../vol_surface/widgets/vol_smile_chart.dart';
import '../../models/phase_result.dart';

// ── Surface analysis ──────────────────────────────────────────────────────────

enum _TermShape  { contango, flat, backwardation }
enum _SmileSkew  { putBid, symmetric, callBid }

class _SurfaceAnalysis {
  final VolSnapshot   snap;
  final double?       cellIv;
  final double        cellPct;       // 0–1 percentile within surface
  final _TermShape    termShape;
  final double        termSlope;     // near − far ATM IV; + = backwardation
  final _SmileSkew    smileSkew;
  final double        putCallRatio;
  final int           closestDte;
  final double        closestStrike;
  final Map<int, double> atmByDte;   // ATM IV keyed by DTE (for term structure bar)

  const _SurfaceAnalysis({
    required this.snap,
    required this.cellIv,
    required this.cellPct,
    required this.termShape,
    required this.termSlope,
    required this.smileSkew,
    required this.putCallRatio,
    required this.closestDte,
    required this.closestStrike,
    required this.atmByDte,
  });
}

_SurfaceAnalysis _analyzeSnap({
  required VolSnapshot snap,
  required double      strike,
  required int         dte,
  required bool        isCall,
}) {
  final points = snap.points;
  final spot   = snap.spotPrice;

  if (points.isEmpty) {
    return _SurfaceAnalysis(
      snap: snap, cellIv: null, cellPct: 0.5,
      termShape: _TermShape.flat, termSlope: 0,
      smileSkew: _SmileSkew.symmetric, putCallRatio: 1.0,
      closestDte: dte, closestStrike: strike, atmByDte: {},
    );
  }

  final allStrikes = snap.strikes;
  final allDtes    = snap.dtes;

  final closestStrike = allStrikes.reduce(
      (a, b) => (a - strike).abs() < (b - strike).abs() ? a : b);
  final closestDte = allDtes.reduce(
      (a, b) => (a - dte).abs() < (b - dte).abs() ? a : b);

  // ── Cell IV ────────────────────────────────────────────────────────────────
  final mode   = isCall ? 'call' : 'put';
  final cell   = points.where(
      (p) => p.strike == closestStrike && p.dte == closestDte).firstOrNull;
  final cellIv = cell?.iv(mode, spot);

  // ── Percentile ─────────────────────────────────────────────────────────────
  final allIvs = points.map((p) => p.iv(mode, spot)).whereType<double>().toList();
  double cellPct = 0.5;
  if (allIvs.isNotEmpty && cellIv != null) {
    final mn = allIvs.reduce(min);
    final mx = allIvs.reduce(max);
    cellPct = mx > mn ? ((cellIv - mn) / (mx - mn)).clamp(0.0, 1.0) : 0.5;
  }

  // ── Term structure: ATM IV by DTE ──────────────────────────────────────────
  final atmByDte = <int, double>{};
  if (spot != null) {
    for (final d in allDtes) {
      final row = points.where((p) => p.dte == d).toList();
      if (row.isEmpty) continue;
      final atmPt = row.reduce(
          (a, b) => (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
      final iv = atmPt.iv('avg', spot) ?? atmPt.iv('call', spot) ?? atmPt.iv('put', spot);
      if (iv != null) atmByDte[d] = iv;
    }
  }

  double termSlope = 0;
  _TermShape termShape = _TermShape.flat;
  if (atmByDte.length >= 2) {
    final sorted = atmByDte.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final nearIv = sorted.first.value;
    final farIv  = sorted.last.value;
    termSlope = nearIv - farIv; // + = near > far = backwardation
    if (termSlope > 0.015) {
      termShape = _TermShape.backwardation;
    } else if (termSlope < -0.005) {
      termShape = _TermShape.contango;
    }
  }

  // ── Smile skew at closest DTE ──────────────────────────────────────────────
  _SmileSkew smileSkew  = _SmileSkew.symmetric;
  double     putCallRatio = 1.0;
  if (spot != null) {
    final row      = points.where((p) => p.dte == closestDte).toList();
    final otmCalls = row.where((p) => p.strike > spot * 1.02 && p.callIv != null)
                        .map((p) => p.callIv!).toList();
    final otmPuts  = row.where((p) => p.strike < spot * 0.98 && p.putIv  != null)
                        .map((p) => p.putIv!).toList();
    if (otmCalls.isNotEmpty && otmPuts.isNotEmpty) {
      final avgPut  = otmPuts.reduce((a, b) => a + b)  / otmPuts.length;
      final avgCall = otmCalls.reduce((a, b) => a + b) / otmCalls.length;
      putCallRatio  = avgCall > 0 ? avgPut / avgCall : 1.0;
      if (putCallRatio > 1.10) {
        smileSkew = _SmileSkew.putBid;
      } else if (putCallRatio < 0.90) {
        smileSkew = _SmileSkew.callBid;
      }
    }
  }

  return _SurfaceAnalysis(
    snap: snap, cellIv: cellIv, cellPct: cellPct,
    termShape: termShape, termSlope: termSlope,
    smileSkew: smileSkew, putCallRatio: putCallRatio,
    closestDte: closestDte, closestStrike: closestStrike,
    atmByDte: atmByDte,
  );
}

// ── Phase result from analysis + earnings ────────────────────────────────────

PhaseResult _toPhaseResult({
  required _SurfaceAnalysis  a,
  required bool              isCall,
  required int               dte,
  required double            strike,
  required double?           spot,
  FmpEarningsDate?           earnings,
}) {
  final signals  = <String>[];
  final warnings = <String>[];

  // ── 1. IV Level ────────────────────────────────────────────────────────────
  final ivStr  = a.cellIv != null ? '${(a.cellIv! * 100).toStringAsFixed(1)}%' : 'N/A';
  final pctStr = '${(a.cellPct * 100).toStringAsFixed(0)}th pct';
  signals.add(
    'IV at \$${_fmtK(a.closestStrike)} / ${a.closestDte}d: '
    '$ivStr  ($pctStr of surface range)');

  final String ivInterpret;
  if (a.cellPct < 0.30) {
    ivInterpret = 'Very low IV — premium is historically cheap. Favor buying outright or debit spreads. Model σ may underestimate realized vol.';
  } else if (a.cellPct < 0.60) {
    ivInterpret = 'Normal IV — option priced near the surface average. No strong premium-direction bias.';
  } else if (a.cellPct < 0.80) {
    ivInterpret = 'Elevated IV — above-average cost. Consider credit spreads or reducing size. IV compression after catalyst will hurt long premium.';
  } else {
    ivInterpret = 'High IV — top ${((1 - a.cellPct) * 100).toStringAsFixed(0)}% of surface. Strong IV crush risk. Prefer selling premium or defined-risk credit structure.';
  }
  signals.add(ivInterpret);

  // ── 2. Term Structure ──────────────────────────────────────────────────────
  final slopePct = (a.termSlope * 100).toStringAsFixed(1);
  final String termInterpret;
  switch (a.termShape) {
    case _TermShape.contango:
      termInterpret =
        'Term structure in contango (+${(-a.termSlope * 100).toStringAsFixed(1)}% far premium). '
        'Normal market: longer-dated options carry more premium. '
        'Calendar spreads are priced fairly. Near-term premium does not indicate event risk.';
    case _TermShape.flat:
      termInterpret =
        'Flat term structure — no significant near/far premium difference. '
        'Market sees similar risk across expirations.';
    case _TermShape.backwardation:
      termInterpret =
        'Backwardation ($slopePct% near-term premium over far). '
        'Market is pricing an imminent event — earnings, macro data, or crisis. '
        'Near-term IV is inflated; IV crush is likely once the event resolves. '
        'Avoid buying near-term premium going into the event.';
  }
  signals.add('Term structure: $termInterpret');

  // ── 3. Smile Skew ──────────────────────────────────────────────────────────
  final pcRatio = a.putCallRatio.toStringAsFixed(2);
  final String skewInterpret;
  switch (a.smileSkew) {
    case _SmileSkew.putBid:
      skewInterpret =
        'Put skew (P/C ratio $pcRatio): OTM puts are more expensive than OTM calls. '
        'Market is actively hedging downside. Bearish lean. Puts carry a premium that will compress if fear fades.';
    case _SmileSkew.symmetric:
      skewInterpret =
        'Symmetric smile (P/C $pcRatio): balanced demand for upside and downside protection. '
        'No strong directional bias from the surface.';
    case _SmileSkew.callBid:
      skewInterpret =
        'Call skew (P/C $pcRatio): OTM calls more expensive than puts. '
        'Market is chasing upside. Bullish lean; melt-up or short-squeeze positioning present.';
  }
  signals.add('Smile at ${a.closestDte}d: $skewInterpret');

  // ── 4. Direction alignment ─────────────────────────────────────────────────
  final bool skewAligned;
  if (isCall) {
    skewAligned = a.smileSkew == _SmileSkew.callBid || a.smileSkew == _SmileSkew.symmetric;
    if (skewAligned) {
      signals.add('Direction: Call skew ✓ — surface supports bullish position');
    } else {
      warnings.add('Smile works against long call — puts command premium; calls are relatively cheap but surface sentiment is bearish');
    }
  } else {
    skewAligned = a.smileSkew == _SmileSkew.putBid || a.smileSkew == _SmileSkew.symmetric;
    if (skewAligned) {
      signals.add('Direction: Put skew ✓ — surface supports bearish position; puts command premium');
    } else {
      warnings.add('Smile works against long put — calls command premium; surface sentiment is bullish');
    }
  }

  // ── 5. Earnings calendar ───────────────────────────────────────────────────
  bool earningsInWindow = false;
  if (earnings != null) {
    final daysToEarnings = earnings.date.difference(DateTime.now()).inDays;
    earningsInWindow = daysToEarnings >= 0 && daysToEarnings <= dte;

    final dateStr  = '${earnings.date.month}/${earnings.date.day}/${earnings.date.year}';
    final timeLabel = earnings.time == 'bmo' ? 'before open'
        : earnings.time == 'amc' ? 'after close' : '';
    final timeNote  = timeLabel.isNotEmpty ? ' ($timeLabel)' : '';

    if (earningsInWindow) {
      final moneyness = spot != null ? ((strike - spot) / spot).abs() : 0.0;
      final nearAtm   = moneyness < 0.05;
      final earningsText =
        'Earnings on $dateStr$timeNote — $daysToEarnings days away — falls inside your ${dte}d window. '
        '${nearAtm
            ? 'Your strike is near-ATM: the earnings move will directly decide your P&L. '
              'IV will crush sharply after announcement — you are buying the elevated pre-earnings IV.'
            : 'Your strike is ${(moneyness * 100).toStringAsFixed(0)}% OTM — '
              'needs a large post-earnings gap to be profitable. '
              'IV crush will still hurt even if direction is right.'}';
      warnings.add(earningsText);

      if (a.termShape == _TermShape.backwardation) {
        warnings.add(
          'Backwardation + earnings = classic IV crush setup. '
          'The near-term IV premium is entirely earnings-event pricing. '
          'Post-announcement IV will collapse regardless of direction.');
      }
    } else if (daysToEarnings >= 0) {
      signals.add(
        'Next earnings: $dateStr$timeNote — $daysToEarnings days away '
        '(outside your ${dte}d window — no immediate IV crush risk for this trade)');
    }
  }

  // ── 6. Calendar spread & cycle read ───────────────────────────────────────
  if (a.atmByDte.length >= 3) {
    final dteList = a.atmByDte.keys.toList()..sort();
    final frontIv = a.atmByDte[dteList.first]!;
    final midIv   = a.atmByDte[dteList[dteList.length ~/ 2]]!;
    final backIv  = a.atmByDte[dteList.last]!;
    final String calSpread;
    if (frontIv > midIv && midIv > backIv) {
      calSpread = 'Term structure fully inverted (front ${(frontIv*100).toStringAsFixed(1)}% → mid ${(midIv*100).toStringAsFixed(1)}% → back ${(backIv*100).toStringAsFixed(1)}%). Calendar spreads favor selling near-term vol, buying longer-dated. Wide contango of realized vs implied expected.';
    } else if (frontIv < midIv && midIv > backIv) {
      calSpread = 'Hump-shaped: mid-term IV elevated. This suggests a known binary event in the mid-tenor. Calendar spread at the peak DTE captures the elevated term.';
    } else {
      calSpread = 'Normal upward slope: longer expirations carry higher IV. Calendar spreads fairly priced — no structural edge.';
    }
    signals.add('Calendar cycle: $calSpread');
  }

  // ── Pass / Warn / Fail ─────────────────────────────────────────────────────
  final bool ivCrush  = a.termShape == _TermShape.backwardation && a.termSlope > 0.05;
  final bool ivHighBuy = a.cellPct > 0.90;
  final bool earningsFail = earningsInWindow && a.termShape == _TermShape.backwardation;

  final PhaseStatus status;
  final String headline;

  if (ivCrush || ivHighBuy || earningsFail) {
    status = PhaseStatus.fail;
    if (earningsFail) {
      headline = 'Fail — earnings in window + backwardation ($slopePct%) → IV crush';
    } else if (ivCrush) {
      headline = 'Fail — backwardation $slopePct% → IV crush setup';
    } else {
      headline = 'Fail — IV at ${(a.cellPct * 100).toStringAsFixed(0)}th pct; extreme premium';
    }
  } else if (warnings.isNotEmpty || earningsInWindow || a.cellPct > 0.60 || a.termShape == _TermShape.backwardation) {
    status = PhaseStatus.warn;
    final parts = <String>[];
    if (a.cellPct > 0.60) parts.add('${(a.cellPct * 100).toStringAsFixed(0)}th pct IV');
    if (a.termShape == _TermShape.backwardation) parts.add('mild backwardation');
    if (earningsInWindow) parts.add('earnings in window');
    if (!skewAligned) parts.add('adverse skew');
    headline = 'Warn — ${parts.join(' · ')}';
  } else {
    status = PhaseStatus.pass;
    headline = a.cellPct < 0.40
        ? 'Pass — low IV (${(a.cellPct * 100).toStringAsFixed(0)}th pct), contango, skew aligned'
        : 'Pass — normal IV, contango, smile supports direction';
  }

  return PhaseResult(
    status:   status,
    headline: headline,
    signals:  [...signals, ...warnings.map((w) => '⚠ $w')],
    reviewed: false,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtK(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

// ── Public widget ─────────────────────────────────────────────────────────────

class VolSurfacePhasePanel extends ConsumerStatefulWidget {
  final String  ticker;
  final double  strike;
  final int     daysToExpiry;
  final bool    isCall;
  final void Function(PhaseResult) onResult;

  const VolSurfacePhasePanel({
    super.key,
    required this.ticker,
    required this.strike,
    required this.daysToExpiry,
    required this.isCall,
    required this.onResult,
  });

  @override
  ConsumerState<VolSurfacePhasePanel> createState() =>
      _VolSurfacePhasePanelState();
}

class _VolSurfacePhasePanelState extends ConsumerState<VolSurfacePhasePanel> {
  PhaseResult? _last;

  void _notifyIfChanged(PhaseResult result) {
    if (_last?.status == result.status && _last?.headline == result.headline) {
      return;
    }
    _last = result;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onResult(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapsAsync    = ref.watch(volSurfaceProvider);
    final earningsAsync = ref.watch(tickerNextEarningsProvider(widget.ticker));

    return snapsAsync.when(
      loading: () {
        _notifyIfChanged(PhaseResult.none);
        return const _LoadingTile();
      },
      error: (e, _) {
        final r = PhaseResult(
          status: PhaseStatus.fail, headline: 'Error loading vol surface',
          signals: [e.toString()], reviewed: false,
        );
        _notifyIfChanged(r);
        return _ErrorTile(message: e.toString());
      },
      data: (snaps) {
        final filtered = snaps
            .where((s) => s.ticker.toUpperCase() == widget.ticker.toUpperCase())
            .toList();

        if (filtered.isEmpty) {
          final r = PhaseResult(
            status: PhaseStatus.warn,
            headline: 'No surface data for ${widget.ticker}',
            signals: [
              'Paste a ThinkorSwim CSV in the Vol Surface screen to unlock this phase.',
              earningsAsync.valueOrNull != null
                  ? 'Next earnings: ${earningsAsync.valueOrNull!.date.month}/${earningsAsync.valueOrNull!.date.day}'
                  : 'Earnings data loading…',
            ],
            reviewed: false,
          );
          _notifyIfChanged(r);
          return _NoDataTile(
            ticker:   widget.ticker,
            earnings: earningsAsync.valueOrNull,
          );
        }

        filtered.sort((a, b) => b.obsDate.compareTo(a.obsDate));
        final snap = filtered.first;

        final analysis = _analyzeSnap(
          snap:   snap,
          strike: widget.strike,
          dte:    widget.daysToExpiry,
          isCall: widget.isCall,
        );
        final result = _toPhaseResult(
          a:        analysis,
          isCall:   widget.isCall,
          dte:      widget.daysToExpiry,
          strike:   widget.strike,
          spot:     snap.spotPrice,
          earnings: earningsAsync.valueOrNull,
        );
        _notifyIfChanged(result);

        return _PanelBody(
          analysis:     analysis,
          result:       result,
          ticker:       widget.ticker,
          isCall:       widget.isCall,
          earnings:     earningsAsync.valueOrNull,
          dte:          widget.daysToExpiry,
          strike:       widget.strike,
          allSnaps:     filtered,
        );
      },
    );
  }
}

// ── Stub tiles ─────────────────────────────────────────────────────────────────

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
  );
}

class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text('Error: $message',
        style: const TextStyle(color: Color(0xFFFF6B8A), fontSize: 13)),
  );
}

class _NoDataTile extends StatelessWidget {
  final String          ticker;
  final FmpEarningsDate? earnings;
  const _NoDataTile({required this.ticker, this.earnings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No surface data for $ticker',
              style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Export a "Stock and Option Quote" CSV from ThinkorSwim '
            'and paste it on the Vol Surface screen.',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
          ),
          if (earnings != null) ...[
            const SizedBox(height: 8),
            _EarningsBanner(earnings: earnings!, dte: 999),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => context.push('/vol-surface'),
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open Vol Surface →'),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main panel body
// ═══════════════════════════════════════════════════════════════════════════════

class _PanelBody extends StatefulWidget {
  final _SurfaceAnalysis  analysis;
  final PhaseResult       result;
  final String            ticker;
  final bool              isCall;
  final FmpEarningsDate?  earnings;
  final int               dte;
  final double            strike;
  final List<VolSnapshot> allSnaps; // all snapshots for this ticker

  const _PanelBody({
    required this.analysis,
    required this.result,
    required this.ticker,
    required this.isCall,
    required this.dte,
    required this.strike,
    required this.allSnaps,
    this.earnings,
  });

  @override
  State<_PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<_PanelBody> {
  bool   _showHeatmap = true;
  String _ivMode      = 'otm';

  @override
  Widget build(BuildContext context) {
    final a    = widget.analysis;
    final snap = a.snap;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Snapshot badge ────────────────────────────────────────────────
          _SnapBadge(
            snap:    snap,
            ticker:  widget.ticker,
            count:   widget.allSnaps.length,
          ),
          const SizedBox(height: 10),

          // ── Earnings banner (always visible if earnings present) ───────────
          if (widget.earnings != null) ...[
            _EarningsBanner(earnings: widget.earnings!, dte: widget.dte),
            const SizedBox(height: 10),
          ],

          // ── Signal bullets ────────────────────────────────────────────────
          ...widget.result.signals.map((s) => _SignalRow(text: s)),
          const SizedBox(height: 12),

          // ── Term structure bar ─────────────────────────────────────────────
          _TermStructureBar(analysis: a),
          const SizedBox(height: 12),

          // ── Chart view toggle + IV mode ───────────────────────────────────
          Row(
            children: [
              _ToggleChip(
                label:    'Heatmap',
                selected: _showHeatmap,
                onTap:    () => setState(() => _showHeatmap = true),
              ),
              const SizedBox(width: 8),
              _ToggleChip(
                label:    'Smile',
                selected: !_showHeatmap,
                onTap:    () => setState(() => _showHeatmap = false),
              ),
              const Spacer(),
              _IvModeSelector(
                current:  _ivMode,
                onChange: (m) => setState(() => _ivMode = m),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Mini chart ────────────────────────────────────────────────────
          Container(
            height: 230,
            decoration: BoxDecoration(
              color:        AppTheme.cardColor,
              borderRadius: BorderRadius.circular(10),
              border:       Border.all(color: AppTheme.borderColor),
            ),
            child: _showHeatmap
                ? VolHeatmap(
                    points:    snap.points,
                    spotPrice: snap.spotPrice,
                    ivMode:    _ivMode,
                  )
                : VolSmileChart(
                    points:    snap.points,
                    spotPrice: snap.spotPrice,
                    ivMode:    _ivMode,
                  ),
          ),
          const SizedBox(height: 10),

          // ── Deep link ─────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/vol-surface'),
              icon:  const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('Full Surface Screen →',
                  style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.neutralColor,
                side:            const BorderSide(color: AppTheme.borderColor),
                minimumSize:     const Size.fromHeight(38),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Snapshot badge ────────────────────────────────────────────────────────────

class _SnapBadge extends StatelessWidget {
  final VolSnapshot snap;
  final String      ticker;
  final int         count;
  const _SnapBadge({required this.snap, required this.ticker, required this.count});

  @override
  Widget build(BuildContext context) {
    final spot = snap.spotPrice;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(7),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          const Icon(Icons.layers_outlined, size: 14, color: AppTheme.neutralColor),
          const SizedBox(width: 7),
          Text(
            '$ticker  ·  ${snap.obsDateStr}',
            style: const TextStyle(
                color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (spot != null) ...[
            const SizedBox(width: 6),
            Text('\$${spot.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11,
                    fontFamily: 'monospace')),
          ],
          const Spacer(),
          Text('$count snapshot${count == 1 ? '' : 's'}',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

// ── Earnings banner ───────────────────────────────────────────────────────────

class _EarningsBanner extends StatelessWidget {
  final FmpEarningsDate earnings;
  final int             dte;
  const _EarningsBanner({required this.earnings, required this.dte});

  @override
  Widget build(BuildContext context) {
    final daysAway     = earnings.date.difference(DateTime.now()).inDays;
    final inWindow     = daysAway >= 0 && daysAway <= dte;
    final Color color  = inWindow ? const Color(0xFFFF6B8A) : const Color(0xFFFBBF24);
    final dateStr      = '${earnings.date.month}/${earnings.date.day}/${earnings.date.year}';
    final timeLabel    = earnings.timeLabel;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            inWindow ? Icons.warning_amber_rounded : Icons.event_note_rounded,
            size: 15, color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inWindow
                      ? 'Earnings inside your DTE window'
                      : 'Next earnings upcoming',
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w700),
                ),
                Text(
                  '$dateStr${timeLabel.isNotEmpty ? '  ·  $timeLabel' : ''}  '
                  '·  $daysAway day${daysAway == 1 ? '' : 's'} away',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Signal row ────────────────────────────────────────────────────────────────

class _SignalRow extends StatelessWidget {
  final String text;
  const _SignalRow({required this.text});

  @override
  Widget build(BuildContext context) {
    final isWarn = text.startsWith('⚠');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isWarn)
            const Padding(
              padding: EdgeInsets.only(top: 4, right: 7),
              child: Icon(Icons.circle, size: 4, color: Color(0xFF94A3B8)),
            ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isWarn ? const Color(0xFFFBBF24) : Colors.white70,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Term structure bar ────────────────────────────────────────────────────────

class _TermStructureBar extends StatelessWidget {
  final _SurfaceAnalysis analysis;
  const _TermStructureBar({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final a          = analysis;
    final slopePct   = a.termSlope * 100;
    final fillFrac   = (slopePct.abs() / 8.0).clamp(0.0, 1.0);

    final Color color;
    final String label;
    switch (a.termShape) {
      case _TermShape.contango:
        color = AppTheme.profitColor; label = 'Contango';
      case _TermShape.flat:
        color = AppTheme.neutralColor; label = 'Flat';
      case _TermShape.backwardation:
        color = slopePct > 3 ? AppTheme.lossColor : const Color(0xFFFBBF24);
        label = 'Backwardation';
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.cardColor, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('TERM STRUCTURE',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 10,
                      fontWeight: FontWeight.w700, letterSpacing: 1.0)),
              const Spacer(),
              Text(label.toUpperCase(),
                  style: TextStyle(color: color, fontSize: 10,
                      fontWeight: FontWeight.w800, letterSpacing: 0.8)),
              const SizedBox(width: 8),
              Text(
                '${slopePct >= 0 ? '+' : ''}${slopePct.toStringAsFixed(1)}%',
                style: TextStyle(color: color, fontSize: 11,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ATM IV dots by DTE
          if (a.atmByDte.length >= 2)
            _TermDotRow(atmByDte: a.atmByDte, closestDte: a.closestDte),
          const SizedBox(height: 6),
          // Contango ←──────● ──→ Backwardation bar
          LayoutBuilder(builder: (_, c) {
            final half = c.maxWidth / 2;
            return Stack(
              children: [
                Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppTheme.elevatedColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Positioned(left: half - 1, top: 0,
                  child: Container(width: 2, height: 5, color: AppTheme.borderColor)),
                if (a.termShape != _TermShape.flat)
                  Positioned(
                    left: a.termShape == _TermShape.contango
                        ? half * (1 - fillFrac) : half,
                    top: 0,
                    child: Container(
                      width: half * fillFrac, height: 5,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            );
          }),
          const SizedBox(height: 4),
          const Row(
            children: [
              Text('← Contango', style: TextStyle(color: Color(0xFF4ADE80),
                  fontSize: 9, fontFamily: 'monospace')),
              Spacer(),
              Text('Backwardation →', style: TextStyle(color: Color(0xFFFF6B8A),
                  fontSize: 9, fontFamily: 'monospace')),
            ],
          ),
        ],
      ),
    );
  }
}

class _TermDotRow extends StatelessWidget {
  final Map<int, double> atmByDte;
  final int              closestDte;
  const _TermDotRow({required this.atmByDte, required this.closestDte});

  @override
  Widget build(BuildContext context) {
    final sorted = atmByDte.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    // Show up to 8 dots
    final shown = sorted.length > 8
        ? sorted.where((e) => sorted.indexOf(e) % (sorted.length ~/ 8 + 1) == 0
                              || e == sorted.first || e == sorted.last).toList()
        : sorted;

    return SizedBox(
      height: 36,
      child: LayoutBuilder(builder: (_, c) {
        final step = shown.isEmpty ? 0.0 : c.maxWidth / max(shown.length - 1, 1);
        return Stack(
          children: [
            // line connecting dots
            Positioned(
              left: 0, right: 0, top: 10,
              child: Container(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.4)),
            ),
            for (var i = 0; i < shown.length; i++) ...[
              Positioned(
                left: i * step - 4,
                top: 6,
                child: Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: shown[i].key == closestDte
                        ? AppTheme.profitColor
                        : AppTheme.neutralColor.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.borderColor, width: 0.5),
                  ),
                ),
              ),
              Positioned(
                left: i * step - 12,
                top: 20,
                child: SizedBox(
                  width: 24,
                  child: Text(
                    '${shown[i].key}d',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: shown[i].key == closestDte
                          ? AppTheme.profitColor
                          : AppTheme.neutralColor,
                      fontSize: 8,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }
}

// ── Toggle / mode chips ───────────────────────────────────────────────────────

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool   selected;
  final VoidCallback onTap;
  const _ToggleChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.profitColor.withValues(alpha: 0.15)
            : AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: selected
                ? AppTheme.profitColor.withValues(alpha: 0.55)
                : AppTheme.borderColor),
      ),
      child: Text(label,
          style: TextStyle(
              color:      selected ? AppTheme.profitColor : Colors.white54,
              fontSize:   12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
    ),
  );
}

class _IvModeSelector extends StatelessWidget {
  final String current;
  final void Function(String) onChange;
  const _IvModeSelector({required this.current, required this.onChange});

  static const _modes = [('otm', 'OTM'), ('call', 'Call'), ('put', 'Put'), ('avg', 'Avg')];

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < _modes.length; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        GestureDetector(
          onTap: () => onChange(_modes[i].$1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: current == _modes[i].$1 ? AppTheme.cardColor : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: current == _modes[i].$1
                      ? AppTheme.borderColor : Colors.transparent),
            ),
            child: Text(_modes[i].$2,
                style: TextStyle(
                    color: current == _modes[i].$1 ? Colors.white70 : Colors.white38,
                    fontSize: 11)),
          ),
        ),
      ],
    ],
  );
}
