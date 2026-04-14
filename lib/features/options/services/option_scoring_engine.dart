// =============================================================================
// features/options/services/option_scoring_engine.dart
// Pure Dart — no Flutter dependencies.
// Scores a single option contract 0–100, then applies a Regime Multiplier.
//
// ── Scoring components (Base Score, 0–100) ────────────────────────────────────
//   Delta quality      0–20   Sweet spot 0.30–0.50 abs delta
//   DTE zone           0–20   Sweet spot 21–45 DTE
//   Spread quality     0–10   Bid/ask spread as % of midpoint
//   IV Percentile      0–20   IVP-based cheapness (falls back to absolute IV)
//   Liquidity          0–15   OI + Volume/OI ratio + slippage gate
//   Moneyness          0–15   OTM 1–7% sweet spot
//
// ── Regime Multiplier (Final Score = Base × Gm × Vm) ─────────────────────────
//   Gm — GEX Multiplier  (requires IvAnalysis)
//     Deep Long Gamma + rising        → 1.20
//     Long Gamma + rising             → 1.10
//     Long Gamma + flat               → 1.00
//     Long Gamma + falling            → 0.85
//     Near Zero Gamma flip (≤±0.5%)   → 0.70
//     Short Gamma                     → 0.50
//
//   Vm — Vanna Multiplier  (requires IvAnalysis)
//     Standard regime (IV falling on rally) → 1.0
//     Vanna Divergence (IV rising on rally,
//       gammaSlope falling + bearish vanna) → 0.6
//
//   Hard Gate: Short Gamma regime → add REGIME FAIL flag; score capped at 35.
//   Hard Gate: Slippage (ask–theo)/mid > 2% → SLIPPAGE GATE flag; –5 pts.
// =============================================================================
import '../../../services/schwab/schwab_models.dart';
import '../../../services/iv/iv_models.dart';

class OptionScore {
  final int    total;           // 0–100 final (regime-adjusted)
  final int    baseScore;       // 0–100 before regime multiplier
  final int    deltaScore;      // 0–20
  final int    dteScore;        // 0–20
  final int    spreadScore;     // 0–10
  final int    ivScore;         // 0–20  (IVP-based when available)
  final int    liquidityScore;  // 0–15  (OI + Vol/OI)
  final int    moneynessScore;  // 0–15
  final double gexMultiplier;   // Gm — 0.50–1.20
  final double vannaMultiplier; // Vm — 0.60–1.00
  final bool   regimeFail;      // true = short gamma hard gate triggered
  final bool   ivpUsed;         // true = IVP data was used for ivScore
  final String grade;           // A / B / C / D
  final List<String> flags;

  const OptionScore({
    required this.total,
    required this.baseScore,
    required this.deltaScore,
    required this.dteScore,
    required this.spreadScore,
    required this.ivScore,
    required this.liquidityScore,
    required this.moneynessScore,
    required this.gexMultiplier,
    required this.vannaMultiplier,
    required this.regimeFail,
    required this.ivpUsed,
    required this.grade,
    required this.flags,
  });

  double get regimeMultiplier => gexMultiplier * vannaMultiplier;

  static String _grade(int t) {
    if (t >= 75) return 'A';
    if (t >= 55) return 'B';
    if (t >= 35) return 'C';
    return 'D';
  }
}

class OptionScoringEngine {
  const OptionScoringEngine._();

