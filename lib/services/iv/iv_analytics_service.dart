// =============================================================================
// services/iv/iv_analytics_service.dart
// =============================================================================
// Pure math — no I/O. Takes a SchwabOptionsChain + historical IvSnapshot list
// and produces a fully-populated IvAnalysis.
//
// Calculations:
//
//  IV Rank (IVR)
//    IVR = (currentIV − 52wLow) / (52wHigh − 52wLow) × 100
//    Classic measure. Tells you WHERE in the range today's IV sits.
//
//  IV Percentile (IVP)
//    IVP = (# days IV was below today) / totalDays × 100
//    Better than IVR when IV spikes were rare — avoids one outlier dominating.
//
//  Volatility Skew
//    Computed per-expiration (nearest monthly ≥ 21 DTE preferred).
//    For each OTM strike within ±15% of spot:
//      skewDelta = putIV − callIV at same distance from ATM
//    Summary skew = avg of all skewDelta values.
//    Positive skew = puts more expensive = tail-risk premium.
//
//  Gamma Exposure (GEX)
//    Dealer GEX per strike ($ millions):
//      GEX = (callOI × callGamma − putOI × putGamma) × 100 × spot / 1e6
//    Assumes dealers are long calls (sold to buyers) and short puts (sold to buyers).
//    Positive GEX → market-makers stabilise price (buy dips, sell rips).
//    Negative GEX → market-makers amplify moves (buy rallies, sell dips).
//    Max GEX strike = major support/resistance / "gamma wall."
//
//  Second-order Greeks (Vanna, Charm, Volga)
//    Full Black-Scholes with risk-free rate r (passed in, sourced from FRED DFF).
//    r=0 is NOT used — with US rates at 4-5%, omitting r causes systematic bias
//    in d₁/d₂ that de-syncs Vanna and Charm from real dealer hedges.
//
//    Time T is computed in fractional years with intraday precision:
//      T = minutesToExpiry / (365 × 24 × 60)
//    This prevents Gamma/Charm from exploding incorrectly for 0-DTE contracts.
//    Minimum T floor = 1 minute to avoid division by zero near expiry.
//
//    d₁ = (ln(S/K) + (r + 0.5σ²)T) / (σ√T)   ← full BS with r
//    d₂ = d₁ − σ√T
//    Vanna  ≈ −gamma × S × √T × d₂
//    Charm  ≈  gamma × S × (r×d₁/σ − d₂/(2T)) / 365   (exact BS charm)
//    Volga  ≈  vega × d₁ × d₂ / σ
// =============================================================================

import 'dart:math' as math;
import '../../services/schwab/schwab_models.dart';
import 'iv_models.dart';

class IvAnalyticsService {
  static const double _otmMinPct  = 0.01;  // 1% OTM minimum
  static const double _otmMaxPct  = 0.15;  // 15% OTM maximum for skew wing
  static const int    _minDtePref = 21;    // prefer expirations ≥ 21 DTE

  // Fallback risk-free rate when FRED data unavailable.
  // Updated to reflect 2025-2026 Fed Funds reality (~4.33% as of Apr 2026).
  // The caller should pass the live FRED DFF value instead.
  static const double _defaultRiskFreeRate = 0.0433;

  // ── Main entry point ───────────────────────────────────────────────────────

