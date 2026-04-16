// =============================================================================
// features/greek_grid/services/greek_interpreter.dart
// =============================================================================
// Pure computation — no Flutter/UI dependencies.
//
// interpretGreekGrid   → used by GreekGridScreen
// interpretGreekChart  → used by GreekChartScreen (ATM time-series)
//
// Each returns an InterpretationResult with:
//   • headline    — single most notable finding
//   • today       — per-metric observations for the selected/latest snapshot
//   • period      — trend observations across all tracked history
// =============================================================================

import '../../../services/greeks/greek_snapshot_models.dart';
import '../models/greek_grid_models.dart';

// ── Output model ──────────────────────────────────────────────────────────────

enum InterpretationSignal { neutral, bullish, bearish, caution }

class InterpretationLine {
  final String               label;
  final String               text;
  final InterpretationSignal signal;
  const InterpretationLine(this.label, this.text, this.signal);
}

class InterpretationResult {
  final String               headline;
  final InterpretationSignal headlineSignal;
  final List<InterpretationLine> today;
  final List<InterpretationLine> period;
  final int                  periodObs;

  const InterpretationResult({
    required this.headline,
    required this.headlineSignal,
    required this.today,
    required this.period,
    required this.periodObs,
  });

  bool get hasData => today.isNotEmpty || period.isNotEmpty;
}

// ── Greek Grid interpreter ─────────────────────────────────────────────────────
//
// snapshot  — the currently selected date's cells (null = no data yet)
// allPoints — every GreekGridPoint ever ingested for this ticker
//
// TODAY: reads the snapshot's cells directly.
// PERIOD: builds an ATM time-series from allPoints, first → last.

