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

from dataclasses import dataclass, field

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
    iv_analysis: dict | None = None,
) -> OptionScore:
    """Score a single option contract 0-100.

    Args:
        contract: Schwab option contract dict (raw, IV in percent).
        underlying_price: Current underlying price.
        iv_analysis: Optional IV analytics result (enables regime multiplier and IVP scoring).

    Returns:
        OptionScore with all components, grade, and flags.
    """
    flags: list[str] = []

    bid = float(contract.get("bid", 0))
    ask = float(contract.get("ask", 0))

    # Zero-liquidity guard
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
        dist = abs(abs_delta - 0.40)
        delta_score = int(max(0, min(20, round(20 * (1 - dist / 0.40)))))

    # ── 2. DTE zone (0-20) ────────────────────────────────────────────────────
    dte = int(contract.get("daysToExpiration", 0))
    if dte <= 0:
        dte_score = 0
        flags.append("Expiring today")
    elif dte <= 7:
        dte_score = round(20.0 * dte / 7)
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

    # ── 5. Liquidity (0-15) ───────────────────────────────────────────────────
    oi = int(contract.get("openInterest", 0))
    vol = int(contract.get("totalVolume", 0))
    vol_oi_ratio = vol / oi if oi > 0 else 0.0

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

        # Gm — GEX Multiplier
        if gr == GammaRegime.negative or gr == "negative":
            regime_fail = True
            gex_multiplier = 0.50
            flags.append("REGIME FAIL: Short Gamma — dealers amplify moves; structural support absent")
        elif flip_pct is not None and abs(flip_pct) <= 0.5:
            gex_multiplier = 0.70
            flags.append(f"Near Zero Gamma flip ({flip_pct:.2f}% from flip) — high regime-shift probability")
        elif gr == GammaRegime.positive or gr == "positive":
            if total_gex is not None and total_gex >= IV_DEEP_LONG_GEX:
                gex_multiplier = 1.20
            elif slope == GammaSlope.rising or slope == "rising":
                gex_multiplier = 1.10
            elif slope == GammaSlope.flat or slope == "flat":
                gex_multiplier = 1.00
            else:  # falling
                gex_multiplier = 0.85

        # Vm — Vanna Multiplier
        slope_falling = slope == GammaSlope.falling or slope == "falling"
        vanna_bearish = vr in (VannaRegime.bearish_on_vol_crush, "bearishOnVolCrush", "bearishOnVolSpike")
        if slope_falling and vanna_bearish:
            vanna_multiplier = 0.60
            flags.append(
                "Vanna Divergence: declining gamma slope + bearish dealer delta hedge — "
                "fragile rally; reversal risk elevated"
            )

    raw_final = base_score * gex_multiplier * vanna_multiplier
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