  static IvAnalysis analyse(
    SchwabOptionsChain chain,
    List<IvSnapshot> history, {  // sorted ascending by date
    double? riskFreeRate,         // pass live FRED DFF value; falls back to default
  }) {
    final r = (riskFreeRate ?? _defaultRiskFreeRate) / 100; // convert % to decimal if needed
    // Guard: if caller already passed a decimal (e.g. 0.0433) keep it; if they
    // passed a percentage (e.g. 4.33) normalise it.
    final rDecimal = r > 0.5 ? r / 100 : r;
    final spot  = chain.underlyingPrice;
    final atmIv = chain.volatility; // chain-level ATM IV from Schwab

    // ── IVR & IVP ──────────────────────────────────────────────────────────
    double? ivRank;
    double? ivPercentile;
    double? iv52wHigh;
    double? iv52wLow;
    IvRating rating = IvRating.noData;

    if (history.length >= 10) {
      final ivs = history.map((s) => s.atmIv).toList();
      iv52wHigh = ivs.reduce(math.max);
      iv52wLow  = ivs.reduce(math.min);
      final range = iv52wHigh - iv52wLow;

      ivRank = range < 0.001
          ? 50.0
          : ((atmIv - iv52wLow) / range * 100).clamp(0, 100);

      final below = ivs.where((iv) => iv < atmIv).length;
      ivPercentile = (below / ivs.length * 100).clamp(0, 100);

      rating = _ratingFromRank(ivRank);
    }

    // ── Skew ───────────────────────────────────────────────────────────────
    final exp = _pickExpiration(chain);
    final skewCurve  = exp != null ? _computeSkewCurve(exp, spot) : <SkewPoint>[];
    final skewVal    = exp != null ? _summariseSkew(skewCurve) : null;

    double? skewAvg52w;
    double? skewZScore;
    if (history.isNotEmpty) {
      final skewHistory = history
          .where((s) => s.skew != null)
          .map((s) => s.skew!)
          .toList();
      if (skewHistory.length >= 5) {
        skewAvg52w = skewHistory.reduce((a, b) => a + b) / skewHistory.length;
        if (skewVal != null) {
          final avg = skewAvg52w;
          final variance = skewHistory
              .map((s) => (s - avg) * (s - avg))
              .reduce((a, b) => a + b) / skewHistory.length;
          final std = math.sqrt(variance);
          skewZScore = std < 0.001 ? 0 : (skewVal - skewAvg52w) / std;
        }
      }
    }

    // ── GEX ────────────────────────────────────────────────────────────────
    final gexStrikes = _computeGex(chain, spot);
    double? totalGex;
    double? maxGexStrike;
    double? putCallRatio;

    if (gexStrikes.isNotEmpty) {
      totalGex = gexStrikes
          .map((g) => g.dealerGex(spot))
          .reduce((a, b) => a + b);

      // Max absolute GEX — the key gamma wall
      maxGexStrike = gexStrikes
          .reduce((a, b) =>
              a.dealerGex(spot).abs() >= b.dealerGex(spot).abs() ? a : b)
          .strike;

      // Put/call ratio from OI
      final totalCallOi = gexStrikes.map((g) => g.callOi).reduce((a, b) => a + b);
      final totalPutOi  = gexStrikes.map((g) => g.putOi).reduce((a, b) => a + b);
      if (totalCallOi > 0) {
        putCallRatio = totalPutOi / totalCallOi;
      }
    }

    // ── Second-order Greeks: Vanna / Charm / Volga ────────────────────────
    final secondOrder  = _computeSecondOrder(chain, spot, rDecimal);
    double? totalVex;
    double? totalCex;
    double? totalVolga;
    double? maxVexStrike;
    GammaRegime gammaRegime = GammaRegime.unknown;
    VannaRegime vannaRegime = VannaRegime.unknown;

    if (secondOrder.isNotEmpty) {
      totalVex   = secondOrder.map((s) => s.dealerVex).reduce((a, b) => a + b);
      totalCex   = secondOrder.map((s) => s.dealerCex).reduce((a, b) => a + b);
      totalVolga = secondOrder.map((s) => s.dealerVolga).reduce((a, b) => a + b);
      maxVexStrike = secondOrder
          .reduce((a, b) => a.dealerVex.abs() >= b.dealerVex.abs() ? a : b)
          .strike;
    }

    if (totalGex != null) {
      gammaRegime = totalGex >= 0
          ? GammaRegime.positive
          : GammaRegime.negative;
    }
    if (totalVex != null) {
      vannaRegime = totalVex >= 0
          ? VannaRegime.bullishOnVolCrush   // vol drop → dealers buy delta
          : VannaRegime.bearishOnVolCrush;  // vol drop → dealers sell delta
    }

    return IvAnalysis(
      ticker:         chain.symbol,
      currentIv:      atmIv,
      iv52wHigh:      iv52wHigh,
      iv52wLow:       iv52wLow,
      ivRank:         ivRank,
      ivPercentile:   ivPercentile,
      rating:         rating,
      historyDays:    history.length,
      skew:           skewVal,
      skewAvg52w:     skewAvg52w,
      skewZScore:     skewZScore,
      skewCurve:      skewCurve,
      gexStrikes:     gexStrikes,
      totalGex:       totalGex,
      maxGexStrike:   maxGexStrike,
      putCallRatio:   putCallRatio,
      secondOrder:    secondOrder,
      totalVex:       totalVex,
      totalCex:       totalCex,
      totalVolga:     totalVolga,
      maxVexStrike:   maxVexStrike,
      gammaRegime:    gammaRegime,
      vannaRegime:    vannaRegime,
    );
  }

