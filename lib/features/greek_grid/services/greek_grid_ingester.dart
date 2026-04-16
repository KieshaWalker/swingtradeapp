// =============================================================================
// features/greek_grid/services/greek_grid_ingester.dart
// =============================================================================
// Pure function: maps a SchwabOptionsChain into aggregated GreekGridPoints.
// No Supabase I/O — only math. Repository handles persistence.
//
// Second-order greeks (vanna, charm, volga) are computed inline via the
// same Black-Scholes approximations as FairValueEngine.
// =============================================================================

import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_service.dart';
import '../models/greek_grid_models.dart';
import 'greek_grid_repository.dart';

// ── Internal accumulator ──────────────────────────────────────────────────────

class _CellAccumulator {
  final List<double> deltas  = [];
  final List<double> gammas  = [];
  final List<double> vegas   = [];
  final List<double> thetas  = [];
  final List<double> ivs     = [];
  final List<double> vannas  = [];
  final List<double> charms  = [];
  final List<double> volgas  = [];
  final List<double> strikes = [];
  final List<int>    ois     = [];
  final List<int>    vols    = [];
  DateTime?          nearestExpiry;

  void add(SchwabOptionContract c, DateTime expiry) {
    if (c.delta.abs() > 0)       deltas.add(c.delta);
    if (c.gamma.abs() > 0)       gammas.add(c.gamma);
    if (c.vega.abs() > 0)        vegas.add(c.vega);
    if (c.theta.abs() > 0)       thetas.add(c.theta);
    if (c.impliedVolatility > 0) ivs.add(c.impliedVolatility / 100);
    strikes.add(c.strikePrice);
    ois.add(c.openInterest);
    vols.add(c.totalVolume);

    // Second-order greeks via B-S approximations
    final iv  = c.impliedVolatility / 100;
    final dte = c.daysToExpiration;
    if (iv > 0 && dte > 0 && c.strikePrice > 0) {
      final T      = dte / 365.0;
      final sqrtT  = math.sqrt(T);
      final K      = c.strikePrice;
      // Approximate forward from strike + delta (rough but usable for grid)
      final f      = K * math.exp(iv * sqrtT * 0.5);
      final sigSqT = iv * sqrtT;

      if (sigSqT > 1e-8) {
        final d1  = (math.log(f / K) + 0.5 * iv * iv * T) / sigSqT;
        final d2  = d1 - sigSqT;
        final phi = math.exp(-0.5 * d1 * d1) / math.sqrt(2 * math.pi);

        vannas.add(-phi * d2 / iv);                              // vanna
        charms.add(-phi * (2 * 0.0433 * T - d2 * sigSqT)        // charm
            / (2 * sigSqT));
        final vegaVal = f * phi * sqrtT;
        if (iv.abs() > 1e-8) volgas.add(vegaVal * d1 * d2 / iv); // volga
      }
    }

    if (nearestExpiry == null || expiry.isBefore(nearestExpiry!)) {
      nearestExpiry = expiry;
    }
  }

  GreekGridPoint toPoint({
    required String       ticker,
    required DateTime     obsDate,
    required StrikeBand   band,
    required ExpiryBucket bucket,
    required double       spotAtObs,
  }) => GreekGridPoint(
    ticker:        ticker,
    obsDate:       obsDate,
    strikeBand:    band,
    expiryBucket:  bucket,
    strike:        _median(strikes),
    expiryDate:    nearestExpiry,
    delta:         deltas.isEmpty ? null : _median(deltas),
    gamma:         gammas.isEmpty ? null : _median(gammas),
    vega:          vegas.isEmpty  ? null : _median(vegas),
    theta:         thetas.isEmpty ? null : _median(thetas),
    iv:            ivs.isEmpty    ? null : _median(ivs),
    vanna:         vannas.isEmpty ? null : _median(vannas),
    charm:         charms.isEmpty ? null : _median(charms),
    volga:         volgas.isEmpty ? null : _median(volgas),
    openInterest:  ois.isEmpty    ? null : ois.reduce((a, b) => a + b),
    volume:        vols.isEmpty   ? null : vols.reduce((a, b) => a + b),
    spotAtObs:     spotAtObs,
    contractCount: strikes.length,
  );
}

double _median(List<double> vals) {
  if (vals.isEmpty) return 0;
  final sorted = List<double>.from(vals)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

// ── Public ingester ───────────────────────────────────────────────────────────

class GreekGridIngester {
  GreekGridIngester._();

  static List<GreekGridPoint> ingest(
    SchwabOptionsChain chain,
    DateTime           obsDate,
  ) {
    final spot = chain.underlyingPrice;
    if (spot <= 0) return [];

    final accumulators = <(StrikeBand, ExpiryBucket), _CellAccumulator>{};

    for (final exp in chain.expirations) {
      final bucket = ExpiryBucket.fromDte(exp.dte);
      final expiry = _parseExpiry(exp.expirationDate) ??
          obsDate.add(Duration(days: exp.dte));

      for (final c in [...exp.calls, ...exp.puts]) {
        final moneynessPct = (c.strikePrice - spot) / spot * 100;
        final band = StrikeBand.fromMoneynessPct(moneynessPct);
        accumulators.putIfAbsent((band, bucket), _CellAccumulator.new)
            .add(c, expiry);
      }
    }

    return accumulators.entries.map((e) {
      final (band, bucket) = e.key;
      return e.value.toPoint(
        ticker:    chain.symbol,
        obsDate:   obsDate,
        band:      band,
        bucket:    bucket,
        spotAtObs: spot,
      );
    }).toList();
  }

  static DateTime? _parseExpiry(String raw) {
    final dateStr = raw.split(':').first.trim();
    return DateTime.tryParse(dateStr);
  }
}

// ── Auto-ingest helper ────────────────────────────────────────────────────────
// Fetches its own wide chain (strikeCount: 40) so band coverage is guaranteed
// regardless of what strikeCount the chain screen is currently showing.
// With only 10 strikes the default screen uses, tight-spaced tickers (SPY
// weeklies at $1/strike) put all contracts inside the ±5 % ATM band.
// Fire-and-forget — errors swallowed so the chain screen is never disrupted.

Future<void> autoIngestGreekGrid(String symbol) async {
  try {
    final db     = Supabase.instance.client;
    final userId = db.auth.currentUser?.id;
    if (userId == null) return;

    final chain = await SchwabService().getOptionsChain(
      symbol,
      contractType: 'ALL',
      strikeCount:  40,
    );
    if (chain == null || chain.expirations.isEmpty) return;

    final now   = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);

    final points = GreekGridIngester.ingest(chain, today);
    if (points.isEmpty) return;

    await GreekGridRepository(db).upsertPoints(points, userId);
  } catch (_) {
    // Never disrupt the options chain UI.
  }
}
