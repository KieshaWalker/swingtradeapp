// =============================================================================
// vol_surface/widgets/vol_surface_interpretation.dart
// Plain-English interpretation panel — shown below heatmap/smile/diff.
// Analyzes the active snapshot and surfaces IV level, term structure,
// smile skew, and 2-3 key reads without requiring a specific trade.
// =============================================================================
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/vol_surface_models.dart';
import '../providers/sabr_calibration_provider.dart';
import '../../../services/iv/iv_models.dart';
import '../../../services/iv/iv_storage_service.dart';
import '../../../services/iv/iv_providers.dart';
import '../../../services/iv/realized_vol_models.dart';
import '../../../services/iv/realized_vol_providers.dart';
import '../../../services/vol_surface/arb_checker.dart';

// ── IV snapshot provider ──────────────────────────────────────────────────────
// Reads the latest iv_snapshots row for a ticker — populated by Python
// /iv/analytics each time an options chain loads. Provides real GEX,
// skew (pp), and P/C ratio to replace the Dart OI-proxy approximations.

final _ivSnapProvider = FutureProvider.autoDispose
    .family<IvSnapshot?, String>(
  (ref, ticker) => IvStorageService().getLatest(ticker),
);

// ── Private analysis ──────────────────────────────────────────────────────────

enum _Term { contango, flat, backwardation }
enum _Skew { putBid, symmetric, callBid }
enum _GammaRegime { positive, negative, neutral }
enum _GexSlope    { rising, flat, falling }

// ── Gamma wall data ────────────────────────────────────────────────────────────
// Dealers are assumed net-short options (they sell to retail/institutions).
// Large call OI → dealers long delta hedge → concentrated hedging near call wall.
// Large put OI → dealers short delta hedge → pinning effect near put wall.
// Net OI = callOI − putOI (proxy for gamma regime; true GEX requires gamma × OI × multiplier × spot).
// Positive net OI → more call-side hedging → dealers likely absorb moves.
// Negative net OI → more put-side hedging → dealers likely amplify moves.
//
// OI slope: direction of net OI profile as price rises.
//   Rising  → more call OI ahead (walls sticky, moves likely absorbed)
//   Falling → OI balance declining toward zero (Danger Zone if flip is close)
//   Flat    → no strong directional bias in OI above spot
//
// IV/OI signal: in negative OI regimes, spot ↓ typically correlates with IV ↑.
//   If that relationship breaks (neg OI + suppressed IV), a regime shift may
//   be occurring. Computed from current surface-range atmPct + OI regime.
//   Note: atmPct is the surface percentile (ATM IV within today's p5–p95 range),
//   not a historical IV percentile.
//
// Liquidity density proxy: bid/ask SIZE is not in the TOS static CSV export, so
//   we cannot measure book depth directly. Instead we compute the OI concentration
//   ratio at the nearest put wall vs. the surrounding ±5% band. A ratio < 0.5
//   means the wall is thinly supported relative to the surrounding strikes — a
//   proxy signal for "dealer preparing for washout." Real-time order book data
//   would give a more precise signal.

class _WallStrike {
  final double strike;
  final int    callOI;
  final int    putOI;
  int get netOI => callOI - putOI; // + = call-dominated (OI proxy, not true GEX)
  const _WallStrike({required this.strike, required this.callOI, required this.putOI});
}

class _GammaData {
  final List<_WallStrike> callWalls;       // top 3 by call OI above spot
  final List<_WallStrike> putWalls;        // top 3 by put OI  below spot
  final double?           oiFlip;          // price where cumulative net OI → 0
  final double?           oiFlipDistPct;   // |flip − spot| / spot × 100
  final _GammaRegime      regime;
  final _GexSlope         oiSlope;         // net OI direction as price moves up
  final bool              dangerZone;      // pos-OI regime but flip within 4% of spot
  final double?           wallOiRatio;     // nearest put wall OI / avg nearby OI
  final int               totalCallOI;
  final int               totalPutOI;

  const _GammaData({
    required this.callWalls,
    required this.putWalls,
    required this.oiFlip,
    required this.oiFlipDistPct,
    required this.regime,
    required this.oiSlope,
    required this.dangerZone,
    required this.wallOiRatio,
    required this.totalCallOI,
    required this.totalPutOI,
  });

  static const _empty = _GammaData(
    callWalls: [], putWalls: [], oiFlip: null, oiFlipDistPct: null,
    regime: _GammaRegime.neutral, oiSlope: _GexSlope.flat,
    dangerZone: false, wallOiRatio: null, totalCallOI: 0, totalPutOI: 0,
  );