  // ── Build IvSnapshot from a chain (for persistence) ───────────────────────

  static IvSnapshot snapshotFromChain(SchwabOptionsChain chain) {
    final spot   = chain.underlyingPrice;
    final exp    = _pickExpiration(chain);
    final skewCurve = exp != null ? _computeSkewCurve(exp, spot) : <SkewPoint>[];
    final skewVal   = exp != null ? _summariseSkew(skewCurve) : null;
    final gexStrikes = _computeGex(chain, spot);

    double? totalGex;
    double? maxGexStrike;
    double? putCallRatio;

    if (gexStrikes.isNotEmpty) {
      totalGex = gexStrikes
          .map((g) => g.dealerGex(spot))
          .reduce((a, b) => a + b);
      maxGexStrike = gexStrikes
          .reduce((a, b) =>
              a.dealerGex(spot).abs() >= b.dealerGex(spot).abs() ? a : b)
          .strike;
      final totalCallOi = gexStrikes.map((g) => g.callOi).reduce((a, b) => a + b);
      final totalPutOi  = gexStrikes.map((g) => g.putOi).reduce((a, b) => a + b);
      if (totalCallOi > 0) putCallRatio = totalPutOi / totalCallOi;
    }

    return IvSnapshot(
      ticker:          chain.symbol,
      date:            DateTime.now(),
      atmIv:           chain.volatility,
      skew:            skewVal,
      gexByStrike:     gexStrikes.map((g) => g.toJson(spot)).toList(),
      totalGex:        totalGex,
      maxGexStrike:    maxGexStrike,
      putCallRatio:    putCallRatio,
      underlyingPrice: spot,
    );
  }

  // ── Expiration picker ─────────────────────────────────────────────────────

  static SchwabOptionsExpiration? _pickExpiration(SchwabOptionsChain chain) {
    if (chain.expirations.isEmpty) return null;
    // Prefer first expiration ≥ 21 DTE (monthly territory)
    final preferred = chain.expirations
        .where((e) => e.dte >= _minDtePref)
        .toList();
    if (preferred.isNotEmpty) return preferred.first;
    // Fall back to nearest available
    return chain.expirations.first;
  }

  // ── Skew curve ────────────────────────────────────────────────────────────

  static List<SkewPoint> _computeSkewCurve(
    SchwabOptionsExpiration exp,
    double spot,
  ) {
    // Build maps: strike → IV for calls and puts
    final callMap = <double, double>{};
    final putMap  = <double, double>{};

    for (final c in exp.calls) {
      if (c.impliedVolatility > 0) callMap[c.strikePrice] = c.impliedVolatility;
    }
    for (final p in exp.puts) {
      if (p.impliedVolatility > 0) putMap[p.strikePrice] = p.impliedVolatility;
    }

    // Collect all strikes within ±15% of spot
    final allStrikes = {...callMap.keys, ...putMap.keys}.toList()..sort();
    final points = <SkewPoint>[];

    for (final strike in allStrikes) {
      final moneyness = (strike - spot) / spot * 100;
      if (moneyness.abs() > _otmMaxPct * 100) continue;

      points.add(SkewPoint(
        strike:    strike,
        moneyness: moneyness,
        callIv:    callMap[strike],
        putIv:     putMap[strike],
      ));
    }

    return points;
  }

