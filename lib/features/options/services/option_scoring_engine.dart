// =============================================================================
// features/options/services/option_scoring_engine.dart
// Pure Dart — no Flutter dependencies. Scores a single option contract 0–100.
// =============================================================================
import '../../../services/schwab/schwab_models.dart';

class OptionScore {
  final int total;          // 0–100
  final int deltaScore;     // 0–20
  final int dteScore;       // 0–20
  final int spreadScore;    // 0–15
  final int ivScore;        // 0–20
  final int oiScore;        // 0–10
  final int moneynessScore; // 0–15
  final String grade;       // A / B / C / D
  final List<String> flags; // e.g. "Wide spread", "Expiring today"

  const OptionScore({
    required this.total,
    required this.deltaScore,
    required this.dteScore,
    required this.spreadScore,
    required this.ivScore,
    required this.oiScore,
    required this.moneynessScore,
    required this.grade,
    required this.flags,
  });

  static String _grade(int t) {
    if (t >= 75) return 'A';
    if (t >= 55) return 'B';
    if (t >= 35) return 'C';
    return 'D';
  }
}

class OptionScoringEngine {
  const OptionScoringEngine._();

  static OptionScore score(
    SchwabOptionContract contract,
    double underlyingPrice,
  ) {
    final flags = <String>[];

    // ── Zero-liquidity guard ────────────────────────────────────────────────
    if (contract.bid == 0 && contract.ask == 0) {
      return OptionScore(
        total: 0, deltaScore: 0, dteScore: 0, spreadScore: 0,
        ivScore: 0, oiScore: 0, moneynessScore: 0,
        grade: 'D', flags: ['No market (illiquid)'],
      );
    }

    // ── 1. Delta quality (0–20) ─────────────────────────────────────────────
    // Sweet spot 0.30–0.50 absolute delta for directional swings
    final absDelta = contract.delta.abs();
    final int deltaScore;
    if (absDelta == 0) {
      deltaScore = 0;
      flags.add('Delta unavailable');
    } else {
      final dist = (absDelta - 0.40).abs();
      deltaScore = (20 * (1 - (dist / 0.40))).clamp(0, 20).round();
    }

    // ── 2. DTE zone (0–20) ──────────────────────────────────────────────────
    // Sweet spot: 21–45 DTE scores 20. Linear ramp 1–20 DTE → 0..20.
    // 46–90 DTE: smooth decay 20→10. 91–180 DTE: 10→0. Beyond 180 = 0.
    final dte = contract.daysToExpiration;
    final int dteScore;
    if (dte <= 0) {
      dteScore = 0;
      flags.add('Expiring today');
    } else if (dte <= 7) {
      dteScore = (20.0 * dte / 7).round();
      flags.add('DTE < 7 — pin risk');
    } else if (dte <= 21) {
      dteScore = (10.0 + 10.0 * (dte - 7) / 14).round();
    } else if (dte <= 45) {
      dteScore = 20;
    } else if (dte <= 90) {
      // Decays 20 → 10 over 45 days (not 0 — 90-DTE swings still viable)
      dteScore = (20.0 - (dte - 45) / 45.0 * 10).round();
    } else {
      // Decays 10 → 0 over the next 90 days; clamp at 0 beyond 180 DTE
      dteScore = (10.0 - (dte - 90) / 90.0 * 10).clamp(0.0, 10.0).round();
      if (dte > 180) flags.add('DTE > 180 — very long-dated');
    }

    // ── 3. Bid/Ask spread quality (0–15) ────────────────────────────────────
    // Spread % of midpoint. Monotone: 0% → 15pts, 20% → 8pts, 100% → 0pts.
    // Two-segment linear curve that is continuous at the 20% boundary.
    final spreadPct = contract.spreadPct;
    final int spreadScore;
    if (spreadPct >= 1.0) {
      spreadScore = 0;
      flags.add('No real market');
    } else if (spreadPct > 0.20) {
      // Wide region: 8 → 0 as spreadPct goes 20% → 100%
      spreadScore = (8.0 * (1 - (spreadPct - 0.20) / 0.80)).clamp(0, 8).round();
      flags.add('Wide spread');
    } else {
      // Tight region: 15 → 8 as spreadPct goes 0% → 20%
      spreadScore = (8.0 + 7.0 * (1 - spreadPct / 0.20)).clamp(0, 15).round();
    }

    // ── 4. Implied Volatility (0–20) ─────────────────────────────────────────
    // Schwab returns IV as percentage (e.g. 32.6 = 32.6%)
    final iv = contract.impliedVolatility; // already a percentage
    final int ivScore;
    if (iv >= 50) {
      ivScore = 20;
    } else if (iv >= 20) {
      ivScore = (10 + 10 * (iv - 20) / 30).round();
    } else if (iv >= 5) {
      ivScore = (10 * (iv - 5) / 15).clamp(0, 10).round();
    } else {
      ivScore = 0;
    }

    // ── 5. Open Interest (0–10) ──────────────────────────────────────────────
    final oi = contract.openInterest;
    final int oiScore;
    if (oi >= 1000) {
      oiScore = 10;
    } else if (oi >= 500) {
      oiScore = 8;
    } else if (oi >= 100) {
      oiScore = 5;
    } else if (oi >= 20) {
      oiScore = 2;
    } else {
      oiScore = 0;
      if (oi == 0) flags.add('No open interest');
    }

    // ── 6. Moneyness match (0–15) ─────────────────────────────────────────────
    // OTM 1–7% = best for long directional swings
    final pctOtm = underlyingPrice == 0
        ? 0.0
        : ((contract.strikePrice - underlyingPrice) / underlyingPrice).abs();
    final bool isItm = contract.inTheMoney;
    final int moneynessScore;
    if (isItm) {
      if (pctOtm <= 0.05) {
        moneynessScore = 8; // shallow ITM
      } else {
        moneynessScore = 4; // deep ITM — high cost, low leverage
        flags.add('Deep ITM');
      }
    } else {
      if (pctOtm <= 0.01) {
        moneynessScore = 12; // ATM
      } else if (pctOtm <= 0.07) {
        moneynessScore = 15; // sweet spot OTM
      } else if (pctOtm <= 0.12) {
        moneynessScore = 7;
      } else {
        moneynessScore = 0;
        flags.add('Deep OTM');
      }
    }

    final total = (deltaScore + dteScore + spreadScore + ivScore + oiScore + moneynessScore)
        .clamp(0, 100);

    return OptionScore(
      total:          total,
      deltaScore:     deltaScore,
      dteScore:       dteScore,
      spreadScore:    spreadScore,
      ivScore:        ivScore,
      oiScore:        oiScore,
      moneynessScore: moneynessScore,
      grade:          OptionScore._grade(total),
      flags:          flags,
    );
  }
}
