from __future__ import annotations

# =============================================================================
# services/option_scoring.py
# =============================================================================
# Options contract scoring engine 0-100.
# Exact port of OptionScoringEngine from option_scoring_engine.dart.
#
# Note on IV convention:
#   contract["impliedVolatility"] is expected as PERCENT (e.g. 21.0 = 21%)
#   matching the raw Schwab field. This matches Dart usage.
# =============================================================================
#
# SCORES THE INSTRUMENT, NOT THE TRADE. There is no price target, no budget and
# no direction here — a high score means "this is a clean option to own",
# never "this will make money". services/option_decision.py is the layer that
# adds a thesis, and it embeds this score as one input.
#
# STRUCTURE: six ADDITIVE components summing to a 0-100 base, then two
# MULTIPLICATIVE regime factors:
#
#   delta      20   peaks at |Δ| ≈ 0.40
#   DTE        20   peaks in the 21-45 day band
#   IV         20   IV percentile when available, raw IV otherwise
#   liquidity  15   open interest + volume/OI, minus a slippage penalty
#   moneyness  15   peaks slightly OTM
#   spread     10   bid/ask width relative to mid
#   ────────────────
#   base      100
#   x GEX multiplier    (0.50 - 1.20)
#   x vanna multiplier  (0.60 - 1.00)
#
# ADDITIVE vs MULTIPLICATIVE IS THE DESIGN. Component quality trades off — poor
# liquidity can be offset by an excellent DTE — but the REGIME does not: an
# unfavourable dealer-positioning backdrop degrades every contract in the name
# at once, so it scales the whole score rather than subtracting from it. A
# multiplier can never rescue a bad base, which is intended.
#
# THE REGIME LAYER IS OPTIONAL. Without `iv_analysis` both multipliers are 1.0
# and the score is pure contract mechanics — perfectly usable, just blind to
# positioning. `ivp_used` reports whether the IV component had history behind it.
#
# ⚠️ IV UNITS: contract["impliedVolatility"] is PERCENT here (21.0 = 21%), the
# raw Schwab convention — opposite to the pricing services, which take decimals.

from dataclasses import dataclass, field
from typing import Optional

from core.constants import SCORE_GRADE_A, SCORE_GRADE_B, SCORE_GRADE_C, SHORT_GAMMA_CAP, IV_DEEP_LONG_GEX
from services.iv_analytics import GammaRegime, GammaSlope, VannaRegime


@dataclass
class OptionScore:
    total: int                 # 0-100 final (regime-adjusted)
    base_score: int            # 0-100 before regime multiplier
    delta_score: int           # 0-20
    dte_score: int             # 0-20
    spread_score: int          # 0-10
    iv_score: int              # 0-20 (IVP-based when available)
    liquidity_score: int       # 0-15
    moneyness_score: int       # 0-15
    gex_multiplier: float      # 0.50-1.20
    vanna_multiplier: float    # 0.60-1.00
    regime_fail: bool
    ivp_used: bool
    grade: str                 # A / B / C / D
    flags: list[str] = field(default_factory=list)

    @property
    def regime_multiplier(self) -> float:
        return self.gex_multiplier * self.vanna_multiplier

    @staticmethod
    def _grade(total: int) -> str:
        if total >= SCORE_GRADE_A:
            return "A"
        if total >= SCORE_GRADE_B:
            return "B"
        if total >= SCORE_GRADE_C:
            return "C"
        return "D"