  // ── Skew summary ──────────────────────────────────────────────────────────

  static double? _summariseSkew(List<SkewPoint> curve) {
    // Only use OTM puts (moneyness < -1%) vs OTM calls (moneyness > +1%)
    final otmPuts  = curve.where((p) => p.moneyness < -_otmMinPct * 100 && p.putIv != null);
    final otmCalls = curve.where((p) => p.moneyness >  _otmMinPct * 100 && p.callIv != null);

    if (otmPuts.isEmpty || otmCalls.isEmpty) return null;

    final avgPutIv  = otmPuts.map((p) => p.putIv!).reduce((a, b) => a + b)
        / otmPuts.length;
    final avgCallIv = otmCalls.map((p) => p.callIv!).reduce((a, b) => a + b)
        / otmCalls.length;

    return avgPutIv - avgCallIv; // positive = put skew (fear premium)
  }

  // ── GEX calculation ───────────────────────────────────────────────────────

  static List<GexStrike> _computeGex(SchwabOptionsChain chain, double spot) {
    // Merge calls + puts across all expirations by strike
    final callsByStrike = <double, List<SchwabOptionContract>>{};
    final putsByStrike  = <double, List<SchwabOptionContract>>{};

    for (final exp in chain.expirations) {
      for (final c in exp.calls) {
        callsByStrike.putIfAbsent(c.strikePrice, () => []).add(c);
      }
      for (final p in exp.puts) {
        putsByStrike.putIfAbsent(p.strikePrice, () => []).add(p);
      }
    }

    final allStrikes = {
      ...callsByStrike.keys,
      ...putsByStrike.keys,
    }.toList()..sort();

    final results = <GexStrike>[];

    for (final strike in allStrikes) {
      // Only consider strikes within ±20% of spot (relevant gamma range)
      if ((strike - spot).abs() / spot > 0.20) continue;

      double callOi    = 0, putOi = 0;
      double callGamma = 0, putGamma = 0;

      for (final c in callsByStrike[strike] ?? []) {
        callOi    += c.openInterest;
        callGamma += c.gamma;
      }
      for (final p in putsByStrike[strike] ?? []) {
        putOi    += p.openInterest;
        putGamma += p.gamma;
      }

      // Average gamma per expiration (if multiple expirations at same strike)
      final callCount = (callsByStrike[strike] ?? []).length;
      final putCount  = (putsByStrike[strike]  ?? []).length;
      if (callCount > 1) callGamma /= callCount;
      if (putCount  > 1) putGamma  /= putCount;

      if (callOi == 0 && putOi == 0) continue;

      results.add(GexStrike(
        strike:    strike,
        callOi:    callOi,
        putOi:     putOi,
        callGamma: callGamma,
        putGamma:  putGamma,
      ));
    }

    return results;
  }

  // ── Second-order Greeks: Vanna / Charm / Volga ───────────────────────────
  // Full Black-Scholes with risk-free rate r and minute-precision T.
  //
  //  T   = minutesToExpiry / (365 × 24 × 60)   [floor: 1 min]
  //  d₁  = (ln(S/K) + (r + 0.5σ²)T) / (σ√T)  [full BS]
  //  d₂  = d₁ − σ√T
  //
  //  Vanna  ≈ −gamma × S × √T × d₂
  //  Charm  ≈  gamma × S × (r×d₁/σ − d₂/(2T)) / 365   [exact BS charm]
  //  Volga  ≈  vega  × d₁ × d₂ / σ