InterpretationResult interpretGreekGrid(
  GreekGridSnapshot?   snapshot,
  List<GreekGridPoint> allPoints,
  String               ticker,
) {
  final today  = <InterpretationLine>[];
  final period = <InterpretationLine>[];

  // ── TODAY ──────────────────────────────────────────────────────────────────

  if (snapshot != null) {
    // 1. IV Term Structure ─────────────────────────────────────────────────────
    final shortIv = snapshot.cell(StrikeBand.atm, ExpiryBucket.weekly)?.iv
                 ?? snapshot.cell(StrikeBand.atm, ExpiryBucket.nearMonthly)?.iv;
    final longIv  = snapshot.cell(StrikeBand.atm, ExpiryBucket.quarterly)?.iv
                 ?? snapshot.cell(StrikeBand.atm, ExpiryBucket.farMonthly)?.iv
                 ?? snapshot.cell(StrikeBand.atm, ExpiryBucket.monthly)?.iv;

    if (shortIv != null && longIv != null && shortIv > 0 && longIv > 0) {
      final spread = (shortIv - longIv) * 100;
      if (spread > 3) {
        today.add(InterpretationLine(
          'IV Term Structure',
          'Inverted — short-term IV (${_pct(shortIv)}) exceeds long-term '
          '(${_pct(longIv)}) by ${spread.toStringAsFixed(1)}pp. Near-term '
          'event premium is priced in.',
          InterpretationSignal.caution,
        ));
      } else if (spread < -3) {
        today.add(InterpretationLine(
          'IV Term Structure',
          'Normal — long-term IV (${_pct(longIv)}) > short-term '
          '(${_pct(shortIv)}). Market pricing stability near-term.',
          InterpretationSignal.neutral,
        ));
      } else {
        today.add(InterpretationLine(
          'IV Term Structure',
          'Flat — short (${_pct(shortIv)}) ≈ long (${_pct(longIv)}). '
          'Uncertainty distributed evenly across expirations.',
          InterpretationSignal.neutral,
        ));
      }
    }

    // 2. Gamma Peak ─────────────────────────────────────────────────────────────
    GreekGridPoint? peakCell;
    double          peakGamma = 0;
    for (final band in StrikeBand.values) {
      for (final bucket in ExpiryBucket.values) {
        final p = snapshot.cell(band, bucket);
        if (p?.gamma != null && p!.gamma!.abs() > peakGamma) {
          peakGamma = p.gamma!.abs();
          peakCell  = p;
        }
      }
    }
    if (peakCell != null && peakGamma > 0) {
      final isAtm   = peakCell.strikeBand == StrikeBand.atm;
      final isShort = peakCell.expiryBucket == ExpiryBucket.weekly ||
                      peakCell.expiryBucket == ExpiryBucket.nearMonthly;
      final risk = isAtm && isShort
          ? 'Binary outcome risk elevated — price pinned near ATM into near-term expiry.'
          : isAtm
              ? 'Elevated delta hedging pressure on large moves from ATM.'
              : 'Off-centre concentration — less pin risk; ITM/OTM acceleration elevated.';
      today.add(InterpretationLine(
        'Gamma Peak',
        '${peakCell.strikeBand.label} · ${peakCell.expiryBucket.label}  '
        '(Γ ${peakGamma.toStringAsFixed(4)}).  $risk',
        isAtm && isShort ? InterpretationSignal.caution : InterpretationSignal.neutral,
      ));
    }

    // 3. Skew Bias ──────────────────────────────────────────────────────────────
    // OTM band aggregates OTM calls + ITM puts. Positive net delta there means
    // call demand dominates; negative means put hedging pressure.
    final refBucket = snapshot.cell(StrikeBand.otm, ExpiryBucket.nearMonthly) != null
        ? ExpiryBucket.nearMonthly
        : ExpiryBucket.monthly;
    final otmDelta = snapshot.cell(StrikeBand.otm, refBucket)?.delta;
    if (otmDelta != null) {
      if (otmDelta > 0.05) {
        today.add(InterpretationLine(
          'Skew Bias',
          'Call-side demand dominant — net OTM delta +${otmDelta.toStringAsFixed(2)}. '
          'Bullish positioning in out-of-the-money strikes.',
          InterpretationSignal.bullish,
        ));
      } else if (otmDelta < -0.05) {
        today.add(InterpretationLine(
          'Skew Bias',
          'Put-side hedging elevated — net OTM delta ${otmDelta.toStringAsFixed(2)}. '
          'Bearish protection being built in OTM options.',
          InterpretationSignal.bearish,
        ));
      }
    }

    // 4. Vanna ──────────────────────────────────────────────────────────────────
    // Vanna = ∂(delta)/∂(IV). Negative ATM vanna → rising IV suppresses call delta.
    final atm   = snapshot.cell(StrikeBand.atm, ExpiryBucket.nearMonthly)
               ?? snapshot.cell(StrikeBand.atm, ExpiryBucket.monthly);
    final vanna = atm?.vanna;
    if (vanna != null && vanna.abs() > 0.002) {
      if (vanna < -0.005) {
        today.add(InterpretationLine(
          'Vanna',
          'Negative ATM vanna (${vanna.toStringAsFixed(3)}) — rising IV will '
          'erode call delta. Vol expansion is a headwind for long calls.',
          InterpretationSignal.caution,
        ));
      } else if (vanna > 0.005) {
        today.add(InterpretationLine(
          'Vanna',
          'Positive ATM vanna (+${vanna.toStringAsFixed(3)}) — rising IV lifts '
          'call delta. Vol expansion supports long call positions.',
          InterpretationSignal.bullish,
        ));
      }
    }

    // 5. Charm ──────────────────────────────────────────────────────────────────
    // Charm = ∂(delta)/∂(time). Large magnitude in weekly means delta is
    // shifting rapidly each day as expiry approaches.
    final weeklyCharm = snapshot.cell(StrikeBand.atm, ExpiryBucket.weekly)?.charm;
    if (weeklyCharm != null && weeklyCharm.abs() > 0.01) {
      today.add(InterpretationLine(
        'Charm (Weekly)',
        'ATM weekly charm ${weeklyCharm.toStringAsFixed(3)} — delta '
        '${weeklyCharm < 0 ? "decaying toward" : "drifting away from"} '
        'ATM at ${weeklyCharm.abs().toStringAsFixed(3)}/day. '
        '${weeklyCharm.abs() > 0.05 ? "Expiry dynamics accelerating." : "Normal near-expiry erosion."}',
        weeklyCharm.abs() > 0.05 ? InterpretationSignal.caution : InterpretationSignal.neutral,
      ));
    }
  }

  // ── PERIOD ─────────────────────────────────────────────────────────────────

  // ATM time-series: use monthly, fall back to near-monthly if sparse
  List<GreekGridPoint> atmSeries = allPoints
      .where((p) => p.strikeBand == StrikeBand.atm &&
                    p.expiryBucket == ExpiryBucket.monthly)
      .toList()
    ..sort((a, b) => a.obsDate.compareTo(b.obsDate));
  if (atmSeries.length < 2) {
    atmSeries = allPoints
        .where((p) => p.strikeBand == StrikeBand.atm &&
                      (p.expiryBucket == ExpiryBucket.monthly ||
                       p.expiryBucket == ExpiryBucket.nearMonthly))
        .toList()
      ..sort((a, b) => a.obsDate.compareTo(b.obsDate));
  }

  final nObs = allPoints
      .map((p) => '${p.obsDate.year}-${p.obsDate.month}-${p.obsDate.day}')
      .toSet()
      .length;

  if (atmSeries.length >= 2) {
    final first = atmSeries.first;
    final last  = atmSeries.last;

    // IV trend
    if (first.iv != null && last.iv != null && first.iv! > 0) {
      final chg = (last.iv! - first.iv!) / first.iv! * 100;
      period.add(InterpretationLine(
        'IV Trend',
        '${chg > 5 ? "Expanding" : chg < -5 ? "Compressing" : "Stable"} — '
        'ATM IV ${_pct(first.iv!)} → ${_pct(last.iv!)} '
        '(${chg >= 0 ? "+" : ""}${chg.toStringAsFixed(1)}%) '
        'over $nObs observation${nObs == 1 ? "" : "s"}.',
        chg > 5 ? InterpretationSignal.caution
        : chg < -5 ? InterpretationSignal.bullish
        : InterpretationSignal.neutral,
      ));
    }

    // Gamma trend
    if (first.gamma != null && last.gamma != null && first.gamma! > 0) {
      final chg = (last.gamma! - first.gamma!) / first.gamma! * 100;
      if (chg.abs() > 15) {
        period.add(InterpretationLine(
          'Gamma Trend',
          '${chg > 0 ? "Rising" : "Falling"} ${chg.abs().toStringAsFixed(0)}% — '
          '${chg > 0
              ? "risk density building near ATM; market accumulating near-money strikes"
              : "gamma dispersing from ATM; underlying moving away from current strikes"}.',
          chg > 0 ? InterpretationSignal.caution : InterpretationSignal.neutral,
        ));
      }
    }

    // Volga trend (vol of vol)
    if (first.volga != null && last.volga != null && first.volga!.abs() > 1e-6) {
      final chg = (last.volga!.abs() - first.volga!.abs()) / first.volga!.abs() * 100;
      if (chg > 20) {
        period.add(InterpretationLine(
          'Volga (Vol-of-Vol)',
          'Rising ${chg.toStringAsFixed(0)}% — market paying more for vol '
          'convexity. Uncertainty about the volatility regime is expanding.',
          InterpretationSignal.caution,
        ));
      } else if (chg < -20) {
        period.add(InterpretationLine(
          'Volga (Vol-of-Vol)',
          'Compressing ${chg.abs().toStringAsFixed(0)}% — vol-of-vol declining. '
          'Market becoming comfortable with the current vol regime.',
          InterpretationSignal.neutral,
        ));
      }
    }

    // Vanna structural shift
    if (first.vanna != null && last.vanna != null) {
      if (first.vanna! > 0.002 && last.vanna! < -0.002) {
        period.add(InterpretationLine(
          'Vanna Shift',
          'Flipped negative over period — IV–delta relationship reversed. '
          'Rising vol now suppresses call delta; hedging flow is building.',
          InterpretationSignal.caution,
        ));
      } else if (first.vanna! < -0.002 && last.vanna! > 0.002) {
        period.add(InterpretationLine(
          'Vanna Shift',
          'Flipped positive over period — rising vol now supports call delta. '
          'Hedging flow becoming structurally supportive.',
          InterpretationSignal.bullish,
        ));
      }
    }
  }

  return _buildResult(today, period, nObs);
}

