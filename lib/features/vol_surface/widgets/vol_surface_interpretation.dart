// =============================================================================
// vol_surface/widgets/vol_surface_interpretation.dart
// Plain-English interpretation panel — shown below heatmap/smile/diff.
// Analyzes the active snapshot and surfaces IV level, term structure,
// smile skew, and 2-3 key reads without requiring a specific trade.
// =============================================================================
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/vol_surface_models.dart';

// ── Private analysis ──────────────────────────────────────────────────────────

enum _Term { contango, flat, backwardation }
enum _Skew { putBid, symmetric, callBid }
enum _GammaRegime { positive, negative, neutral }

// ── Gamma wall data ────────────────────────────────────────────────────────────
// Dealers are assumed net-short options (they sell to retail/institutions).
// Large call OI → dealers long delta hedge → price ceiling (call wall).
// Large put OI → dealers short delta hedge → price floor (put wall).
// Net GEX = callOI − putOI. Positive net = dealers absorb price moves (stable).
// Negative net = dealers amplify price moves (unstable / trending).

class _WallStrike {
  final double strike;
  final int    callOI;
  final int    putOI;
  int get netGex => callOI - putOI; // + = call-dominated
  const _WallStrike({required this.strike, required this.callOI, required this.putOI});
}

class _GammaData {
  final List<_WallStrike> callWalls; // top strikes by call OI, above spot
  final List<_WallStrike> putWalls;  // top strikes by put OI,  below spot
  final double?           gexFlip;   // approx price where net GEX → 0
  final _GammaRegime      regime;    // net gamma sign at spot
  final int               totalCallOI;
  final int               totalPutOI;

  const _GammaData({
    required this.callWalls,
    required this.putWalls,
    required this.gexFlip,
    required this.regime,
    required this.totalCallOI,
    required this.totalPutOI,
  });