  static _GammaData from(VolSnapshot snap) {
    final pts  = snap.points;
    final spot = snap.spotPrice;
    if (pts.isEmpty) return _empty;

    final hasOI = pts.any((p) => (p.callOI ?? 0) > 0 || (p.putOI ?? 0) > 0);
    if (!hasOI) return _empty;

    // ── Aggregate OI by strike across all expirations ──────────────────────
    final byStrike = <double, _WallStrike>{};
    for (final p in pts) {
      final ex = byStrike[p.strike];
      byStrike[p.strike] = _WallStrike(
        strike:  p.strike,
        callOI: (ex?.callOI ?? 0) + (p.callOI ?? 0),
        putOI:  (ex?.putOI  ?? 0) + (p.putOI  ?? 0),
      );
    }
    final all = byStrike.values.toList()..sort((a, b) => a.strike.compareTo(b.strike));

    final int totalC = all.fold(0, (s, w) => s + w.callOI);
    final int totalP = all.fold(0, (s, w) => s + w.putOI);

    // ── Separate above/below spot ──────────────────────────────────────────
    final above = spot == null ? all : all.where((w) => w.strike >= spot).toList();
    final below = spot == null ? all : all.where((w) => w.strike <  spot).toList();

    // Top 3 call walls: highest call OI above spot
    final topCalls = ([...above]..sort((a, b) => b.callOI.compareTo(a.callOI)))
        .take(3).toList()
        ..sort((a, b) => a.strike.compareTo(b.strike)); // ascending by strike

    // Top 3 put walls: highest put OI below spot
    final topPuts = ([...below]..sort((a, b) => b.putOI.compareTo(a.putOI)))
        .take(3).toList()
        ..sort((a, b) => b.strike.compareTo(a.strike)); // descending (nearest first)

    // ── Net OI regime at spot ──────────────────────────────────────────────
    _GammaRegime regime = _GammaRegime.neutral;
    if (spot != null && all.isNotEmpty) {
      final nearest = all.reduce((a, b) =>
          (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
      final net = nearest.netOI;
      if (net > 0) {
        regime = _GammaRegime.positive;
      } else if (net < 0) {
        regime = _GammaRegime.negative;
      }
    }

    // ── OI flip price ──────────────────────────────────────────────────────
    // Walk outward from spot; find the first strike where cumulative net OI sign
    // flips from the at-spot sign.
    double? flip;
    if (spot != null && all.length >= 2) {
      final sortedByDist = [...all]
        ..sort((a, b) => (a.strike - spot).abs().compareTo((b.strike - spot).abs()));
      int cumOI   = 0;
      int? firstSign; // only set on first non-zero cumOI to avoid false flip at 0
      for (final w in sortedByDist) {
        cumOI += w.netOI;
        // Skip zero — setting firstSign=0 would trigger a false flip on the next
        // non-zero step. We want the sign of the first non-zero cumulative value.
        if (cumOI.sign != 0) firstSign ??= cumOI.sign;
        if (firstSign != null && cumOI.sign != 0 && cumOI.sign != firstSign) {
          flip = w.strike;
          break;
        }
      }
    }
    final flipDistPct = (spot != null && spot > 0 && flip != null)
        ? ((flip - spot).abs() / spot * 100)
        : null;

    // ── OI slope ───────────────────────────────────────────────────────────
    // Compare total net OI in the 0–3% band above spot to the 3–6% band.
    // Falling: OI balance declining as price rises → approaching flip.
    // Rising:  more call OI ahead → walls likely sticky, moves absorbed.
    _GexSlope gexSlope = _GexSlope.flat;
    if (spot != null && above.length >= 2) {
      final nearOI = above
          .where((w) => w.strike <= spot * 1.03)
          .fold(0, (s, w) => s + w.netOI);
      final farOI = above
          .where((w) => w.strike > spot * 1.03 && w.strike <= spot * 1.06)
          .fold(0, (s, w) => s + w.netOI);
      final ratio = (nearOI == 0) ? 1.0 : farOI / nearOI;
      if (ratio < 0.70) {
        gexSlope = _GexSlope.falling;
      } else if (ratio > 1.30) {
        gexSlope = _GexSlope.rising;
      }
    }

    // ── Danger Zone ────────────────────────────────────────────────────────
    // Positive OI regime but OI flip is within 4% of spot — one move from flipping.
    final dangerZone = regime == _GammaRegime.positive &&
        flipDistPct != null &&
        flipDistPct < 4.0;

    // ── Liquidity density proxy (OI concentration at nearest put wall) ─────
    // Real bid/ask SIZE is not available in TOS static CSV exports.
    // Proxy: OI at the nearest put wall vs. average OI of strikes within ±5%
    // of the wall itself (not of spot). This avoids a scale mismatch when the
    // nearest put wall is far from spot.
    // Ratio < 0.5 → wall is thinly supported vs neighbours = potential washout.
    // Ratio > 2.0 → wall is heavily defended = strong support.
    double? wallOiRatio;
    if (spot != null && topPuts.isNotEmpty) {
      final nearWall = topPuts.first; // nearest put wall (sorted desc → first = nearest)
      final wallBand = nearWall.strike * 0.05;
      final neighborStrikes = all.where((w) =>
          (w.strike - nearWall.strike).abs() <= wallBand &&
          w.strike != nearWall.strike).toList();
      if (neighborStrikes.isNotEmpty) {
        final avgNeighborOi = neighborStrikes.fold(0, (s, w) => s + w.putOI) /
            neighborStrikes.length;
        if (avgNeighborOi > 0) wallOiRatio = nearWall.putOI / avgNeighborOi;
      }
    }

    return _GammaData(
      callWalls:     topCalls,
      putWalls:      topPuts,
      oiFlip:        flip,
      oiFlipDistPct: flipDistPct,
      regime:        regime,
      oiSlope:       gexSlope,
      dangerZone:    dangerZone,
      wallOiRatio:   wallOiRatio,
      totalCallOI:   totalC,
      totalPutOI:    totalP,
    );
  }
}

class _A {
  final _Term           termShape;
  final double          termSlope;      // nearIv − farIv  (+= backwardation)
  final Map<int,double> atmByDte;       // sorted ASC by DTE
  final _Skew           skew;
  final double          putCallRatio;
  final int             frontDte;
  final double?         atmIvFront;     // ATM IV at shortest DTE
  final double          surfaceMin;
  final double          surfaceMax;
  final double          atmPct;         // 0–1 within surface range

  const _A({
    required this.termShape,
    required this.termSlope,
    required this.atmByDte,
    required this.skew,
    required this.putCallRatio,
    required this.frontDte,
    required this.atmIvFront,
    required this.surfaceMin,
    required this.surfaceMax,
    required this.atmPct,
  });

  static _A from(VolSnapshot snap) {
    final pts  = snap.points;
    final spot = snap.spotPrice;
    final dtes = snap.dtes; // pre-sorted

    if (pts.isEmpty || dtes.isEmpty) {
      return const _A(
        termShape: _Term.flat, termSlope: 0, atmByDte: {},
        skew: _Skew.symmetric, putCallRatio: 1, frontDte: 0,
        atmIvFront: null, surfaceMin: 0, surfaceMax: 1, atmPct: 0.5,
      );
    }

    // ── ATM IV by DTE ────────────────────────────────────────────────────────
    final atmByDte = <int,double>{};
    if (spot != null) {
      for (final d in dtes) {
        final row = pts.where((p) => p.dte == d).toList();
        if (row.isEmpty) continue;
        final atm = row.reduce((a, b) =>
            (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
        final iv = atm.iv('avg', spot) ?? atm.iv('call', spot) ?? atm.iv('put', spot);
        if (iv != null) atmByDte[d] = iv;
      }
    }

    // ── Term structure ────────────────────────────────────────────────────────
    // slope = nearIV − farIV (positive = backwardation).
    // Normalize by DTE span: a 1.5% IV drop over 7 days is extreme;
    // the same drop over 150 days is noise. Threshold per 30-day unit.
    double slope = 0;
    _Term term = _Term.flat;
    if (atmByDte.length >= 2) {
      final s = atmByDte.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      slope = s.first.value - s.last.value; // raw: + = near > far = backwardation
      final dteDiff = (s.last.key - s.first.key).toDouble().clamp(1.0, double.infinity);
      final slopePerMonth = slope / dteDiff * 30; // IV difference per 30 DTE
      if (slopePerMonth > 0.020) {        // >2% per 30d = backwardation
        term = _Term.backwardation;
      } else if (slopePerMonth < -0.005) { // <-0.5% per 30d = contango
        term = _Term.contango;
      }
    }

    // ── Front-DTE smile skew ──────────────────────────────────────────────────
    final front = dtes.first;
    _Skew skew = _Skew.symmetric;
    double pcr  = 1.0;
    if (spot != null) {
      final row = pts.where((p) => p.dte == front).toList();
      // Use the 3 nearest OTM strikes on each side (sorted by proximity to spot).
      // Averaging all OTM strikes within a fixed % band gives equal weight to near
      // and far wings — the far wing IV is much higher and drowns out the ATM signal.
      final sortedAsc = [...row]..sort((a, b) => a.strike.compareTo(b.strike));
      final nearCalls = sortedAsc
          .where((p) => p.strike > spot * 1.02 && p.callIv != null)
          .take(3)
          .map((p) => p.callIv!)
          .toList();
      final nearPuts = sortedAsc.reversed
          .where((p) => p.strike < spot * 0.98 && p.putIv != null)
          .take(3)
          .map((p) => p.putIv!)
          .toList();
      if (nearCalls.isNotEmpty && nearPuts.isNotEmpty) {
        final avgP = nearPuts.reduce((a, b) => a + b)  / nearPuts.length;
        final avgC = nearCalls.reduce((a, b) => a + b) / nearCalls.length;
        pcr = avgC > 0 ? avgP / avgC : 1.0;
        if (pcr > 1.10) {
          skew = _Skew.putBid;
        } else if (pcr < 0.90) {
          skew = _Skew.callBid;
        }
      }
    }

    // ── Surface IV range — 5th/95th percentile ───────────────────────────────
    // Raw min/max includes deep-OTM strikes at 500–1100%+ IV; ATM at 38% would
    // register as ~0th percentile of the surface. Use percentile bounds instead.
    final rawIvs = pts
        .map((p) => p.iv('avg', spot) ?? p.iv('call', spot) ?? p.iv('put', spot))
        .whereType<double>()
        .toList()
      ..sort();
    double mn, mx;
    if (rawIvs.isEmpty) {
      mn = 0.0; mx = 1.0;
    } else if (rawIvs.length < 20) {
      mn = rawIvs.first; mx = rawIvs.last;
    } else {
      mn = rawIvs[(rawIvs.length * 0.05).floor()];
      mx = rawIvs[(rawIvs.length * 0.95).floor()];
    }
    final atm = atmByDte[front];
    double pct = 0.5;
    if (atm != null && mx > mn) {
      pct = ((atm - mn) / (mx - mn)).clamp(0.0, 1.0);
    }

    return _A(
      termShape: term,
      termSlope: slope,
      atmByDte: Map.fromEntries(
          atmByDte.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      skew: skew,
      putCallRatio: pcr,
      frontDte: front,
      atmIvFront: atm,
      surfaceMin: mn,
      surfaceMax: mx,
      atmPct: pct,
    );
  }
}

// ── Key reads generator ───────────────────────────────────────────────────────

List<String> _keyReads(_A a) {
  final reads = <String>[];

  // Crush warning takes priority slot if both signals agree
  if (a.termShape == _Term.backwardation && a.atmPct > 0.70) {
    reads.add('Crush setup — near-term IV inflated by event pricing; avoid buying front premium');
  }

  // IV level
  if (a.atmPct < 0.30) {
    reads.add('IV cheap vs surface — debit spreads and outright buys have structural edge');
  } else if (a.atmPct < 0.60) {
    reads.add('IV near surface average — no premium direction bias; all structures viable');
  } else if (a.atmPct < 0.80) {
    reads.add('Premium above surface average — reduce long size; credit structures worth considering');
  } else if (!reads.any((r) => r.contains('Crush'))) {
    reads.add('IV near surface highs — significant crush risk on long premium positions');
  }

  // Term structure (skip if crush already noted)
  if (!reads.any((r) => r.contains('Crush') || r.contains('event'))) {
    switch (a.termShape) {
      case _Term.contango:
        reads.add('Contango intact — no event risk priced near-term; calendar spreads fairly valued');
      case _Term.flat:
        reads.add('Flat term structure — similar risk priced across all expirations');
      case _Term.backwardation:
        reads.add('Near-term IV elevated — binary event or macro risk priced in the front');
    }
  } else if (a.termShape == _Term.contango) {
    reads.add('Despite elevated IV, term in contango — event risk limited to surface noise');
  }

  // Smile skew
  switch (a.skew) {
    case _Skew.putBid:
      reads.add('Put skew: market is paying up to hedge downside — bearish lean in surface structure');
    case _Skew.symmetric:
      reads.add('Symmetric smile: balanced directional demand; surface not biased call or put');
    case _Skew.callBid:
      reads.add('Call skew: upside chasing detected — squeeze or melt-up positioning in surface');
  }

  return reads.take(3).toList();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Public widget
// ═══════════════════════════════════════════════════════════════════════════════

class VolSurfaceInterpretation extends ConsumerWidget {
  final VolSnapshot snap;
  final String ivMode;

  const VolSurfaceInterpretation({
    super.key,
    required this.snap,
    required this.ivMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = _A.from(snap);
    final ivSnap   = ref.watch(_ivSnapProvider(snap.ticker)).valueOrNull;
    final rvResult = ref.watch(realizedVolProvider(snap.ticker)).valueOrNull;
    final ivAsync    = ref.watch(ivAnalysisProvider(snap.ticker));

    // Verdict
    final bool isFail = a.termShape == _Term.backwardation && a.atmPct > 0.70;
    final bool isWarn = a.atmPct > 0.60 || a.termShape == _Term.backwardation;
    final Color verdictColor = isFail
        ? const Color(0xFFf87171)
        : isWarn
            ? const Color(0xFFfbbf24)
            : const Color(0xFF4ade80);
    final String verdictLabel =
        isFail ? 'CRUSH RISK' : isWarn ? 'CAUTION' : 'CLEAR';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0a0e1a),
        border: Border(top: BorderSide(color: Color(0xFF1f2937))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              border: Border(bottom: BorderSide(color: Color(0xFF1f2937))),
            ),
            child: Row(children: [
              const Text('SURFACE READ',
                  style: TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      fontFamily: 'monospace')),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: verdictColor.withValues(alpha: 0.15),
                  border: Border.all(
                      color: verdictColor.withValues(alpha: 0.50)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(verdictLabel,
                    style: TextStyle(
                        color: verdictColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                        fontFamily: 'monospace')),
              ),
              const SizedBox(width: 10),
              Text(snap.ticker,
                  style: const TextStyle(
                      color: Color(0xFF60a5fa),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace')),
              const SizedBox(width: 6),
              Text(snap.obsDateStr,
                  style: const TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 10,
                      fontFamily: 'monospace')),
              if (snap.spotPrice != null) ...[
                const SizedBox(width: 6),
                Text(
                    '\$${snap.spotPrice!.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: Color(0xFF9ca3af),
                        fontSize: 10,
                        fontFamily: 'monospace')),
              ],
            ]),
          ),
          // ── Cards row ────────────────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _IvCard(a: a, ivSnap: ivSnap, rvResult: rvResult),
                  _TermCard(a: a),
                  _SkewCard(a: a, ivSnap: ivSnap),
                  _WallsCard(snap: snap, a: a, ivSnap: ivSnap),
                  _FlowCard(snap: snap, ivSnap: ivSnap),
                  _ReadsCard(a: a, ivSnap: ivSnap),
                  _SabrCard(snap: snap),
                  _ArbCard(snap: snap),
                  _RndCard(ivAsync: ivAsync),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── IV Level card ─────────────────────────────────────────────────────────────

class _IvCard extends StatelessWidget {
  final _A a;
  final IvSnapshot? ivSnap;
  final RealizedVolResult? rvResult;
  const _IvCard({required this.a, this.ivSnap, this.rvResult});

  @override
  Widget build(BuildContext context) {
    final iv = a.atmIvFront;

    // Use Python IV rank (52-week history) when available; fall back to
    // surface percentile (ATM IV within today's p5–p95 range).
    final usingIvRank = ivSnap?.ivRank != null;
    final pct = usingIvRank
        ? (ivSnap!.ivRank! / 100).clamp(0.0, 1.0)
        : a.atmPct;

    final (label, color) = switch (usingIvRank ? ivSnap!.ivRating : null) {
      IvRating.cheap     => ('LOW IV',      const Color(0xFF4ade80)),
      IvRating.fair      => ('NORMAL IV',   const Color(0xFF60a5fa)),
      IvRating.expensive => ('ELEVATED IV', const Color(0xFFfbbf24)),
      IvRating.extreme   => ('HIGH IV',     const Color(0xFFf87171)),
      _ => switch (pct) {
        < 0.30 => ('LOW IV',      const Color(0xFF4ade80)),
        < 0.60 => ('NORMAL IV',   const Color(0xFF60a5fa)),
        < 0.80 => ('ELEVATED IV', const Color(0xFFfbbf24)),
        _      => ('HIGH IV',     const Color(0xFFf87171)),
      },
    };

    final String sub = usingIvRank
        ? switch (ivSnap!.ivRating) {
            IvRating.cheap     => 'Cheap vs 52w — debit edge',
            IvRating.fair      => 'Near 52w average',
            IvRating.expensive => 'Above 52w avg — watch premium cost',
            IvRating.extreme   => '52w highs — crush risk',
            _                  => '',
          }
        : switch (pct) {
            < 0.30 => 'Cheap vs surface — debit edge',
            < 0.60 => 'Near surface average',
            < 0.80 => 'Above avg — watch premium cost',
            _      => 'Top of surface — crush risk',
          };

    return _Card(
      width: 168,
      label: 'ATM IV  (${a.frontDte}d)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            iv != null ? '${(iv * 100).toStringAsFixed(1)}%' : 'N/A',
            style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace'),
          ),
          const SizedBox(height: 6),
          // Percentile bar
          Stack(children: [
            Container(
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFF1f2937),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            FractionallySizedBox(
              widthFactor: pct,
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 5),
          Text(
            usingIvRank
                ? 'IVR ${ivSnap!.ivRank!.toStringAsFixed(0)}%'
                    '  ·  IVP ${ivSnap!.ivPercentile?.toStringAsFixed(0) ?? '—'}%'
                : '${(pct * 100).toStringAsFixed(0)}th pct of surface',
            style: const TextStyle(
                color: Color(0xFF6b7280),
                fontSize: 9,
                fontFamily: 'monospace'),
          ),
          if (rvResult != null && rvResult!.rv20d > 0) ...[
            const SizedBox(height: 2),
            Text(
              'HV20d ${(rvResult!.rv20d * 100).toStringAsFixed(1)}%'
              '  ·  HV60d ${(rvResult!.rv60d * 100).toStringAsFixed(1)}%',
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 9,
                  fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              border:
                  Border.all(color: color.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 6),
          Text(sub,
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 9,
                  fontFamily: 'monospace')),
          const SizedBox(height: 6),
          Text(
            usingIvRank
                ? 'Surface p5–p95: ${(a.surfaceMin * 100).toStringAsFixed(0)}–'
                    '${(a.surfaceMax * 100).toStringAsFixed(0)}%  (today)'
                : 'Surface p5–p95: ${(a.surfaceMin * 100).toStringAsFixed(0)}–'
                    '${(a.surfaceMax * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 9,
                fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

// ── Term structure card ───────────────────────────────────────────────────────

class _TermCard extends StatelessWidget {
  final _A a;
  const _TermCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon, detail) = switch (a.termShape) {
      _Term.contango => (
          'CONTANGO',
          const Color(0xFF4ade80),
          '▲',
          'Far IV > Near IV — normal market',
        ),
      _Term.flat => (
          'FLAT',
          const Color(0xFF60a5fa),
          '→',
          'Near ≈ Far IV — balanced risk',
        ),
      _Term.backwardation => (
          'BACKWARDATION',
          const Color(0xFFf87171),
          '▼',
          'Near IV > Far IV — event risk',
        ),
    };

    final slope  = a.termSlope * 100;
    final slopeTxt = slope >= 0
        ? '+${slope.toStringAsFixed(1)}%'
        : '${slope.toStringAsFixed(1)}%';

    // Show up to 4 DTE ladder entries
    final ladder = a.atmByDte.entries.take(4).toList();

    return _Card(
      width: 180,
      label: 'TERM STRUCTURE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('$icon ',
                style: TextStyle(
                    color: color, fontSize: 13, fontFamily: 'monospace')),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      fontFamily: 'monospace')),
            ),
          ]),
          Text('Near−Far: $slopeTxt',
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 9,
                  fontFamily: 'monospace')),
          const SizedBox(height: 6),
          Text(detail,
              style: const TextStyle(
                  color: Color(0xFF9ca3af),
                  fontSize: 9,
                  fontFamily: 'monospace')),
          const SizedBox(height: 8),
          // DTE ladder
          if (ladder.isNotEmpty) ...[
            const Text('ATM IV by expiry',
                style: TextStyle(
                    color: Color(0xFF4b5563),
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    fontFamily: 'monospace')),
            const SizedBox(height: 4),
            for (final e in ladder)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  SizedBox(
                    width: 28,
                    child: Text('${e.key}d',
                        style: const TextStyle(
                            color: Color(0xFF6b7280),
                            fontSize: 9,
                            fontFamily: 'monospace')),
                  ),
                  Text('${(e.value * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                          color: Color(0xFFd1d5db),
                          fontSize: 9,
                          fontFamily: 'monospace')),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Smile skew card ───────────────────────────────────────────────────────────

class _SkewCard extends StatelessWidget {
  final _A a;
  final IvSnapshot? ivSnap;
  const _SkewCard({required this.a, this.ivSnap});

  @override
  Widget build(BuildContext context) {
    // Python skew = OTM put IV − call IV in percentage points.
    // Prefer it over the Dart near-OTM ratio approximation.
    final effectiveSkew = ivSnap?.skew != null
        ? (ivSnap!.skew! > 2.0
            ? _Skew.putBid
            : ivSnap!.skew! < -2.0
                ? _Skew.callBid
                : _Skew.symmetric)
        : a.skew;

    final effectivePcr = ivSnap?.putCallRatio ?? a.putCallRatio;

    final (label, color, headline, sub) = switch (effectiveSkew) {
      _Skew.putBid => (
          'PUT SKEW',
          const Color(0xFFf87171),
          'Hedging demand present',
          'OTM puts bid up — market is paying for downside protection. Bearish lean in surface structure.',
        ),
      _Skew.symmetric => (
          'SYMMETRIC',
          const Color(0xFF60a5fa),
          'Balanced demand',
          'No strong directional bias. Equal demand for upside and downside optionality.',
        ),
      _Skew.callBid => (
          'CALL SKEW',
          const Color(0xFF4ade80),
          'Upside positioning',
          'OTM calls command premium — squeeze or melt-up positioning visible in surface.',
        ),
    };

    final pcr = effectivePcr.toStringAsFixed(2);

    return _Card(
      width: 188,
      label: 'SMILE SKEW  (${a.frontDte}d)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  fontFamily: 'monospace')),
          const SizedBox(height: 3),
          Text('P/C ratio: $pcr',
              style: const TextStyle(
                  color: Color(0xFF9ca3af),
                  fontSize: 10,
                  fontFamily: 'monospace')),
          const SizedBox(height: 8),
          Text(headline,
              style: const TextStyle(
                  color: Color(0xFFd1d5db),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
          const SizedBox(height: 4),
          Text(sub,
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 9,
                  height: 1.4,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

// ── Key reads card ────────────────────────────────────────────────────────────

class _ReadsCard extends StatelessWidget {
  final _A a;
  final IvSnapshot? ivSnap;
  const _ReadsCard({required this.a, this.ivSnap});

  @override
  Widget build(BuildContext context) {
    // Use Python iv_gex_signal description + strategy hint when available;
    // fall back to locally-computed key reads.
    final signal = ivSnap?.ivGexSignal;
    final useSignal = signal != null && signal != IvGexSignal.unknown;

    final reads = useSignal
        ? [signal.description, signal.strategyHint]
        : _keyReads(a);

    final signalColor = useSignal
        ? switch (signal) {
            IvGexSignal.classicShortGamma => const Color(0xFFf87171),
            IvGexSignal.regimeShift       => const Color(0xFFfbbf24),
            IvGexSignal.eventOverPosGamma => const Color(0xFFfbbf24),
            _                             => const Color(0xFF4ade80),
          }
        : const Color(0xFF9ca3af);

    return _Card(
      width: 260,
      label: useSignal ? 'IV / GEX SIGNAL' : 'KEY READS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (useSignal) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: signalColor.withValues(alpha: 0.12),
                border: Border.all(color: signalColor.withValues(alpha: 0.40)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(signal.label.toUpperCase(),
                  style: TextStyle(
                      color: signalColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      fontFamily: 'monospace')),
            ),
            const SizedBox(height: 8),
          ],
          for (var i = 0; i < reads.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reads[i].startsWith('⚠') ? '⚠ ' : '· ',
                  style: TextStyle(
                      color: reads[i].startsWith('⚠')
                          ? const Color(0xFFfbbf24)
                          : const Color(0xFF4b5563),
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
                Expanded(
                  child: Text(
                    reads[i].startsWith('⚠') ? reads[i].substring(2) : reads[i],
                    style: TextStyle(
                        color: useSignal
                            ? (i == 0 ? const Color(0xFFd1d5db) : const Color(0xFF6b7280))
                            : reads[i].startsWith('⚠')
                                ? const Color(0xFFfbbf24)
                                : const Color(0xFF9ca3af),
                        fontSize: 10,
                        height: 1.45,
                        fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
            if (i < reads.length - 1) const SizedBox(height: 7),
          ],
        ],
      ),
    );
  }
}

// ── Options flow card ─────────────────────────────────────────────────────────

class _StrikeFlow {
  final double strike;
  final int callVol;
  final int putVol;
  final int callOI;
  final int putOI;
  int get totalVol => callVol + putVol;
  int get totalOI  => callOI  + putOI;
  const _StrikeFlow({
    required this.strike,
    required this.callVol,
    required this.putVol,
    required this.callOI,
    required this.putOI,
  });
}

class _FlowCard extends StatelessWidget {
  final VolSnapshot snap;
  final IvSnapshot? ivSnap;
  const _FlowCard({required this.snap, this.ivSnap});

  @override
  Widget build(BuildContext context) {
    // Aggregate by strike across all DTEs
    final byStrike = <double, _StrikeFlow>{};
    for (final p in snap.points) {
      final existing = byStrike[p.strike];
      byStrike[p.strike] = _StrikeFlow(
        strike:  p.strike,
        callVol: (existing?.callVol ?? 0) + (p.callVolume ?? 0),
        putVol:  (existing?.putVol  ?? 0) + (p.putVolume  ?? 0),
        callOI:  (existing?.callOI  ?? 0) + (p.callOI     ?? 0),
        putOI:   (existing?.putOI   ?? 0) + (p.putOI      ?? 0),
      );
    }

    final hasVol = byStrike.values.any((s) => s.totalVol > 0);
    final hasOI  = byStrike.values.any((s) => s.totalOI  > 0);

    if (!hasVol && !hasOI) {
      return _Card(
        width: 210,
        label: 'OPTIONS FLOW',
        child: const Center(
          child: Text(
            'No volume/OI data.\nRe-export CSV with\nVolume & Open Int columns.',
            style: TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 9,
                height: 1.5,
                fontFamily: 'monospace'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Totals
    int totalCallVol = 0, totalPutVol = 0;
    int totalCallOI  = 0, totalPutOI  = 0;
    for (final s in byStrike.values) {
      totalCallVol += s.callVol;
      totalPutVol  += s.putVol;
      totalCallOI  += s.callOI;
      totalPutOI   += s.putOI;
    }
    final totalVol = totalCallVol + totalPutVol;
    final totalOI  = totalCallOI  + totalPutOI;
    // Prefer Python-computed P/C ratio (full chain OI) over surface-OI proxy.
    final volPcr = ivSnap?.putCallRatio ??
        (totalCallVol > 0 ? totalPutVol / totalCallVol : 1.0);

    // Top 4 strikes by volume (falling back to OI)
    final ranked = byStrike.values.toList()
      ..sort((a, b) => (hasVol ? b.totalVol : b.totalOI)
          .compareTo(hasVol ? a.totalVol : a.totalOI));
    final top = ranked.take(4).toList();

    // Sentiment from vol P/C ratio
    final (sentLabel, sentColor) = volPcr > 1.20
        ? ('BEARISH FLOW',  const Color(0xFFf87171))
        : volPcr > 1.05
            ? ('MILD PUT BIAS', const Color(0xFFfbbf24))
            : volPcr < 0.80
                ? ('BULLISH FLOW',  const Color(0xFF4ade80))
                : volPcr < 0.95
                    ? ('MILD CALL BIAS', const Color(0xFF60a5fa))
                    : ('NEUTRAL FLOW',  const Color(0xFF9ca3af));

    String fmtK(int n) {
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000)    return '${(n / 1000).toStringAsFixed(0)}K';
      return n.toString();
    }

    return _Card(
      width: 230,
      label: 'OPTIONS FLOW',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sentiment chip
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: sentColor.withValues(alpha: 0.12),
                border: Border.all(color: sentColor.withValues(alpha: 0.40)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(sentLabel,
                  style: TextStyle(
                      color: sentColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      fontFamily: 'monospace')),
            ),
            const SizedBox(width: 6),
            Text('P/C ${volPcr.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: Color(0xFF6b7280),
                    fontSize: 9,
                    fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 6),
          // Vol / OI totals bar
          if (hasVol) ...[
            _FlowBar(
              label: 'VOL',
              callVal: totalCallVol,
              putVal: totalPutVol,
              total: totalVol,
              fmtK: fmtK,
            ),
            const SizedBox(height: 3),
          ],
          if (hasOI) ...[
            _FlowBar(
              label: 'OI ',
              callVal: totalCallOI,
              putVal: totalPutOI,
              total: totalOI,
              fmtK: fmtK,
            ),
            const SizedBox(height: 4),
          ],
          // Hot strikes
          const Text('HOT STRIKES',
              style: TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  fontFamily: 'monospace')),
          const SizedBox(height: 4),
          for (final s in top)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                SizedBox(
                  width: 46,
                  child: Text(
                    '\$${s.strike == s.strike.truncateToDouble() ? s.strike.toInt() : s.strike.toStringAsFixed(1)}',
                    style: const TextStyle(
                        color: Color(0xFFd1d5db),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace'),
                  ),
                ),
                if (hasVol) ...[
                  Text('C ${fmtK(s.callVol)}',
                      style: const TextStyle(
                          color: Color(0xFF4ade80),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  const Text(' / ',
                      style: TextStyle(
                          color: Color(0xFF374151),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  Text('P ${fmtK(s.putVol)}',
                      style: const TextStyle(
                          color: Color(0xFFf87171),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                ] else if (hasOI) ...[
                  Text('C OI ${fmtK(s.callOI)}',
                      style: const TextStyle(
                          color: Color(0xFF4ade80),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  const Text(' / ',
                      style: TextStyle(
                          color: Color(0xFF374151),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  Text('P OI ${fmtK(s.putOI)}',
                      style: const TextStyle(
                          color: Color(0xFFf87171),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                ],
              ]),
            ),
        ],
      ),
    );
  }
}

// ── Gamma walls card ──────────────────────────────────────────────────────────

// ── Gamma strategy guide bottom sheet ─────────────────────────────────────────

class _GammaStrategySheet extends StatelessWidget {
  final _GammaRegime regime;
  const _GammaStrategySheet({required this.regime});

  static const _longGamma = [
    ('PRIMARY OBJECTIVE', 'Harvest Theta',
        'This is the time to maximize time-decay income while dealer hedging dampens price swings.'),
    ('STRATEGY SELECTION', 'Net-Short Premium',
        'Iron Condors, Strangles, Credit Spreads. The market is "pinned" to heavy strikes — collect the premium.'),
    ('RISK MANAGEMENT', 'Standard Deviation',
        'Price action is near-normally distributed. 2σ/3σ boundaries are highly reliable for stop placement.'),
    ('EXECUTION', 'Passive Liquidity',
        'Sit on the BID or ASK and wait for fills. Spreads are tight; slippage is minimal. No need to chase.'),
    ('THE TRAP ⚠', 'Complacency',
        'Long Gamma environments precede flips. Track distance to the OI flip point daily and use a "circuit breaker" as spot approaches it. Increase sizing on mean-reversion trades — but cut immediately if the flip triggers.'),
  ];

  static const _shortGamma = [
    ('PRIMARY OBJECTIVE', 'Capture Convexity',
        'You want positions that gain value faster as the move accelerates — dealer-driven waterfalls or squeezes.'),
    ('STRATEGY SELECTION', 'Net-Long Premium / Trend Follow',
        'Long Straddles, Strangles, Debit Spreads. Long Gamma positions benefit from the dealer feedback loop amplifying the move.'),
    ('RISK MANAGEMENT', 'Fat Tail Models',
        'Standard deviation models fail here. Switch to Expected Shortfall (ES) or Monte Carlo with fat-tail assumptions — moves are not normally distributed.'),
    ('EXECUTION', 'Aggressive Liquidity',
        'Hit the tape immediately. Do not work an order — in a Short Gamma move, the price you see now is likely the best you will get.'),
    ('THE TRAP ⚠', 'Vanna/Charm Reversals',
        'Volatility spikes can over-price options. If IV hits a ceiling and starts to mean-revert, a volatility crush can kill a winning long-premium trade. Watch for IV stalling while the move continues.'),
  ];

  @override
  Widget build(BuildContext context) {
    final isShort = regime == _GammaRegime.negative;

    Widget buildSection(String tag, String title, String body, bool active) {
      final color = active
          ? (isShort ? const Color(0xFFf87171) : const Color(0xFF4ade80))
          : const Color(0xFF374151);
      final textColor = active ? Colors.white : const Color(0xFF6b7280);
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF111827) : const Color(0xFF0d1117),
          border: Border.all(color: color, width: active ? 1 : 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tag,
                style: TextStyle(
                    color: color,
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    fontFamily: 'monospace')),
            const SizedBox(height: 3),
            Text(title,
                style: TextStyle(
                    color: active ? Colors.white : const Color(0xFF9ca3af),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace')),
            const SizedBox(height: 5),
            Text(body,
                style: TextStyle(
                    color: textColor,
                    fontSize: 12,
                    height: 1.5,
                    fontFamily: 'monospace')),
          ],
        ),
      );
    }

    Widget buildGuide(String heading, Color headColor, List<(String, String, String)> rows, bool active) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: headColor.withValues(alpha: 0.12),
              border: Border.all(color: headColor.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(heading,
                style: TextStyle(
                    color: headColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 10),
          for (final (tag, title, body) in rows)
            buildSection(tag, title, body, active),
        ],
      );
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0a0e1a),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(top: BorderSide(color: Color(0xFF1f2937))),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF374151),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(children: [
                const Text('GAMMA REGIME PLAYBOOK',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        fontFamily: 'monospace')),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close, color: Color(0xFF6b7280), size: 20),
                ),
              ]),
            ),
            // Content
            Expanded(
              child: ListView(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  buildGuide(
                    '1. LONG GAMMA  (The "Cushion" Regime)',
                    const Color(0xFF4ade80),
                    _longGamma,
                    !isShort,
                  ),
                  const SizedBox(height: 18),
                  buildGuide(
                    '2. SHORT GAMMA  (The "Fuel" Regime)',
                    const Color(0xFFf87171),
                    _shortGamma,
                    isShort,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Gamma walls card ──────────────────────────────────────────────────────────

class _WallsCard extends StatelessWidget {
  final VolSnapshot snap;
  final _A          a;
  final IvSnapshot? ivSnap;
  const _WallsCard({required this.snap, required this.a, this.ivSnap});

  @override
  Widget build(BuildContext context) {
    final g    = _GammaData.from(snap);
    final spot = snap.spotPrice;

    // Override regime from Python-computed true GEX when available.
    // The Dart fallback uses raw OI as a proxy (callOI − putOI), which
    // ignores strike distance, time-to-expiry, and actual gamma values.
    final effectiveRegime = ivSnap?.totalGex != null
        ? (ivSnap!.totalGex! > 0
            ? _GammaRegime.positive
            : ivSnap!.totalGex! < 0
                ? _GammaRegime.negative
                : _GammaRegime.neutral)
        : (g.totalCallOI > g.totalPutOI
            ? _GammaRegime.positive
            : g.totalCallOI < g.totalPutOI
                ? _GammaRegime.negative
                : _GammaRegime.neutral);

    if (g.callWalls.isEmpty && g.putWalls.isEmpty) {
      return _Card(
        width: 210,
        label: 'GAMMA WALLS',
        child: const Center(
          child: Text(
            'No OI data.\nRe-export CSV with\nOpen Int columns.',
            style: TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 9,
                height: 1.5,
                fontFamily: 'monospace'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Flip level: prefer Python zero_gamma_level (true GEX crossing) over OI-flip proxy.
    final effectiveFlipLevel    = ivSnap?.zeroGammaLevel ?? g.oiFlip;
    final effectiveFlipDistPct  = ivSnap?.spotToZeroGammaPct?.abs() ?? g.oiFlipDistPct;
    final effectiveDangerZone   = effectiveRegime == _GammaRegime.positive &&
        effectiveFlipDistPct != null && effectiveFlipDistPct < 4.0;

    final (regimeLabel, regimeColor, regimeSub) = switch (effectiveRegime) {
      _GammaRegime.positive => (
          effectiveDangerZone ? 'POS GAMMA ⚡ DANGER ZONE' : 'POS GAMMA',
          effectiveDangerZone ? const Color(0xFFfbbf24) : const Color(0xFF4ade80),
          effectiveDangerZone
              ? 'GEX flip within ${effectiveFlipDistPct.toStringAsFixed(1)}% — one move from negative gamma'
              : 'Dealers absorb moves — mean-reversion likely near walls',
        ),
      _GammaRegime.negative => (
          'NEG GAMMA',
          const Color(0xFFf87171),
          'Dealers amplify moves — trending conditions, walls less sticky',
        ),
      _GammaRegime.neutral => (
          'NEUTRAL GAMMA',
          const Color(0xFF9ca3af),
          'Balanced dealer gamma near spot',
        ),
    };

    // GEX slope: prefer Python gamma_slope over Dart OI-band proxy.
    final (slopeIcon, slopeColor, slopeLabel) = switch (ivSnap?.gammaSlope) {
      GammaSlope.rising  => ('↗', const Color(0xFF4ade80), 'Rising — GEX cushion strengthening above spot'),
      GammaSlope.falling => ('↘', const Color(0xFFf97316), 'Falling — GEX eroding toward flip level'),
      GammaSlope.flat    => ('→', const Color(0xFF9ca3af), 'Flat — GEX stable across strikes'),
      _ => switch (g.oiSlope) {
        _GexSlope.rising  => ('↗', const Color(0xFF4ade80), 'Rising — more call OI ahead'),
        _GexSlope.flat    => ('→', const Color(0xFF9ca3af), 'Flat — OI balance stable'),
        _GexSlope.falling => ('↘', const Color(0xFFf97316), 'Falling — OI balance declining toward flip'),
      },
    };

    // IV / GEX signal: prefer Python classification (uses true GEX + 52w IV rank).
    final pySignal = ivSnap?.ivGexSignal;
    final (ivGexLabel, ivGexColor, ivGexDetail) = pySignal != null &&
            pySignal != IvGexSignal.unknown
        ? (
            pySignal.label.toUpperCase(),
            switch (pySignal) {
              IvGexSignal.classicShortGamma => const Color(0xFFf87171),
              IvGexSignal.regimeShift       => const Color(0xFFfbbf24),
              IvGexSignal.eventOverPosGamma => const Color(0xFFfbbf24),
              _                             => const Color(0xFF4ade80),
            },
            pySignal.description,
          )
        : switch ((effectiveRegime, a.atmPct)) {
            (_GammaRegime.negative, final p) when p > 0.65 => (
              'CLASSIC SHORT GAMMA',
              const Color(0xFFf87171),
              'Neg gamma + elevated IV — inverse corr in effect (spot ↓ = IV ↑)',
            ),
            (_GammaRegime.negative, final p) when p < 0.30 => (
              'REGIME SHIFT SIGNAL',
              const Color(0xFFfbbf24),
              'Neg gamma but IV suppressed — inverse corr may be breaking',
            ),
            (_GammaRegime.negative, _) => (
              'SHORT GAMMA ENV',
              const Color(0xFFf97316),
              'Directional risk elevated — monitor for IV/spot correlation',
            ),
            (_GammaRegime.positive, final p) when p > 0.70 => (
              'EVENT OVER POS GAMMA',
              const Color(0xFFfbbf24),
              'High IV despite positive gamma — event premium suppressing dampening',
            ),
            _ => (
              'STABLE GAMMA',
              const Color(0xFF4ade80),
              'Positive gamma with moderate IV — price/IV less correlated',
            ),
          };

    // Wall density: prefer Python put_wall_density over Dart OI-concentration proxy.
    final effectiveWallDensity = ivSnap?.putWallDensity ?? g.wallOiRatio;
    final (liqLabel, liqColor, liqDetail) = effectiveWallDensity == null
        ? ('N/A', const Color(0xFF4b5563), '')
        : effectiveWallDensity < 0.50
            ? ('THIN WALL',  const Color(0xFFf87171), 'Low density at put wall — washout risk')
            : effectiveWallDensity > 2.0
                ? ('SOLID WALL', const Color(0xFF4ade80), 'High density — support well-defended')
                : ('MODERATE',  const Color(0xFF9ca3af), 'Average density at put wall');

    String fmtK(int n) {
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000)    return '${(n / 1000).toStringAsFixed(0)}K';
      return n.toString();
    }

    String fmtStrike(double s) =>
        '\$${s == s.truncateToDouble() ? s.toInt() : s.toStringAsFixed(1)}';

    return _Card(
      width: 248,
      label: 'GAMMA WALLS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Regime chip + playbook button ────────────────────────────────
          Row(children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: regimeColor.withValues(alpha: 0.12),
                  border: Border.all(color: regimeColor.withValues(alpha: 0.40)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(regimeLabel,
                    style: TextStyle(
                        color: regimeColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        fontFamily: 'monospace')),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => _GammaStrategySheet(regime: effectiveRegime),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1f2937),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF374151)),
                ),
                child: const Text('?',
                    style: TextStyle(
                        color: Color(0xFF9ca3af),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace')),
              ),
            ),
          ]),
          const SizedBox(height: 3),
          Text(regimeSub,
              style: TextStyle(
                  color: effectiveDangerZone
                      ? const Color(0xFFfbbf24)
                      : const Color(0xFF6b7280),
                  fontSize: 8,
                  height: 1.35,
                  fontFamily: 'monospace')),
          const SizedBox(height: 7),

          // ── OI slope ─────────────────────────────────────────────────────
          Row(children: [
            const Text('OI SLOPE  ',
                style: TextStyle(
                    color: Color(0xFF4b5563),
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    fontFamily: 'monospace')),
            Text('$slopeIcon ',
                style: TextStyle(color: slopeColor, fontSize: 10,
                    fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 2),
          Text(slopeLabel,
              style: TextStyle(
                  color: slopeColor,
                  fontSize: 8,
                  height: 1.3,
                  fontFamily: 'monospace')),
          const SizedBox(height: 7),

          // ── Call walls ───────────────────────────────────────────────────
          if (g.callWalls.isNotEmpty) ...[
            const Text('CALL WALLS  (resistance)',
                style: TextStyle(
                    color: Color(0xFF4b5563),
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    fontFamily: 'monospace')),
            const SizedBox(height: 3),
            for (final w in g.callWalls)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  Text('▲ ',
                      style: TextStyle(
                          color: spot != null && w.strike > spot
                              ? const Color(0xFF4ade80)
                              : const Color(0xFF374151),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  SizedBox(
                    width: 46,
                    child: Text(fmtStrike(w.strike),
                        style: const TextStyle(
                            color: Color(0xFFd1d5db),
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace')),
                  ),
                  Text('OI ${fmtK(w.callOI)}',
                      style: const TextStyle(
                          color: Color(0xFF4ade80),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                ]),
              ),
            const SizedBox(height: 6),
          ],

          // ── Put walls ────────────────────────────────────────────────────
          if (g.putWalls.isNotEmpty) ...[
            const Text('PUT WALLS  (pinning zone)',
                style: TextStyle(
                    color: Color(0xFF4b5563),
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    fontFamily: 'monospace')),
            const SizedBox(height: 3),
            for (final w in g.putWalls)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  Text('▼ ',
                      style: TextStyle(
                          color: spot != null && w.strike < spot
                              ? const Color(0xFFf87171)
                              : const Color(0xFF374151),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                  SizedBox(
                    width: 46,
                    child: Text(fmtStrike(w.strike),
                        style: const TextStyle(
                            color: Color(0xFFd1d5db),
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace')),
                  ),
                  Text('OI ${fmtK(w.putOI)}',
                      style: const TextStyle(
                          color: Color(0xFFf87171),
                          fontSize: 8,
                          fontFamily: 'monospace')),
                ]),
              ),
            const SizedBox(height: 7),
          ],

          // ── GEX / OI flip ─────────────────────────────────────────────────
          if (effectiveFlipLevel != null) ...[
            Row(children: [
              Text(ivSnap?.zeroGammaLevel != null ? 'GEX flip  ' : 'OI flip  ',
                  style: const TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 8,
                      fontFamily: 'monospace')),
              Text(fmtStrike(effectiveFlipLevel),
                  style: const TextStyle(
                      color: Color(0xFFfbbf24),
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
              if (effectiveFlipDistPct != null) ...[
                const Text('  ', style: TextStyle(fontSize: 8)),
                Text('(${effectiveFlipDistPct.toStringAsFixed(1)}% away)',
                    style: const TextStyle(
                        color: Color(0xFF6b7280),
                        fontSize: 8,
                        fontFamily: 'monospace')),
              ],
            ]),
            const SizedBox(height: 7),
          ],

          // ── IV / OI signal ────────────────────────────────────────────────
          const Text('IV / OI SIGNAL',
              style: TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  fontFamily: 'monospace')),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: ivGexColor.withValues(alpha: 0.10),
              border: Border.all(color: ivGexColor.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(ivGexLabel,
                style: TextStyle(
                    color: ivGexColor,
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 3),
          Text(ivGexDetail,
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 8,
                  height: 1.35,
                  fontFamily: 'monospace')),
          const SizedBox(height: 7),

          // ── Wall density ──────────────────────────────────────────────────
          if (effectiveWallDensity != null) ...[
            Row(children: [
              const Text('WALL DENSITY  ',
                  style: TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.9,
                      fontFamily: 'monospace')),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: liqColor.withValues(alpha: 0.10),
                  border: Border.all(color: liqColor.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(liqLabel,
                    style: TextStyle(
                        color: liqColor,
                        fontSize: 7,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        fontFamily: 'monospace')),
              ),
            ]),
            const SizedBox(height: 2),
            Text(liqDetail,
                style: const TextStyle(
                    color: Color(0xFF6b7280),
                    fontSize: 8,
                    fontFamily: 'monospace')),
            const SizedBox(height: 2),
            Text('Density: ${effectiveWallDensity.toStringAsFixed(2)}×'
                '${ivSnap?.putWallDensity != null ? ' (Python)' : ' avg (OI proxy)'}',
                style: const TextStyle(
                    color: Color(0xFF374151),
                    fontSize: 7,
                    fontFamily: 'monospace')),
          ],
        ],
      ),
    );
  }
}

class _FlowBar extends StatelessWidget {
  final String label;
  final int callVal;
  final int putVal;
  final int total;
  final String Function(int) fmtK;

  const _FlowBar({
    required this.label,
    required this.callVal,
    required this.putVal,
    required this.total,
    required this.fmtK,
  });

  @override
  Widget build(BuildContext context) {
    final callFrac = total > 0 ? callVal / total : 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('$label ',
              style: const TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontFamily: 'monospace')),
          Text(fmtK(callVal),
              style: const TextStyle(
                  color: Color(0xFF4ade80),
                  fontSize: 8,
                  fontFamily: 'monospace')),
          const Text(' / ',
              style: TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontFamily: 'monospace')),
          Text(fmtK(putVal),
              style: const TextStyle(
                  color: Color(0xFFf87171),
                  fontSize: 8,
                  fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            child: Row(children: [
              Expanded(
                flex: (callFrac * 100).round(),
                child: Container(color: const Color(0xFF166534)),
              ),
              Expanded(
                flex: ((1 - callFrac) * 100).round(),
                child: Container(color: const Color(0xFF7f1d1d)),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

// ── SABR calibration card ─────────────────────────────────────────────────────

// Derives plain-English reads from a single SABR slice.
class _SabrRead {
  final String skewLabel;
  final Color  skewColor;
  final String skewDetail;

  final String wingsLabel;
  final Color  wingsColor;
  final String wingsDetail;

  final String alphaLabel;
  final Color  alphaColor;
  final String alphaDetail;

  final String fitLabel;
  final Color  fitColor;
  final bool   isReliable;

  // Cross-parameter synthesis — combines ρ, ν, α into a single actionable read.
  final String synthesis;

  const _SabrRead({
    required this.skewLabel,  required this.skewColor,  required this.skewDetail,
    required this.wingsLabel, required this.wingsColor, required this.wingsDetail,
    required this.alphaLabel, required this.alphaColor, required this.alphaDetail,
    required this.fitLabel,   required this.fitColor,   required this.isReliable,
    required this.synthesis,
  });

  factory _SabrRead.from(SabrSlice s) {
    // ── ρ  →  skew direction ──────────────────────────────────────────────────
    final (skewLabel, skewColor, skewDetail) = s.rho < -0.40
        ? ('STRONG PUT SKEW', const Color(0xFFf87171),
            'ρ=${s.rho.toStringAsFixed(2)}  Crash-risk priced into puts. '
            'OTM puts command significant premium over calls. '
            'Selling put spreads costs more than call spreads at same distance.')
        : s.rho < -0.15
            ? ('MILD PUT SKEW', const Color(0xFFfbbf24),
                'ρ=${s.rho.toStringAsFixed(2)}  Normal equity hedging bias. '
                'OTM puts slightly bid; surface consistent with typical equity structure.')
            : s.rho > 0.20
                ? ('CALL SKEW', const Color(0xFF4ade80),
                    'ρ=${s.rho.toStringAsFixed(2)}  Unusual upside skew. '
                    'Calls priced richer than puts at same distance — squeeze or '
                    'melt-up positioning visible in the surface.')
                : ('SYMMETRIC', const Color(0xFF60a5fa),
                    'ρ=${s.rho.toStringAsFixed(2)}  Balanced smile. '
                    'No strong directional bias in the surface; calls and puts '
                    'priced at similar IV for equivalent distances from spot.');

    // ── ν  →  wing convexity (vol-of-vol) ────────────────────────────────────
    final (wingsLabel, wingsColor, wingsDetail) = s.nu > 1.50
        ? ('FAT WINGS', const Color(0xFFfbbf24),
            'ν=${s.nu.toStringAsFixed(2)}  High vol-of-vol. OTM options are '
            'expensive vs ATM. Spreads and defined-risk structures are more '
            'capital-efficient than naked buys. Butterflies may be cheap.')
        : s.nu > 0.70
            ? ('MODERATE WINGS', const Color(0xFF60a5fa),
                'ν=${s.nu.toStringAsFixed(2)}  Normal curvature. '
                'Balanced trade-off between ATM and OTM pricing. '
                'No structural edge favouring one structure over another.')
            : ('FLAT SMILE', const Color(0xFF4ade80),
                'ν=${s.nu.toStringAsFixed(2)}  Low vol-of-vol. Wings barely '
                'priced. OTM options are cheap relative to ATM — strangles and '
                'ratio spreads may offer value if direction is taken.');

    // ── α  →  overall vol level calibrated by SABR ───────────────────────────
    final (alphaLabel, alphaColor, alphaDetail) = s.alpha > 0.60
        ? ('HIGH VOL LEVEL', const Color(0xFFf87171),
            'α=${s.alpha.toStringAsFixed(2)}  ATM vol calibrated high. '
            'Premium selling has structural edge; debit buyers face '
            'significant time-decay headwind.')
        : s.alpha > 0.30
            ? ('MODERATE VOL', const Color(0xFFfbbf24),
                'α=${s.alpha.toStringAsFixed(2)}  Mid-range ATM vol. '
                'Neither strongly favours buyers nor sellers. '
                'Structure selection should lean on IVR/IVP for context.')
            : ('LOW VOL LEVEL', const Color(0xFF4ade80),
                'α=${s.alpha.toStringAsFixed(2)}  Compressed ATM vol. '
                'Debit structures are cheap on a historical basis. '
                'Credit sellers face thinner premium but limited risk.');

    // ── RMSE  →  fit reliability ──────────────────────────────────────────────
    final (fitLabel, fitColor) = s.rmse < 0.005
        ? ('EXCELLENT FIT', const Color(0xFF4ade80))
        : s.rmse < 0.015
            ? ('GOOD FIT', const Color(0xFF60a5fa))
            : s.rmse < 0.030
                ? ('MODERATE FIT', const Color(0xFFfbbf24))
                : ('POOR FIT', const Color(0xFFf87171));

    return _SabrRead(
      skewLabel:  skewLabel,  skewColor:  skewColor,  skewDetail:  skewDetail,
      wingsLabel: wingsLabel, wingsColor: wingsColor, wingsDetail: wingsDetail,
      alphaLabel: alphaLabel, alphaColor: alphaColor, alphaDetail: alphaDetail,
      fitLabel:   fitLabel,   fitColor:   fitColor,
      isReliable: s.isReliable,
      synthesis:  _synthesize(s),
    );
  }

  // Cross-parameter synthesis: combines ρ (skew), ν (wings), α (vol level)
  // into one actionable trader narrative. Priority: skew direction first,
  // then wing shape, then vol regime.
  static String _synthesize(SabrSlice s) {
    final rho   = s.rho;
    final nu    = s.nu;
    final alpha = s.alpha;

    // ── Strong put skew variants ──────────────────────────────────────────────
    if (rho < -0.40 && nu > 1.50) {
      return 'Crash-bid surface. Extreme put skew (ρ=${rho.toStringAsFixed(2)}) '
          'combined with high vol-of-vol (ν=${nu.toStringAsFixed(2)}) prices a '
          'gap-down scenario with elevated tail risk. OTM puts are structurally '
          'expensive on both skew and wing grounds — avoid naked short puts below '
          'spot. Bull call spreads and call diagonals are cheap by comparison; '
          'risk-reversals (long call / short put) are the structurally favoured trade.';
    }
    if (rho < -0.40 && nu < 0.70) {
      return 'Heavy directional skew with a flat smile. The surface prices a '
          'grind-lower (ρ=${rho.toStringAsFixed(2)}) rather than a sharp gap: '
          'near-ATM put spreads capture the skew premium without paying up for '
          'expensive wings. Strangles are not especially rich despite the skew — '
          'wings are barely priced (ν=${nu.toStringAsFixed(2)}). Bearish debit '
          'spreads and bear put spreads have the best risk/reward here.';
    }
    if (rho < -0.40) {
      return 'Strong put skew dominates (ρ=${rho.toStringAsFixed(2)}). Crash '
          'protection is priced in; put buyers face elevated premium. Selling '
          'OTM call spreads above resistance may have edge if the bias is neutral '
          'to bearish. Risk-reversals (short put / long call) are expensive to '
          'enter — wait for a vol spike before buying protection.';
    }

    // ── Upside / call skew ────────────────────────────────────────────────────
    if (rho > 0.20 && nu > 1.00) {
      return 'Upside skew with elevated wings. Calls are bid over equivalent puts '
          '(ρ=${rho.toStringAsFixed(2)}) and vol-of-vol is elevated '
          '(ν=${nu.toStringAsFixed(2)}), suggesting active call-buying or squeeze '
          'positioning. OTM call premiums are elevated — prefer call spreads over '
          'naked long calls. Risk-reversals lean bullish; confirm with open interest.';
    }
    if (rho > 0.20) {
      return 'Call skew — unusual for equities. Upside positioning visible '
          '(ρ=${rho.toStringAsFixed(2)}); OTM calls priced richer than equivalent '
          'puts. Risk-reversals lean bullish. Wings are not especially fat '
          '(ν=${nu.toStringAsFixed(2)}), so naked long calls carry less curvature '
          'risk than usual. Confirm with open interest before fading the skew.';
    }

    // ── Symmetric / mild put skew — differentiate by wing shape and vol level ─
    if (nu > 1.50 && alpha > 0.60) {
      return 'High-vol, wide-smile environment. ATM vol is elevated '
          '(α=${alpha.toStringAsFixed(2)}) and OTM wings are expensive '
          '(ν=${nu.toStringAsFixed(2)}). Premium sellers have structural edge — '
          'iron condors and credit spreads capture elevated premium but need wide '
          'leg placement to clear the wing cost. Butterflies may be overpriced. '
          'Let theta work; manage winners at 50%.';
    }
    if (nu > 1.50 && alpha < 0.30) {
      return 'Cheap ATM vol with expensive wings. ATM straddles are inexpensive '
          '(α=${alpha.toStringAsFixed(2)}) while OTM wings command a premium '
          '(ν=${nu.toStringAsFixed(2)}). Classic butterfly opportunity: long the '
          'ATM straddle, short OTM strangles to pocket the wing premium. Long '
          'calendar spreads also benefit — sell elevated near-term wing, '
          'buy cheaper back-month ATM vol.';
    }
    if (nu > 1.50) {
      return 'Wide smile at moderate vol. OTM options are expensive relative to '
          'ATM (ν=${nu.toStringAsFixed(2)}); defined-risk credit structures — '
          'iron condors, credit spreads — are more capital-efficient than buying '
          'OTM options outright. Straddle vs strangle edge exists for short-vol '
          'traders willing to manage the wings.';
    }
    if (nu < 0.70 && alpha > 0.60) {
      return 'Expensive ATM with a flat smile. Vol is elevated at the money '
          '(α=${alpha.toStringAsFixed(2)}) but OTM wings are barely priced '
          '(ν=${nu.toStringAsFixed(2)}). Short ATM premium with cheap OTM '
          'protection is attractive: jade lizard, back-ratio spreads, or '
          'selling ATM straddles hedged with OTM wings. Avoid naked short '
          'straddles given the high absolute vol level.';
    }
    if (nu < 0.70 && alpha < 0.30) {
      return 'Low-vol, flat-smile regime. Cheapest premium environment on both '
          'ATM (α=${alpha.toStringAsFixed(2)}) and OTM (ν=${nu.toStringAsFixed(2)}) '
          'dimensions. Directional debit trades — long calls, long puts, debit '
          'spreads — offer the best risk/reward when vol is this compressed. '
          'Gamma is inexpensive; a catalyst move is under-priced by the surface.';
    }
    if (nu < 0.70) {
      return 'Flat smile, moderate vol. Wings are barely priced '
          '(ν=${nu.toStringAsFixed(2)}); strangles and ratio spreads may offer '
          'value for traders with a directional view. No structural edge favouring '
          'a particular strategy — lean on IVR/IVP percentile for vol regime context.';
    }

    // ── Moderate wings, differentiate by vol level ────────────────────────────
    if (alpha > 0.60) {
      return 'Normal surface structure with elevated ATM vol '
          '(α=${alpha.toStringAsFixed(2)}). Credit spreads and iron condors have '
          'structural edge — premium is historically elevated. Monitor IVR/IVP '
          'percentile to confirm before putting on credit; exit positions at 50% '
          'profit to avoid late-cycle gamma risk.';
    }
    if (alpha < 0.30) {
      return 'Normal surface structure with compressed ATM vol '
          '(α=${alpha.toStringAsFixed(2)}). Debit structures are historically '
          'cheap. Long debit spreads, long straddles near catalysts, or long '
          'single legs with defined risk are favoured. Credit sellers face '
          'thinner premium — wait for vol to expand before shorting.';
    }

    return 'Balanced surface within normal equity ranges '
        '(ρ=${rho.toStringAsFixed(2)}, ν=${nu.toStringAsFixed(2)}, '
        'α=${alpha.toStringAsFixed(2)}). No single structural edge identified. '
        'Let IVR/IVP percentile, open-interest distribution, and directional '
        'thesis drive strategy selection rather than surface shape alone.';
  }

  // Term-structure note comparing front vs back reliable slice.
  // Returns null if there is insufficient data for a meaningful comparison.
  static String? termNote(List<SabrSlice> slices) {
    final reliable = slices.where((s) => s.isReliable).toList();
    if (reliable.length < 2) return null;

    final front = reliable.first;
    final back  = reliable.last;

    // ν term structure — most informative for event detection
    if (front.nu > back.nu * 1.35) {
      return 'Front ν (${front.nu.toStringAsFixed(2)}) >> '
          'back ν (${back.nu.toStringAsFixed(2)}) — near-term event vol priced in. '
          'Front OTM options are expensive; selling front-month premium into the '
          'event and buying back-month protection (calendar spreads) may offer edge '
          'if vol crush is expected post-catalyst.';
    }
    if (back.nu > front.nu * 1.35) {
      return 'Back ν (${back.nu.toStringAsFixed(2)}) >> '
          'front ν (${front.nu.toStringAsFixed(2)}) — longer-dated wing uncertainty '
          'elevated. Calendar spreads (short back-dated OTM, long front ATM) may '
          'exploit the wing premium differential.';
    }

    // α (ATM vol) term structure
    if (front.alpha > back.alpha * 1.30) {
      return 'Inverted vol term structure: front α (${front.alpha.toStringAsFixed(2)}) '
          '>> back α (${back.alpha.toStringAsFixed(2)}). Near-term premium is '
          'elevated vs longer-dated — classic pre-event inversion. Calendar spreads '
          '(sell front ATM, buy back ATM) benefit from vol-term normalisation.';
    }
    if (back.alpha > front.alpha * 1.20) {
      return 'Contango vol term structure: back α (${back.alpha.toStringAsFixed(2)}) '
          '>> front α (${front.alpha.toStringAsFixed(2)}). Longer-dated premium '
          'elevated; diagonal spreads or back-month credit may have edge.';
    }

    // ρ flip across term — skew changing sign or direction
    if ((front.rho < -0.25 && back.rho > 0.0) ||
        (front.rho > 0.0 && back.rho < -0.25)) {
      return 'Skew direction shifts across the term structure '
          '(front ρ ${front.rho.toStringAsFixed(2)} → '
          'back ρ ${back.rho.toStringAsFixed(2)}). '
          'Unusual divergence — check for data quality or illiquidity in '
          'back-dated strikes before trading on the back-month skew.';
    }

    return null;
  }
}

class _SabrCard extends ConsumerWidget {
  final VolSnapshot snap;
  const _SabrCard({required this.snap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sabrCalibrationProvider(snap.ticker));
    return _Card(
      width: 300,
      label: 'SABR CALIBRATION',
      child: async.when(
        loading: () => const Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Color(0xFF3b82f6)),
          ),
        ),
        error: (_, _) => const Text(
          'Unavailable',
          style: TextStyle(
              color: Color(0xFF6b7280),
              fontSize: 9,
              fontFamily: 'monospace'),
        ),
        data: (slices) {
          if (slices.isEmpty) {
            return const Text(
              'No surface data\nfor this ticker.',
              style: TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 9,
                  height: 1.5,
                  fontFamily: 'monospace'),
            );
          }

          // Front reliable slice for interpretation; fall back to first if none reliable.
          final front = slices.firstWhere((s) => s.isReliable,
              orElse: () => slices.first);
          final read = _SabrRead.from(front);

          final visible = slices.take(6).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Parameter table ────────────────────────────────────────────
              Row(children: const [
                SizedBox(
                    width: 28,
                    child: Text('DTE',
                        style: TextStyle(
                            color: Color(0xFF4b5563),
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace'))),
                SizedBox(
                    width: 38,
                    child: Text('α (vol)',
                        style: TextStyle(
                            color: Color(0xFF4b5563),
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace'))),
                SizedBox(
                    width: 38,
                    child: Text('ρ (skew)',
                        style: TextStyle(
                            color: Color(0xFF4b5563),
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace'))),
                SizedBox(
                    width: 38,
                    child: Text('ν (wings)',
                        style: TextStyle(
                            color: Color(0xFF4b5563),
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace'))),
                Text('RMSE',
                    style: TextStyle(
                        color: Color(0xFF4b5563),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace')),
              ]),
              const SizedBox(height: 4),
              for (final s in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    SizedBox(
                        width: 28,
                        child: Text('${s.dte}d',
                            style: TextStyle(
                                color: s.dte == front.dte
                                    ? const Color(0xFFd1d5db)
                                    : const Color(0xFF6b7280),
                                fontSize: 8,
                                fontWeight: s.dte == front.dte
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                                fontFamily: 'monospace'))),
                    SizedBox(
                        width: 38,
                        child: Text(s.alpha.toStringAsFixed(2),
                            style: const TextStyle(
                                color: Color(0xFF60a5fa),
                                fontSize: 8,
                                fontFamily: 'monospace'))),
                    SizedBox(
                        width: 38,
                        child: Text(s.rho.toStringAsFixed(2),
                            style: TextStyle(
                                color: s.rho < 0
                                    ? const Color(0xFFf87171)
                                    : const Color(0xFF4ade80),
                                fontSize: 8,
                                fontFamily: 'monospace'))),
                    SizedBox(
                        width: 38,
                        child: Text(s.nu.toStringAsFixed(2),
                            style: const TextStyle(
                                color: Color(0xFFfbbf24),
                                fontSize: 8,
                                fontFamily: 'monospace'))),
                    Text('${(s.rmse * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                            color: s.rmse < 0.015
                                ? const Color(0xFF4ade80)
                                : s.rmse < 0.030
                                    ? const Color(0xFFfbbf24)
                                    : const Color(0xFFf87171),
                            fontSize: 8,
                            fontFamily: 'monospace')),
                  ]),
                ),
              if (slices.length > 6) ...[
                const SizedBox(height: 2),
                Text('+${slices.length - 6} more',
                    style: const TextStyle(
                        color: Color(0xFF4b5563),
                        fontSize: 8,
                        fontFamily: 'monospace')),
              ],

              // ── Interpretation ─────────────────────────────────────────────
              const SizedBox(height: 10),
              const Divider(color: Color(0xFF1f2937), height: 1),
              const SizedBox(height: 8),
              Row(children: [
                const Text('SABR READ  ',
                    style: TextStyle(
                        color: Color(0xFF4b5563),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        fontFamily: 'monospace')),
                Text('(${front.dte}d slice)',
                    style: const TextStyle(
                        color: Color(0xFF374151),
                        fontSize: 8,
                        fontFamily: 'monospace')),
                if (!read.isReliable) ...[
                  const SizedBox(width: 4),
                  const Text('⚠ low data',
                      style: TextStyle(
                          color: Color(0xFFfbbf24),
                          fontSize: 7,
                          fontFamily: 'monospace')),
                ],
              ]),
              const SizedBox(height: 6),

              // Skew (ρ)
              _SabrReadRow(
                paramLabel: 'ρ SKEW',
                chipLabel:  read.skewLabel,
                chipColor:  read.skewColor,
                detail:     read.skewDetail,
              ),
              const SizedBox(height: 6),

              // Wings (ν)
              _SabrReadRow(
                paramLabel: 'ν WINGS',
                chipLabel:  read.wingsLabel,
                chipColor:  read.wingsColor,
                detail:     read.wingsDetail,
              ),
              const SizedBox(height: 6),

              // Alpha (α)
              _SabrReadRow(
                paramLabel: 'α LEVEL',
                chipLabel:  read.alphaLabel,
                chipColor:  read.alphaColor,
                detail:     read.alphaDetail,
              ),
              const SizedBox(height: 6),

              // Fit quality
              Row(children: [
                const Text('FIT  ',
                    style: TextStyle(
                        color: Color(0xFF4b5563),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        fontFamily: 'monospace')),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: read.fitColor.withValues(alpha: 0.12),
                    border: Border.all(color: read.fitColor.withValues(alpha: 0.40)),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(read.fitLabel,
                      style: TextStyle(
                          color: read.fitColor,
                          fontSize: 7,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          fontFamily: 'monospace')),
                ),
                const SizedBox(width: 5),
                Text(
                  'RMSE ${(front.rmse * 100).toStringAsFixed(2)}%  '
                  '·  n=${front.nPoints}',
                  style: const TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 8,
                      fontFamily: 'monospace'),
                ),
              ]),
              if (front.rmse >= 0.030) ...[
                const SizedBox(height: 3),
                const Text(
                  'Poor fit may indicate illiquid strikes or arb violations '
                  'distorting the calibration. Check the ARB CHECK card.',
                  style: TextStyle(
                      color: Color(0xFFf87171),
                      fontSize: 8,
                      height: 1.4,
                      fontFamily: 'monospace'),
                ),
              ],

              // ── Surface Read (cross-param synthesis) ───────────────────────
              const SizedBox(height: 10),
              const Divider(color: Color(0xFF1f2937), height: 1),
              const SizedBox(height: 8),
              Row(children: [
                const Text('SURFACE READ  ',
                    style: TextStyle(
                        color: Color(0xFF4b5563),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        fontFamily: 'monospace')),
                const Text('ρ × ν × α',
                    style: TextStyle(
                        color: Color(0xFF374151),
                        fontSize: 8,
                        fontFamily: 'monospace')),
              ]),
              const SizedBox(height: 5),
              Text(read.synthesis,
                  style: const TextStyle(
                      color: Color(0xFF9ca3af),
                      fontSize: 8,
                      height: 1.5,
                      fontFamily: 'monospace')),

              // ── Term structure note (only shown when data supports it) ─────
              Builder(builder: (_) {
                final note = _SabrRead.termNote(slices);
                if (note == null) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    const Divider(color: Color(0xFF1f2937), height: 1),
                    const SizedBox(height: 8),
                    const Text('TERM STRUCTURE',
                        style: TextStyle(
                            color: Color(0xFF4b5563),
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.9,
                            fontFamily: 'monospace')),
                    const SizedBox(height: 5),
                    Text(note,
                        style: const TextStyle(
                            color: Color(0xFF9ca3af),
                            fontSize: 8,
                            height: 1.5,
                            fontFamily: 'monospace')),
                  ],
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

// Small reusable row: label chip + detail text.
class _SabrReadRow extends StatelessWidget {
  final String paramLabel;
  final String chipLabel;
  final Color  chipColor;
  final String detail;

  const _SabrReadRow({
    required this.paramLabel,
    required this.chipLabel,
    required this.chipColor,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('$paramLabel  ',
              style: const TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  fontFamily: 'monospace')),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.12),
              border: Border.all(color: chipColor.withValues(alpha: 0.40)),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(chipLabel,
                style: TextStyle(
                    color: chipColor,
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    fontFamily: 'monospace')),
          ),
        ]),
        const SizedBox(height: 2),
        Text(detail,
            style: const TextStyle(
                color: Color(0xFF6b7280),
                fontSize: 8,
                height: 1.4,
                fontFamily: 'monospace')),
      ],
    );
  }
}

// ── Arb check card ────────────────────────────────────────────────────────────

class _ArbCard extends StatefulWidget {
  final VolSnapshot snap;
  const _ArbCard({required this.snap});

  @override
  State<_ArbCard> createState() => _ArbCardState();
}

class _ArbCardState extends State<_ArbCard> {
  late Future<ArbCheckResult> _future;

  @override
  void initState() {
    super.initState();
    _future = checkArbForSnap(widget.snap);
  }

  @override
  void didUpdateWidget(_ArbCard old) {
    super.didUpdateWidget(old);
    if (old.snap.ticker != widget.snap.ticker ||
        old.snap.obsDateStr != widget.snap.obsDateStr ||
        old.snap.points.length != widget.snap.points.length) {
      final f = checkArbForSnap(widget.snap);
      setState(() => _future = f);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Card(
      width: 210,
      label: 'ARB CHECK',
      child: FutureBuilder<ArbCheckResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Color(0xFF3b82f6)),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Text(
              'Unavailable',
              style: TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 9,
                  fontFamily: 'monospace'),
            );
          }
          final result = snapshot.data!;
          if (result.isArbitrageFree) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4ade80).withValues(alpha: 0.12),
                    border: Border.all(
                        color: const Color(0xFF4ade80).withValues(alpha: 0.40)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('ARB-FREE ✓',
                      style: TextStyle(
                          color: Color(0xFF4ade80),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          fontFamily: 'monospace')),
                ),
                const SizedBox(height: 6),
                const Text(
                  'No calendar or butterfly\nviolations detected.',
                  style: TextStyle(
                      color: Color(0xFF6b7280),
                      fontSize: 9,
                      height: 1.4,
                      fontFamily: 'monospace'),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFf87171).withValues(alpha: 0.12),
                  border: Border.all(
                      color: const Color(0xFFf87171).withValues(alpha: 0.40)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                    '${result.totalViolations} ARB VIOLATION${result.totalViolations == 1 ? '' : 'S'}',
                    style: const TextStyle(
                        color: Color(0xFFf87171),
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        fontFamily: 'monospace')),
              ),
              const SizedBox(height: 6),
              if (result.calendarViolations.isNotEmpty) ...[
                Text('Cal: ${result.calendarViolations.length}',
                    style: const TextStyle(
                        color: Color(0xFFfbbf24),
                        fontSize: 9,
                        fontFamily: 'monospace')),
                for (final v in result.calendarViolations.take(2))
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 1),
                    child: Text(
                      'K\$${v.strike.toStringAsFixed(0)} ${v.nearDte}d→${v.farDte}d',
                      style: const TextStyle(
                          color: Color(0xFF6b7280),
                          fontSize: 8,
                          fontFamily: 'monospace'),
                    ),
                  ),
              ],
              if (result.butterflyViolations.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Fly: ${result.butterflyViolations.length}',
                    style: const TextStyle(
                        color: Color(0xFFf87171),
                        fontSize: 9,
                        fontFamily: 'monospace')),
                for (final v in result.butterflyViolations.take(2))
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 1),
                    child: Text(
                      '${v.dte}d K\$${v.strike.toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: Color(0xFF6b7280),
                          fontSize: 8,
                          fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ── Shared card shell ─────────────────────────────────────────────────────────

// ── Risk-Neutral Density card ─────────────────────────────────────────────────

class _RndCard extends StatelessWidget {
  final AsyncValue<IvAnalysis> ivAsync;
  const _RndCard({required this.ivAsync});

  @override
  Widget build(BuildContext context) {
    return ivAsync.when(
      loading: () => _Card(
        width: 260,
        label: 'IMPLIED DISTRIBUTION',
        child: const Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Color(0xFF4b5563)),
          ),
        ),
      ),
      error: (e, _) => _Card(
        width: 260,
        label: 'IMPLIED DISTRIBUTION',
        child: Text(
          'RND unavailable.\n${e.toString().split(':').first}',
          style: const TextStyle(
              color: Color(0xFFf87171),
              fontSize: 9,
              height: 1.5,
              fontFamily: 'monospace'),
        ),
      ),
      data: (ivAnalysis) {
        final rnd = ivAnalysis.rnd;
        final RndSlice? slice = rnd.isEmpty
            ? null
            : rnd.firstWhere((s) => s.reliable, orElse: () => rnd.first);
        return _Card(
          width: 260,
          label: slice != null
              ? 'IMPLIED DISTRIBUTION  (${slice.dte}d)'
              : 'IMPLIED DISTRIBUTION',
          child: slice == null
              ? const Text(
                  'No surface data.\nLoad the options chain to compute\nthe risk-neutral density.',
                  style: TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 9,
                      height: 1.5,
                      fontFamily: 'monospace'),
                )
              : _RndContent(slice: slice),
        );
      },
    );
  }
}

class _RndContent extends StatelessWidget {
  final RndSlice slice;
  const _RndContent({required this.slice});

  @override
  Widget build(BuildContext context) {
    final m = slice.moments;
    final spot = slice.nearestByProbAbove(0.50)?.strike;

    // ── Skewness chip ──────────────────────────────────────────────────────────
    final (skewLabel, skewColor, skewDetail) = m.skewness < -0.40
        ? ('CRASH RISK', const Color(0xFFf87171),
            'Left tail fat (skew=${m.skewness.toStringAsFixed(2)}). '
            'Market assigns excess probability to sharp downside moves. '
            'OTM puts are structurally bid; put spreads cost more than equivalent call spreads.')
        : m.skewness > 0.40
            ? ('LOTTERY TAIL', const Color(0xFF4ade80),
                'Right tail fat (skew=${m.skewness.toStringAsFixed(2)}). '
                'Market prices in rare but explosive upside. '
                'Far OTM calls trade rich; typical in biotech / catalyst names.')
            : ('SYMMETRIC', const Color(0xFF60a5fa),
                'Near-symmetric distribution (skew=${m.skewness.toStringAsFixed(2)}). '
                'Balanced tail pricing — no structural directional bias '
                'implied by the option surface.');

    // ── Kurtosis chip ──────────────────────────────────────────────────────────
    final (kurtLabel, kurtColor, kurtDetail) = m.kurtosis > 1.50
        ? ('FAT TAILS', const Color(0xFFfbbf24),
            'Excess kurtosis ${m.kurtosis.toStringAsFixed(2)} — distribution significantly '
            'fatter than lognormal. Binary-outcome risk elevated; '
            'standard delta-based hedges underestimate tail exposure.')
        : m.kurtosis < -0.50
            ? ('THIN TAILS', const Color(0xFF4ade80),
                'Excess kurtosis ${m.kurtosis.toStringAsFixed(2)} — thinner than lognormal. '
                'Market discounts extreme moves; wings are relatively cheap.')
            : ('NORMAL TAILS', const Color(0xFF60a5fa),
                'Excess kurtosis ${m.kurtosis.toStringAsFixed(2)} — tails consistent with '
                'lognormal pricing. No unusual tail-risk premium.');

    // ── Reliability warning ────────────────────────────────────────────────────
    final bool warn = !slice.reliable;

    // ── Strike probability table ───────────────────────────────────────────────
    // Pick 5 representative probability levels to display.
    final targets = [0.85, 0.65, 0.50, 0.35, 0.15];
    final tableRows = targets
        .map((p) => slice.nearestByProbAbove(p))
        .whereType<RndPoint>()
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Skew chip + detail ─────────────────────────────────────────────────
        _SabrReadRow(
          paramLabel: 'SKEW',
          chipLabel:  skewLabel,
          chipColor:  skewColor,
          detail:     skewDetail,
        ),
        const SizedBox(height: 6),

        // ── Kurtosis chip + detail ─────────────────────────────────────────────
        _SabrReadRow(
          paramLabel: 'TAILS',
          chipLabel:  kurtLabel,
          chipColor:  kurtColor,
          detail:     kurtDetail,
        ),
        const SizedBox(height: 10),

        // ── Moments summary line ───────────────────────────────────────────────
        Text(
          'σ_rnd=${(m.impliedVol * 100).toStringAsFixed(1)}%  '
          'ρ=${slice.sabrRho.toStringAsFixed(2)}  '
          'ν=${slice.sabrNu.toStringAsFixed(2)}',
          style: const TextStyle(
              color: Color(0xFF6b7280),
              fontSize: 8,
              fontFamily: 'monospace'),
        ),

        // ── Fit warning ────────────────────────────────────────────────────────
        if (warn) ...[
          const SizedBox(height: 3),
          const Text(
            '⚠ Low-confidence fit — interpret with caution',
            style: TextStyle(
                color: Color(0xFFfbbf24),
                fontSize: 8,
                fontFamily: 'monospace'),
          ),
        ],

        // ── Probability table ──────────────────────────────────────────────────
        const SizedBox(height: 10),
        const Divider(color: Color(0xFF1f2937), height: 1),
        const SizedBox(height: 6),
        Row(children: const [
          SizedBox(width: 56,
              child: Text('STRIKE', style: TextStyle(color: Color(0xFF4b5563), fontSize: 8, fontWeight: FontWeight.w700, fontFamily: 'monospace'))),
          SizedBox(width: 52,
              child: Text('P(ABOVE)', style: TextStyle(color: Color(0xFF4b5563), fontSize: 8, fontWeight: FontWeight.w700, fontFamily: 'monospace'))),
          Text('P(BELOW)', style: TextStyle(color: Color(0xFF4b5563), fontSize: 8, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 4),
        for (final p in tableRows) ...[
          _ProbRow(point: p, isAtm: spot != null && p.strike == spot),
          const SizedBox(height: 2),
        ],
      ],
    );
  }
}

class _ProbRow extends StatelessWidget {
  final RndPoint point;
  final bool isAtm;
  const _ProbRow({required this.point, required this.isAtm});

  @override
  Widget build(BuildContext context) {
    final strikeStr = point.strike >= 1000
        ? point.strike.toStringAsFixed(0)
        : point.strike.toStringAsFixed(2);
    final abovePct = (point.probAbove * 100).toStringAsFixed(1);
    final belowPct = (point.probBelow * 100).toStringAsFixed(1);
    final color = isAtm ? const Color(0xFFd1d5db) : const Color(0xFF6b7280);

    return Row(children: [
      SizedBox(
        width: 56,
        child: Row(children: [
          Text('\$$strikeStr', style: TextStyle(color: color, fontSize: 8, fontFamily: 'monospace')),
          if (isAtm) ...[
            const SizedBox(width: 3),
            const Text('ATM', style: TextStyle(color: Color(0xFF4b5563), fontSize: 7, fontFamily: 'monospace')),
          ],
        ]),
      ),
      SizedBox(
        width: 52,
        child: Text('$abovePct%',
            style: TextStyle(
                color: point.probAbove > 0.5
                    ? const Color(0xFF4ade80)
                    : const Color(0xFFf87171),
                fontSize: 8,
                fontFamily: 'monospace')),
      ),
      Text('$belowPct%',
          style: TextStyle(
              color: point.probBelow > 0.5
                  ? const Color(0xFFf87171)
                  : const Color(0xFF4ade80),
              fontSize: 8,
              fontFamily: 'monospace')),
    ]);
  }
}

// ── Shared card shell ─────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final double width;
  final String label;
  final Widget child;

  const _Card({
    required this.width,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xFF1f2937))),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  fontFamily: 'monospace')),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