  /// Score a single contract.
  ///
  /// [ivAnalysis] is optional. When supplied:
  ///   • IV Percentile replaces absolute IV for the ivScore.
  ///   • Regime Multiplier (Gm × Vm) is applied to the base score.
  ///   • Hard Gate fires if the GEX regime is Short Gamma.
  static OptionScore score(
    SchwabOptionContract contract,
    double underlyingPrice, {
    IvAnalysis? ivAnalysis,
  }) {
    final flags = <String>[];

    // ── Zero-liquidity guard ────────────────────────────────────────────────
    if (contract.bid == 0 && contract.ask == 0) {
      return OptionScore(
        total: 0, baseScore: 0,
        deltaScore: 0, dteScore: 0, spreadScore: 0,
        ivScore: 0, liquidityScore: 0, moneynessScore: 0,
        gexMultiplier: 1.0, vannaMultiplier: 1.0,
        regimeFail: false, ivpUsed: false,
        grade: 'D', flags: ['No market (illiquid)'],
      );
    }

    // ── 1. Delta quality (0–20) ─────────────────────────────────────────────
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
      dteScore = (20.0 - (dte - 45) / 45.0 * 10).round();
    } else {
      dteScore = (10.0 - (dte - 90) / 90.0 * 10).clamp(0.0, 10.0).round();
      if (dte > 180) flags.add('DTE > 180 — very long-dated');
    }

    // ── 3. Spread quality (0–10) ────────────────────────────────────────────
    final spreadPct = contract.spreadPct;
    final int spreadScore;
    if (spreadPct >= 1.0) {
      spreadScore = 0;
      flags.add('No real market');
    } else if (spreadPct > 0.20) {
      spreadScore = (5.0 * (1 - (spreadPct - 0.20) / 0.80)).clamp(0, 5).round();
      flags.add('Wide spread');
    } else {
      spreadScore = (5.0 + 5.0 * (1 - spreadPct / 0.20)).clamp(0, 10).round();
    }

    // ── 4. IV score (0–20) — IVP-based when available ──────────────────────
    final ivp    = ivAnalysis?.ivPercentile;
    final ivpUsed = ivp != null;
    final int ivScore;
    if (ivpUsed) {
      // Cheap IV = good for long premium (swing trade buyers).
      // IVP 0–20 = very cheap → 20 pts.  IVP 80–100 = expensive → 2 pts.
      if (ivp <= 20)       ivScore = 20;
      else if (ivp <= 40)  ivScore = 16;
      else if (ivp <= 60)  ivScore = 10;
      else if (ivp <= 80)  ivScore = 5;
      else                 ivScore = 2;
    } else {
      // Fallback: absolute IV (normalised to same 0–20 range)
      final iv = contract.impliedVolatility;
      if (iv >= 50)       ivScore = 15;
      else if (iv >= 20)  ivScore = (8 + 7 * (iv - 20) / 30).round();
      else if (iv >= 5)   ivScore = (8 * (iv - 5) / 15).clamp(0, 8).round();
      else                ivScore = 0;
    }

    // ── 5. Liquidity (0–15): OI + Volume/OI ratio ──────────────────────────
    final oi       = contract.openInterest;
    final vol      = contract.totalVolume;
    final volOiRatio = oi == 0 ? 0.0 : vol / oi;

    // OI sub-score (0–10)
    final int oiSub;
    if (oi >= 5000)      oiSub = 10;
    else if (oi >= 1000) oiSub = 8;
    else if (oi >= 500)  oiSub = 5;
    else if (oi >= 100)  oiSub = 3;
    else                 oiSub = 0;
    if (oi == 0) flags.add('No open interest');

    // Volume/OI sub-score (0–5) — measures today's tradability
    final int volOiSub;
    if (volOiRatio >= 0.50)      volOiSub = 5;
    else if (volOiRatio >= 0.20) volOiSub = 3;
    else if (volOiRatio >= 0.05) volOiSub = 1;
    else                         volOiSub = 0;
    if (oi > 0 && vol == 0) flags.add('Zero volume today — stale OI');

    // Slippage gate: (ask − theo) / mid > 2% → penalty + flag
    int slippagePenalty = 0;
    if (contract.theoreticalOptionValue > 0 && contract.midpoint > 0) {
      final slippagePct =
          (contract.ask - contract.theoreticalOptionValue) / contract.midpoint;
      if (slippagePct > 0.02) {
        slippagePenalty = 5;
        flags.add(
            'Slippage gate: ask is ${(slippagePct * 100).toStringAsFixed(1)}% '
            'above theo (> 2% threshold)');
      }
    }

    final liquidityScore = (oiSub + volOiSub - slippagePenalty).clamp(0, 15);