// ── Greek Chart interpreter ────────────────────────────────────────────────────
//
// history    — all GreekSnapshots for one DTE bucket, sorted oldest → newest
// dteBucket  — the target DTE (4, 7, or 31)
//
// TODAY: reads history.last.
// PERIOD: compares history.first vs history.last; uses full array for percentile.

InterpretationResult interpretGreekChart(
  List<GreekSnapshot> history,
  int dteBucket,
) {
  if (history.isEmpty) {
    return const InterpretationResult(
      headline:       'No data yet.',
      headlineSignal: InterpretationSignal.neutral,
      today:          [],
      period:         [],
      periodObs:      0,
    );
  }

  final today  = <InterpretationLine>[];
  final period = <InterpretationLine>[];
  final latest = history.last;

  // ── TODAY ──────────────────────────────────────────────────────────────────

  // 1. IV Skew (put IV − call IV) ─────────────────────────────────────────────
  final callIv = latest.callIv;
  final putIv  = latest.putIv;
  if (callIv != null && putIv != null && callIv > 0 && putIv > 0) {
    final skewPp = (putIv - callIv) * 100;
    if (skewPp > 2.5) {
      today.add(InterpretationLine(
        'IV Skew',
        'Put IV (${_pct(putIv)}) > Call IV (${_pct(callIv)}) by '
        '${skewPp.toStringAsFixed(1)}pp — protective put demand elevated. '
        'Bearish hedging above normal for $dteBucket DTE.',
        InterpretationSignal.bearish,
      ));
    } else if (skewPp < -1.5) {
      today.add(InterpretationLine(
        'IV Skew',
        'Call IV (${_pct(callIv)}) > Put IV (${_pct(putIv)}) by '
        '${(-skewPp).toStringAsFixed(1)}pp — positive call skew unusual. '
        'May reflect takeover speculation or short-squeeze positioning.',
        InterpretationSignal.caution,
      ));
    } else {
      today.add(InterpretationLine(
        'IV Skew',
        'Neutral — call IV (${_pct(callIv)}) ≈ put IV (${_pct(putIv)}). '
        'Balanced hedging demand at $dteBucket DTE.',
        InterpretationSignal.neutral,
      ));
    }
  }

  // 2. Gamma percentile within tracked history ─────────────────────────────────
  final allCallGammas = history
      .map((s) => s.callGamma)
      .whereType<double>()
      .toList()
    ..sort();
  final latestGamma = latest.callGamma;
  if (latestGamma != null && allCallGammas.isNotEmpty) {
    final rank   = allCallGammas.where((g) => g <= latestGamma).length;
    final pctile = (rank / allCallGammas.length * 100).round();
    final isHigh = pctile >= 80;
    today.add(InterpretationLine(
      'Gamma',
      'ATM call gamma at ${pctile}th percentile of '
      '${history.length}-session history '
      '(${latestGamma.toStringAsFixed(4)}). '
      '${isHigh
          ? "Above-average risk density — strong delta hedging flows expected on large moves."
          : "Within normal range."}',
      isHigh ? InterpretationSignal.caution : InterpretationSignal.neutral,
    ));
  }

  // 3. Theta / Vega efficiency ──────────────────────────────────────────────────
  final callTheta = latest.callTheta;
  final callVega  = latest.callVega;
  if (callTheta != null && callVega != null && callVega.abs() > 0.001) {
    final ratio = callTheta.abs() / callVega.abs();
    if (ratio > 0.5) {
      today.add(InterpretationLine(
        'Theta / Vega',
        'Ratio ${ratio.toStringAsFixed(2)} — theta (${_greek(callTheta)}/day) '
        'heavy vs vega (${_greek(callVega)}/1% IV). '
        'Premium selling efficient at this DTE.',
        InterpretationSignal.neutral,
      ));
    } else {
      today.add(InterpretationLine(
        'Theta / Vega',
        'Ratio ${ratio.toStringAsFixed(2)} — vega (${_greek(callVega)}/1% IV) '
        'dominates theta (${_greek(callTheta)}/day). '
        'Long-vol position favored over premium capture.',
        InterpretationSignal.neutral,
      ));
    }
  }

  // 4. Delta — strike drift ────────────────────────────────────────────────────
  final callDelta = latest.callDelta;
  if (callDelta != null) {
    if (callDelta > 0.58) {
      today.add(InterpretationLine(
        'Delta',
        'ATM call delta ${callDelta.toStringAsFixed(2)} — stock has rallied '
        'above the tracked strike (now ITM). '
        'Consider rolling up to restore ATM exposure.',
        InterpretationSignal.caution,
      ));
    } else if (callDelta < 0.40) {
      today.add(InterpretationLine(
        'Delta',
        'ATM call delta ${callDelta.toStringAsFixed(2)} — stock has fallen '
        'below the tracked strike (now OTM). '
        'Position losing directional sensitivity.',
        InterpretationSignal.bearish,
      ));
    } else {
      today.add(InterpretationLine(
        'Delta',
        'ATM call delta ${callDelta.toStringAsFixed(2)} — strike remains '
        'near fair value. Position well-centred.',
        InterpretationSignal.neutral,
      ));
    }
  }

  // ── PERIOD ─────────────────────────────────────────────────────────────────

  if (history.length >= 2) {
    final first = history.first;
    final n     = history.length;

    // IV direction (call)
    if (first.callIv != null && latest.callIv != null && first.callIv! > 0) {
      final chg = (latest.callIv! - first.callIv!) / first.callIv! * 100;
      period.add(InterpretationLine(
        'IV Direction',
        '${chg > 8 ? "Expanding" : chg < -8 ? "Compressing" : "Stable"} — '
        'call IV ${_pct(first.callIv!)} → ${_pct(latest.callIv!)} '
        '(${chg >= 0 ? "+" : ""}${chg.toStringAsFixed(1)}%) over $n sessions.',
        chg > 8 ? InterpretationSignal.caution
        : chg < -8 ? InterpretationSignal.bullish
        : InterpretationSignal.neutral,
      ));
    }

    // Gamma structural change
    if (first.callGamma != null && latest.callGamma != null &&
        first.callGamma! > 0) {
      final chg = (latest.callGamma! - first.callGamma!) / first.callGamma! * 100;
      if (chg.abs() > 20) {
        period.add(InterpretationLine(
          'Gamma Trend',
          '${chg > 0 ? "Rising" : "Falling"} ${chg.abs().toStringAsFixed(0)}% — '
          '${chg > 0
              ? "increasing concentration near ATM; approaching gamma risk zone"
              : "gamma dispersing; reduced binary risk at current strikes"}.',
          chg > 0 ? InterpretationSignal.caution : InterpretationSignal.neutral,
        ));
      }
    }

    // Put/Call IV spread widening or narrowing
    final firstSkew  = ((first.putIv  ?? 0) - (first.callIv  ?? 0));
    final latestSkew = ((latest.putIv ?? 0) - (latest.callIv ?? 0));
    final skewChange = latestSkew - firstSkew;
    if (skewChange > 0.02) {
      period.add(InterpretationLine(
        'Put/Call IV Spread',
        'Widening (${_pp(firstSkew)} → ${_pp(latestSkew)}) over $n sessions — '
        'growing bearish hedging demand. Downside risk perception increasing.',
        InterpretationSignal.bearish,
      ));
    } else if (skewChange < -0.02) {
      period.add(InterpretationLine(
        'Put/Call IV Spread',
        'Narrowing (${_pp(firstSkew)} → ${_pp(latestSkew)}) over $n sessions — '
        'downside hedging demand easing. Sentiment becoming less defensive.',
        InterpretationSignal.bullish,
      ));
    }

    // Delta drift range
    final deltas = history.map((s) => s.callDelta).whereType<double>().toList();
    if (deltas.length >= 3) {
      final lo = deltas.reduce((a, b) => a < b ? a : b);
      final hi = deltas.reduce((a, b) => a > b ? a : b);
      if (hi - lo > 0.15) {
        final trended = deltas.last > deltas.first;
        period.add(InterpretationLine(
          'Delta Range',
          'Wide (${lo.toStringAsFixed(2)} – ${hi.toStringAsFixed(2)}) — '
          'underlying ${trended ? "rallied" : "declined"} significantly through '
          'tracked period. Strike position shifted relative to spot.',
          trended ? InterpretationSignal.bullish : InterpretationSignal.bearish,
        ));
      } else {
        period.add(InterpretationLine(
          'Delta Range',
          'Contained (${lo.toStringAsFixed(2)} – ${hi.toStringAsFixed(2)}) — '
          'underlying held near the tracked strike through the period.',
          InterpretationSignal.neutral,
        ));
      }
    }
  }

  return _buildResult(today, period, history.length);
}