  static const _empty = _GammaData(
    callWalls: [], putWalls: [], gexFlip: null,
    regime: _GammaRegime.neutral, totalCallOI: 0, totalPutOI: 0,
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

    // Top 3 call walls: highest call OI above spot (resistance)
    final callWalls = [...above]
      ..sort((a, b) => b.callOI.compareTo(a.callOI));
    final topCalls = callWalls.take(3).toList()
      ..sort((a, b) => a.strike.compareTo(b.strike)); // re-sort asc by strike

    // Top 3 put walls: highest put OI below spot (support)
    final putWalls = [...below]
      ..sort((a, b) => b.putOI.compareTo(a.putOI));
    final topPuts = putWalls.take(3).toList()
      ..sort((a, b) => b.strike.compareTo(a.strike)); // re-sort desc (nearest first)

    // ── Net GEX regime at spot ─────────────────────────────────────────────
    // Use the single strike nearest to spot to determine current regime.
    _GammaRegime regime = _GammaRegime.neutral;
    if (spot != null && all.isNotEmpty) {
      final nearest = all.reduce((a, b) =>
          (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
      final net = nearest.netGex;
      if (net > 0) {
        regime = _GammaRegime.positive;
      } else if (net < 0) {
        regime = _GammaRegime.negative;
      }
    }

    // ── GEX flip price ─────────────────────────────────────────────────────
    // Walk strikes from near-spot outward; find first transition where
    // cumulative net GEX sign flips relative to at-spot net GEX.
    double? flip;
    if (spot != null && all.length >= 2) {
      // Build cumulative GEX profile from closest to farthest strike
      final sortedByDist = [...all]
        ..sort((a, b) => (a.strike - spot).abs().compareTo((b.strike - spot).abs()));
      int cumGex = 0;
      int? firstSign;
      for (final w in sortedByDist) {
        cumGex += w.netGex;
        firstSign ??= cumGex.sign;
        if (cumGex.sign != 0 && cumGex.sign != firstSign) {
          flip = w.strike;
          break;
        }
      }
    }

    return _GammaData(
      callWalls:    topCalls,
      putWalls:     topPuts,
      gexFlip:      flip,
      regime:       regime,
      totalCallOI:  totalC,
      totalPutOI:   totalP,
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

class VolSurfaceInterpretation extends StatelessWidget {
  final VolSnapshot snap;
  final String ivMode;

  const VolSurfaceInterpretation({
    super.key,
    required this.snap,
    required this.ivMode,
  });

  @override
  Widget build(BuildContext context) {
    final a = _A.from(snap);

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
                  _IvCard(a: a),
                  _TermCard(a: a),
                  _SkewCard(a: a),
                  _WallsCard(snap: snap),
                  _FlowCard(snap: snap),
                  _ReadsCard(a: a),
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
  const _IvCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final iv   = a.atmIvFront;
    final pct  = a.atmPct;

    final (label, color) = switch (pct) {
      < 0.30 => ('LOW IV', const Color(0xFF4ade80)),
      < 0.60 => ('NORMAL IV', const Color(0xFF60a5fa)),
      < 0.80 => ('ELEVATED IV', const Color(0xFFfbbf24)),
      _      => ('HIGH IV', const Color(0xFFf87171)),
    };

    final String sub = switch (pct) {
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
            '${(pct * 100).toStringAsFixed(0)}th pct of surface',
            style: const TextStyle(
                color: Color(0xFF6b7280),
                fontSize: 9,
                fontFamily: 'monospace'),
          ),
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
            'Surface p5–p95: ${(a.surfaceMin * 100).toStringAsFixed(0)}–'
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
  const _SkewCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final (label, color, headline, sub) = switch (a.skew) {
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

    final pcr = a.putCallRatio.toStringAsFixed(2);

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
  const _ReadsCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final reads = _keyReads(a);

    return _Card(
      width: 240,
      label: 'KEY READS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    reads[i].startsWith('⚠')
                        ? reads[i].substring(2)
                        : reads[i],
                    style: TextStyle(
                        color: reads[i].startsWith('⚠')
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
  const _FlowCard({required this.snap});

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
    final volPcr   = totalCallVol > 0 ? totalPutVol / totalCallVol : 1.0;

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

class _WallsCard extends StatelessWidget {
  final VolSnapshot snap;
  const _WallsCard({required this.snap});

  @override
  Widget build(BuildContext context) {
    final g = _GammaData.from(snap);
    final spot = snap.spotPrice;

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

    final (regimeLabel, regimeColor, regimeSub) = switch (g.regime) {
      _GammaRegime.positive => (
          'POS GAMMA',
          const Color(0xFF4ade80),
          'Dealers absorb moves — expect mean-reversion near walls',
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

    String fmtK(int n) {
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000)    return '${(n / 1000).toStringAsFixed(0)}K';
      return n.toString();
    }

    String fmtStrike(double s) =>
        '\$${s == s.truncateToDouble() ? s.toInt() : s.toStringAsFixed(1)}';

    return _Card(
      width: 220,
      label: 'GAMMA WALLS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Regime chip
          Container(
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
                    letterSpacing: 0.6,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 4),
          Text(regimeSub,
              style: const TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 8,
                  height: 1.35,
                  fontFamily: 'monospace')),
          const SizedBox(height: 8),

          // Call walls (resistance above spot)
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

          // Put walls (support below spot)
          if (g.putWalls.isNotEmpty) ...[
            const Text('PUT WALLS  (support)',
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
            const SizedBox(height: 6),
          ],

          // GEX flip
          if (g.gexFlip != null) ...[
            Row(children: [
              const Text('GEX flip  ',
                  style: TextStyle(
                      color: Color(0xFF4b5563),
                      fontSize: 8,
                      fontFamily: 'monospace')),
              Text(fmtStrike(g.gexFlip!),
                  style: const TextStyle(
                      color: Color(0xFFfbbf24),
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
            ]),
            const Text('Price where dealer hedging flips',
                style: TextStyle(
                    color: Color(0xFF4b5563),
                    fontSize: 8,
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