    // ── 6. Moneyness match (0–15) ─────────────────────────────────────────────
    final pctOtm = underlyingPrice == 0
        ? 0.0
        : ((contract.strikePrice - underlyingPrice) / underlyingPrice).abs();
    final isItm = contract.inTheMoney;
    final int moneynessScore;
    if (isItm) {
      if (pctOtm <= 0.05) {
        moneynessScore = 8;
      } else {
        moneynessScore = 4;
        flags.add('Deep ITM');
      }
    } else {
      if (pctOtm <= 0.01)       moneynessScore = 12;
      else if (pctOtm <= 0.07)  moneynessScore = 15;
      else if (pctOtm <= 0.12)  moneynessScore = 7;
      else {
        moneynessScore = 0;
        flags.add('Deep OTM');
      }
    }

    final baseScore = (deltaScore + dteScore + spreadScore + ivScore +
            liquidityScore + moneynessScore)
        .clamp(0, 100);

    // ── Regime Multiplier ─────────────────────────────────────────────────────
    double gexMultiplier   = 1.0;
    double vannaMultiplier = 1.0;
    bool   regimeFail      = false;

    if (ivAnalysis != null) {
      final gr              = ivAnalysis.gammaRegime;
      final slope           = ivAnalysis.gammaSlope;
      final flipPct         = ivAnalysis.spotToZeroGammaPct;
      final totalGex        = ivAnalysis.totalGex;
      final vr              = ivAnalysis.vannaRegime;

      // ── Gm — GEX Multiplier ────────────────────────────────────────────────
      if (gr == GammaRegime.negative) {
        regimeFail    = true;
        gexMultiplier = 0.50;
        flags.add(
            'REGIME FAIL: Short Gamma — dealers amplify moves; '
            'structural support absent');
      } else if (flipPct != null && flipPct.abs() <= 0.5) {
        gexMultiplier = 0.70;
        flags.add(
            'Near Zero Gamma flip (${flipPct.toStringAsFixed(2)}% from flip) '
            '— high regime-shift probability');
      } else if (gr == GammaRegime.positive) {
        // Deep Long Gamma check: totalGex > $1B → Gm 1.2
        if (totalGex != null && totalGex >= 1000) {
          gexMultiplier = 1.20;
        } else if (slope == GammaSlope.rising) {
          gexMultiplier = 1.10;
        } else if (slope == GammaSlope.flat) {
          gexMultiplier = 1.00;
        } else {
          // falling
          gexMultiplier = 0.85;
        }
      }

      // ── Vm — Vanna Multiplier ──────────────────────────────────────────────
      // Vanna Divergence: slope falling + dealer delta turning bearish on vol change
      // signals that a rally is fragile and a reversal will be violent.
      final vannaDivergence = slope == GammaSlope.falling &&
          (vr == VannaRegime.bearishOnVolCrush ||
           vr == VannaRegime.bearishOnVolSpike);
      if (vannaDivergence) {
        vannaMultiplier = 0.60;
        flags.add(
            'Vanna Divergence: declining gamma slope + bearish dealer delta hedge — '
            'fragile rally; reversal risk elevated');
      }
    }

    // Apply multipliers
    final rawFinal  = baseScore * gexMultiplier * vannaMultiplier;
    // Hard cap: Short Gamma → max 35 (floor D grade)
    final capped    = regimeFail
        ? rawFinal.clamp(0.0, 35.0)
        : rawFinal.clamp(0.0, 100.0);
    final total     = capped.round();

    return OptionScore(
      total:           total,
      baseScore:       baseScore,
      deltaScore:      deltaScore,
      dteScore:        dteScore,
      spreadScore:     spreadScore,
      ivScore:         ivScore,
      liquidityScore:  liquidityScore,
      moneynessScore:  moneynessScore,
      gexMultiplier:   gexMultiplier,
      vannaMultiplier: vannaMultiplier,
      regimeFail:      regimeFail,
      ivpUsed:         ivpUsed,
      grade:           OptionScore._grade(total),
      flags:           flags,
    );
  }
}