def score(
    contract: dict,
    underlying_price: float,
    iv_analysis:Optional[dict] = None,
) -> OptionScore:
    """Score a single option contract 0-100.

    Args:
        contract: Schwab option contract dict (raw, IV in percent).
        underlying_price: Current underlying price.
        iv_analysis: Optional IV analytics result (enables regime multiplier and IVP scoring).

    Returns:
        OptionScore with all components, grade, and flags.
    """
    # Human-readable notes accumulated as scoring proceeds. Not decorative: they
    # are the audit trail explaining WHY a contract scored as it did, and the UI
    # surfaces them directly.
    flags: list[str] = []

    bid = float(contract.get("bid") or 0)
    ask = float(contract.get("ask") or 0)
    delta = float(contract.get("delta") or 0)

    # Zero-liquidity guard
    # Short-circuits to a total of 0 rather than scoring the other components.
    # No market means no score is meaningful — an option nobody quotes cannot be
    # bought at any price, however attractive its delta and DTE look.
    # Note the AND: a one-sided market still gets scored, and the spread
    # component penalises it heavily.
    if bid == 0 and ask == 0:
        return OptionScore(
            total=0, base_score=0, delta_score=0, dte_score=0, spread_score=0,
            iv_score=0, liquidity_score=0, moneyness_score=0,
            gex_multiplier=1.0, vanna_multiplier=1.0,
            regime_fail=False, ivp_used=False, grade="D",
            flags=["No market (illiquid)"],
        )

    # ── 1. Delta quality (0-20) ───────────────────────────────────────────────
    delta = float(contract.get("delta", 0))
    abs_delta = abs(delta)
    if abs_delta == 0:
        delta_score = 0
        flags.append("Delta unavailable")
    else:
        # Peaks at |Δ| = 0.40 and falls off LINEARLY in both directions, hitting
        # zero at Δ=0 and Δ=0.80. 0.40 is the swing-trading sweet spot: enough
        # directional exposure to pay off on a move, without the premium of a
        # near-ITM option or the low hit rate of a far-OTM one.
        dist = abs(abs_delta - 0.40)
        delta_score = int(max(0, min(20, round(20 * (1 - dist / 0.40)))))

    # ── 2. DTE zone (0-20) ────────────────────────────────────────────────────
    # DTE curve is a PLATEAU, not a peak: full marks across 21-45 days, ramping
    # up below and decaying above. Under 21 days theta accelerates faster than
    # most theses resolve; beyond 45 you pay for time the thesis does not need.
    dte = int(contract.get("daysToExpiration", 0))
    if dte <= 0:
        dte_score = 0
        flags.append("Expiring today")
    elif dte <= 7:
        dte_score = round(10.0 * dte / 7)
        flags.append("DTE < 7 — pin risk")
    elif dte <= 21:
        dte_score = round(10.0 + 10.0 * (dte - 7) / 14)
    elif dte <= 45:
        dte_score = 20
    elif dte <= 90:
        dte_score = round(20.0 - (dte - 45) / 45.0 * 10)
    else:
        dte_score = int(max(0.0, min(10.0, 10.0 - (dte - 90) / 90.0 * 10)))
        if dte > 180:
            flags.append("DTE > 180 — very long-dated")

    # ── 3. Spread quality (0-10) ──────────────────────────────────────────────
    # Spread RELATIVE to mid, so a $0.10 spread on a $0.40 option (25%) is
    # correctly worse than the same spread on a $8.00 option (1.25%). The
    # fallback of 1.0 for a zero mid means "worst possible", scoring 0.
    mid = (bid + ask) / 2
    spread_pct = abs(ask - bid) / mid if mid > 0 else 1.0
    if spread_pct >= 1.0:
        spread_score = 0
        flags.append("No real market")
    elif spread_pct > 0.20:
        spread_score = int(max(0, min(5, round(5.0 * (1 - (spread_pct - 0.20) / 0.80)))))
        flags.append("Wide spread")
    else:
        spread_score = int(max(0, min(10, round(5.0 + 5.0 * (1 - spread_pct / 0.20)))))

    # ── 4. IV score (0-20) — IVP-based when available ─────────────────────────
    # TWO PATHS WITH OPPOSITE LOGIC — the most important subtlety in this file.
    #
    # WITH IVP (preferred): LOW percentile scores highest. Cheap vol relative to
    #   this name's own history is what a buyer wants.
    # WITHOUT IVP (fallback): HIGH raw IV scores higher, because with no history
    #   to compare against, raw IV is read as movement potential instead.
    #
    # The two rank contracts in opposite directions, which is why `ivp_used` is
    # returned and a flag is raised on the fallback path — a score computed
    # without history is not comparable to one computed with it.
    ivp = iv_analysis.get("iv_percentile") if iv_analysis else None
    ivp_used = ivp is not None
    if ivp_used:
        if ivp <= 20:
            iv_score = 20
        elif ivp <= 40:
            iv_score = 16
        elif ivp <= 60:
            iv_score = 10
        elif ivp <= 80:
            iv_score = 5
        else:
            iv_score = 2
    else:
        iv = float(contract.get("impliedVolatility", 0))  # percent
        if iv >= 50:
            iv_score = 15
        elif iv >= 20:
            iv_score = round(8 + 7 * (iv - 20) / 30)
        elif iv >= 5:
            iv_score = int(max(0, min(8, round(8 * (iv - 5) / 15))))
        else:
            iv_score = 0
            flags.append(
            f"IV scored by raw volatility level ({iv:.0f}%) — no IVP history available. "
            "High raw IV scores higher (movement potential), opposite to IVP logic."
        )

    # ── 5. Liquidity (0-15) ───────────────────────────────────────────────────
    oi = int(contract.get("openInterest", 0))
    vol = int(contract.get("totalVolume", 0))
    vol_oi_ratio = vol / oi if oi > 0 else 0.0

    # Open interest = how much is OUTSTANDING (can you get out?). Stepped rather
    # than continuous because the difference between 100 and 500 contracts
    # matters far more than between 5,000 and 6,000.
    if oi >= 5000:
        oi_sub = 10
    elif oi >= 1000:
        oi_sub = 8
    elif oi >= 500:
        oi_sub = 5
    elif oi >= 100:
        oi_sub = 3
    else:
        oi_sub = 0
    if oi == 0:
        flags.append("No open interest")

    # Volume/OI = how much is TRADING TODAY relative to what is outstanding
    # (is the market live?). High OI with zero volume is stale interest that
    # nobody is currently quoting — hence the separate flag below.
    if vol_oi_ratio >= 0.50:
        vol_oi_sub = 5
    elif vol_oi_ratio >= 0.20:
        vol_oi_sub = 3
    elif vol_oi_ratio >= 0.05:
        vol_oi_sub = 1
    else:
        vol_oi_sub = 0
    if oi > 0 and vol == 0:
        flags.append("Zero volume today — stale OI")

    # Slippage gate: (ask - theo) / mid > 2%
    # Measures how far ABOVE fair value you actually pay by lifting the offer —
    # the real cost of entry, which the spread component alone misses. A tight
    # spread sitting entirely above theo is still expensive to cross.
    # Deducted from the liquidity component rather than scored separately,
    # because it is a tradeability cost.
    slippage_penalty = 0
    theo = float(contract.get("theoreticalOptionValue", 0))
    if theo > 0 and mid > 0:
        slippage_pct = (ask - theo) / mid
        if slippage_pct > 0.02:
            slippage_penalty = 5
            flags.append(f"Slippage gate: ask is {slippage_pct*100:.1f}% above theo (> 2% threshold)")

    liquidity_score = max(0, min(15, oi_sub + vol_oi_sub - slippage_penalty))

    # ── 6. Moneyness (0-15) ───────────────────────────────────────────────────
    strike = float(contract.get("strikePrice", 0))
    pct_otm = abs(strike - underlying_price) / underlying_price if underlying_price > 0 else 0.0
    is_itm = bool(contract.get("inTheMoney", False))

    # Peaks at 1-7% OTM (15 pts), NOT at the money. Slightly OTM options carry
    # the most convexity per dollar; ATM costs more for the same directional
    # exposure, and deep OTM needs an implausible move. ITM is capped at 8 —
    # you are paying for intrinsic value that carries no optionality.
    if is_itm:
        if pct_otm <= 0.05:
            moneyness_score = 8
        else:
            moneyness_score = 4
            flags.append("Deep ITM")
    else:
        if pct_otm <= 0.01:
            moneyness_score = 12
        elif pct_otm <= 0.07:
            moneyness_score = 15
        elif pct_otm <= 0.12:
            moneyness_score = 7
        else:
            moneyness_score = 0
            flags.append("Deep OTM")

    base_score = max(0, min(100, delta_score + dte_score + spread_score + iv_score + liquidity_score + moneyness_score))

    # ── Regime Multiplier ─────────────────────────────────────────────────────
    gex_multiplier = 1.0
    vanna_multiplier = 1.0
    regime_fail = False

    if iv_analysis:
        gr = iv_analysis.get("gamma_regime", GammaRegime.unknown)
        slope = iv_analysis.get("gamma_slope", GammaSlope.flat)
        flip_pct = iv_analysis.get("spot_to_zero_gamma_pct")
        total_gex = iv_analysis.get("total_gex")
        vr = iv_analysis.get("vanna_regime", VannaRegime.unknown)

        # Every comparison below accepts BOTH the enum and its string value,
        # because iv_analysis may arrive as a live dataclass or as JSON parsed
        # back from the database.
        #
        # Gm — GEX Multiplier
        # NEGATIVE GAMMA IS A HARD FAIL, not a mild penalty: dealers hedging into
        # the move amplify it, so the structural support that makes a long option
        # position survivable is absent. It sets regime_fail, which caps the
        # final score at SHORT_GAMMA_CAP regardless of how good the contract is.
        if gr == GammaRegime.negative or gr == "negative":
            regime_fail = True
            gex_multiplier = 0.50
            flags.append("REGIME FAIL: Short Gamma — dealers amplify moves; structural support absent")
        # Within 0.5% of the zero-gamma level: the regime could flip on a single
        # session's move, so today's positive-gamma reading is unreliable.
        # Penalised even though gamma is currently favourable.
        elif flip_pct is not None and abs(flip_pct) <= 0.5:
            gex_multiplier = 0.70
            flags.append(f"Near Zero Gamma flip ({flip_pct:.2f}% from flip) — high regime-shift probability")
        elif gr == GammaRegime.positive or gr == "positive":
            # The only multiplier above 1.0 in the file. Deep long gamma
            # (>= $1B) is a genuinely stabilising backdrop, so it is a real
            # bonus rather than merely the absence of a penalty.
            if total_gex is not None and total_gex >= IV_DEEP_LONG_GEX:
                gex_multiplier = 1.20
            elif slope == GammaSlope.rising or slope == "rising":
                gex_multiplier = 1.10
            elif slope == GammaSlope.flat or slope == "flat":
                gex_multiplier = 1.00
            else:  # falling
                gex_multiplier = 0.85

        # Vm — Vanna Multiplier
        # Fires only on the CONJUNCTION of two conditions — thinning gamma AND a
        # bearish vanna regime. Either alone is unremarkable; together they
        # describe a rally whose dealer support is eroding while a vol move would
        # push hedging the wrong way. A 0.60 multiplier is the second-largest
        # penalty here, behind only the short-gamma fail.
        slope_falling = slope == GammaSlope.falling or slope == "falling"
        vanna_bearish = vr in (VannaRegime.bearish_on_vol_crush, "bearishOnVolCrush", "bearishOnVolSpike")
        if slope_falling and vanna_bearish:
            vanna_multiplier = 0.60
            flags.append(
                "Vanna Divergence: declining gamma slope + bearish dealer delta hedge — "
                "fragile rally; reversal risk elevated"
            )

    # Multipliers compound, so the worst case (0.50 x 0.60 = 0.30) can cut a
    # score to under a third even before the hard cap applies.
    raw_final = base_score * gex_multiplier * vanna_multiplier
    # THE HARD CAP IS THE REAL TEETH of regime_fail: a perfect 100-point contract
    # in a short-gamma regime cannot score above SHORT_GAMMA_CAP (35) — a D. The
    # multiplier alone would have left it at 50, still a passing grade.
    capped = min(raw_final, SHORT_GAMMA_CAP) if regime_fail else min(raw_final, 100.0)
    total = round(max(0.0, capped))

    return OptionScore(
        total=total,
        base_score=base_score,
        delta_score=delta_score,
        dte_score=dte_score,
        spread_score=spread_score,
        iv_score=iv_score,
        liquidity_score=liquidity_score,
        moneyness_score=moneyness_score,
        gex_multiplier=gex_multiplier,
        vanna_multiplier=vanna_multiplier,
        regime_fail=regime_fail,
        ivp_used=ivp_used,
        grade=OptionScore._grade(total),
        flags=flags,
    )