// ── Shared helpers ─────────────────────────────────────────────────────────────

InterpretationResult _buildResult(
  List<InterpretationLine> today,
  List<InterpretationLine> period,
  int nObs,
) {
  if (today.isEmpty && period.isEmpty) {
    return InterpretationResult(
      headline:       'Not enough data — load the options chain to begin tracking.',
      headlineSignal: InterpretationSignal.neutral,
      today:          today,
      period:         period,
      periodObs:      nObs,
    );
  }

  // Headline = first caution > first bearish > first bullish > first neutral
  final byPriority = [
    ...today.where((l) => l.signal == InterpretationSignal.caution),
    ...today.where((l) => l.signal == InterpretationSignal.bearish),
    ...today.where((l) => l.signal == InterpretationSignal.bullish),
    ...today,
  ];
  final top = byPriority.first;

  return InterpretationResult(
    headline:       '${top.label} — ${top.text.split("—").last.trim().split(".").first}.',
    headlineSignal: top.signal,
    today:          today,
    period:         period,
    periodObs:      nObs,
  );
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _pp (double v) => '${(v * 100).toStringAsFixed(1)}pp';

String _greek(double v) {
  if (v.abs() < 0.001) return v.toStringAsExponential(1);
  return v.toStringAsFixed(3);
}