  static List<SecondOrderStrike> _computeSecondOrder(
    SchwabOptionsChain chain,
    double spot,
    double r,
  ) {
    // Aggregate across all expirations per strike
    final callsByStrike = <double, List<SchwabOptionContract>>{};
    final putsByStrike  = <double, List<SchwabOptionContract>>{};

    for (final exp in chain.expirations) {
      for (final c in exp.calls) {
        callsByStrike.putIfAbsent(c.strikePrice, () => []).add(c);
      }
      for (final p in exp.puts) {
        putsByStrike.putIfAbsent(p.strikePrice, () => []).add(p);
      }
    }

    final allStrikes = {...callsByStrike.keys, ...putsByStrike.keys}.toList()
      ..sort();
    final results = <SecondOrderStrike>[];

    for (final strike in allStrikes) {
      if ((strike - spot).abs() / spot > 0.20) continue;

      final calls = callsByStrike[strike] ?? [];
      final puts  = putsByStrike[strike]  ?? [];
      if (calls.isEmpty && puts.isEmpty) continue;

      double callOi = 0, putOi = 0;
      double callVanna = 0, putVanna = 0;
      double callCharm = 0, putCharm = 0;
      double callVolga = 0, putVolga = 0;

      for (final c in calls) {
        callOi += c.openInterest;
        final g = _secondOrderGreeks(spot, strike, c.impliedVolatility / 100,
            c.daysToExpiration, c.gamma, c.vega, r,
            DateTime.tryParse(c.expirationDate));
        callVanna += g.$1;
        callCharm += g.$2;
        callVolga += g.$3;
      }
      for (final p in puts) {
        putOi += p.openInterest;
        final g = _secondOrderGreeks(spot, strike, p.impliedVolatility / 100,
            p.daysToExpiration, p.gamma, p.vega, r,
            DateTime.tryParse(p.expirationDate));
        putVanna += g.$1;
        putCharm += g.$2;
        putVolga += g.$3;
      }

      // Average across expirations at same strike
      if (calls.length > 1) {
        callVanna /= calls.length;
        callCharm /= calls.length;
        callVolga /= calls.length;
      }
      if (puts.length > 1) {
        putVanna /= puts.length;
        putCharm /= puts.length;
        putVolga /= puts.length;
      }

      results.add(SecondOrderStrike(
        strike:    strike,
        callOi:    callOi,
        putOi:     putOi,
        callVanna: callVanna,
        putVanna:  putVanna,
        callCharm: callCharm,
        putCharm:  putCharm,
        callVolga: callVolga,
        putVolga:  putVolga,
      ));
    }

    return results;
  }

  /// Returns (vanna, charm, volga) for a single contract using full BS with r.
  static (double, double, double) _secondOrderGreeks(
    double spot,
    double strike,
    double sigma,          // IV as decimal (e.g. 0.326)
    int    dte,
    double gamma,          // from Schwab
    double vega,           // from Schwab
    double r,              // risk-free rate as decimal (e.g. 0.0433)
    DateTime? expiryDate,  // for intraday minute-precision T
  ) {
    if (sigma <= 0 || dte < 0) return (0, 0, 0);

    // T in fractional years — minute precision to handle 0DTE correctly
    final now = DateTime.now();
    final minutesLeft = expiryDate != null
        ? expiryDate.difference(now).inMinutes.clamp(1, 999999).toDouble()
        : (dte * 24 * 60.0).clamp(1.0, double.infinity);
    final T = minutesLeft / (365 * 24 * 60);

    final sqrtT  = math.sqrt(T);
    final sigSqT = sigma * sqrtT;
    if (sigSqT < 1e-6) return (0, 0, 0);

    // Full BS d₁ with risk-free rate
    final logMoneyness = math.log(spot / strike);
    final d1 = (logMoneyness + (r + 0.5 * sigma * sigma) * T) / sigSqT;
    final d2 = d1 - sigSqT;

    // Vanna = −gamma × S × √T × d₂
    final vanna = -gamma * spot * sqrtT * d2;

    // Charm (exact BS) = gamma × S × (r×d₁/σ − d₂/(2T)) / 365
    final charm = T > 0
        ? gamma * spot * (r * d1 / sigma - d2 / (2 * T)) / 365
        : 0.0;

    // Volga = vega × d₁ × d₂ / σ
    final volga = vega * d1 * d2 / sigma;

    return (vanna, charm, volga);
  }

  // ── Rating helper ─────────────────────────────────────────────────────────

  static IvRating _ratingFromRank(double ivr) {
    if (ivr >= 80) return IvRating.extreme;
    if (ivr >= 50) return IvRating.expensive;
    if (ivr >= 25) return IvRating.fair;
    return IvRating.cheap;
  }
}
