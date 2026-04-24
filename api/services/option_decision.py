# =============================================================================
# services/option_decision.py
# =============================================================================
# Option decision analysis engine.
# Exact port of OptionDecisionEngine from option_decision_engine.dart.
# =============================================================================

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum

from core.chain_utils import normalize_chain
from services.option_scoring import OptionScore, score as score_contract


class TradeDirection(str, Enum):
    bullish = "bullish"
    bearish = "bearish"


class Recommendation(str, Enum):
    buy = "buy"
    watch = "watch"
    avoid = "avoid"


@dataclass
class OptionDecisionResult:
    contract: dict
    score: OptionScore

    # Cost
    entry_cost: float
    contracts_affordable: int

    # P&L projection (gamma-adjusted, theta-deducted to target date)
    estimated_pnl: float
    estimated_return: float

    # Break-even
    break_even_price: float
    break_even_move: float
    break_even_move_pct: float

    # Theta drag
    daily_theta_drag: float
    total_theta_drag: float
    theta_decay_to_target: float  # theta deducted from P&L over days_to_target

    # Risk framing
    max_loss: float             # = entry_cost for long options
    risk_reward_ratio: float    # estimated_pnl / max_loss

    # Pricing edge
    pricing_edge: float
    is_cheap: bool

    # Volume/OI
    vol_oi_ratio: float
    unusual_activity: bool

    # Vega exposure
    vega_dollar_per_1pct_iv: float

    # Gamma risk
    high_gamma_risk: bool

    # Recommendation
    recommendation: Recommendation
    reasons: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _is_call_from_symbol(symbol: str) -> bool:
    """Detect call/put from OCC symbol format (e.g. ORCL260117C00155000).
    Matches OptionDecisionEngine.analyze() logic exactly.
    """
    match = re.search(r'\d{6}([CP])\d', symbol)
    if match:
        return match.group(1) == 'C'
    return True  # fallback


def analyze(
    contract: dict,
    underlying_price: float,
    direction: TradeDirection,
    price_target: float,
    max_budget: float,
    contracts: int = 1,
    days_to_target: int = 0,
    iv_analysis: dict | None = None,
) -> OptionDecisionResult:
    """Full decision analysis for one contract.

    Matches OptionDecisionEngine.analyze() exactly.

    Args:
        contract: Schwab option contract dict.
        underlying_price: Current underlying price.
        direction: Trade direction (bullish or bearish).
        price_target: Where the trader thinks the stock goes.
        max_budget: Max dollars to spend.
        contracts: Number of contracts.
        iv_analysis: Optional IV analytics result dict.

    Returns:
        OptionDecisionResult with all analysis and recommendation.
    """
    is_call = _is_call_from_symbol(contract.get("symbol", ""))
    option_score = score_contract(contract, underlying_price, iv_analysis=iv_analysis)
    c = contracts

    ask = float(contract.get("ask", 0))
    bid = float(contract.get("bid", 0))
    delta = float(contract.get("delta", 0))
    theta = float(contract.get("theta", 0))
    vega = float(contract.get("vega", 0))
    gamma = float(contract.get("gamma", 0))
    strike = float(contract.get("strikePrice", 0))
    dte = int(contract.get("daysToExpiration", 0))
    oi = int(contract.get("openInterest", 0))
    vol = int(contract.get("totalVolume", 0))
    theo = float(contract.get("theoreticalOptionValue", 0))
    mid = (bid + ask) / 2

    # ── Cost ──────────────────────────────────────────────────────────────────
    entry_cost = ask * c * 100
    contracts_affordable = 0 if ask == 0 else int(max_budget / (ask * 100))

    # ── P&L projection (gamma-adjusted, theta-deducted to target date) ────────
    move = price_target - underlying_price
    pnl_gross = (delta * move + 0.5 * gamma * move ** 2) * 100 * c
    theta_decay_to_target = abs(daily_theta_drag) * days_to_target if days_to_target > 0 else 0.0
    estimated_pnl = pnl_gross - theta_decay_to_target
    estimated_return = estimated_pnl / entry_cost * 100 if entry_cost != 0 else 0.0

    # ── Break-even ────────────────────────────────────────────────────────────
    break_even_price = strike + ask if is_call else strike - ask
    break_even_move = abs(break_even_price - underlying_price)
    break_even_move_pct = break_even_move / underlying_price * 100 if underlying_price != 0 else 0.0

    # ── Theta drag ────────────────────────────────────────────────────────────
    daily_theta_drag = theta * 100 * c
    total_theta_drag = daily_theta_drag * dte  # full decay to expiry (linear approx)

    # ── Pricing edge ──────────────────────────────────────────────────────────
    pricing_edge = theo - mid
    edge_threshold = max(0.05, mid * 0.02)
    is_cheap = pricing_edge > edge_threshold

    # ── Risk framing ──────────────────────────────────────────────────────────
    max_loss = entry_cost
    risk_reward_ratio = estimated_pnl / max_loss if max_loss > 0 and estimated_pnl > 0 else 0.0

    # ── Volume / OI ratio ─────────────────────────────────────────────────────
    vol_oi_ratio = vol / oi if oi > 0 else 0.0
    unusual_activity = vol_oi_ratio > 0.5

    # ── Vega exposure ─────────────────────────────────────────────────────────
    vega_dollar_per_1pct_iv = vega * 100 * c

    # ── Gamma risk ────────────────────────────────────────────────────────────
    high_gamma_risk = dte < 10 and gamma > 0.05

    # ── Direction alignment ────────────────────────────────────────────────────
    direction_aligned = (
        (is_call and direction == TradeDirection.bullish) or
        (not is_call and direction == TradeDirection.bearish)
    )

    # ── Reasons & warnings ────────────────────────────────────────────────────
    reasons: list[str] = []
    warnings: list[str] = []

    if not direction_aligned:
        warnings.append(
            f"Direction mismatch — {'CALL' if is_call else 'PUT'} does not match {direction.value} thesis"
        )

    if estimated_pnl > 0:
        suffix = f" (after {days_to_target}d theta decay)" if days_to_target > 0 else ""
        reasons.append(f"γ-adj est. +${estimated_pnl:.0f} at ${price_target:.2f}{suffix}")
    else:
        suffix = f" after {days_to_target}d theta decay" if days_to_target > 0 else ""
        warnings.append(f"Negative γ-adj P&L (${estimated_pnl:.0f}){suffix} — target may be insufficient")

    if estimated_return >= 50:
        reasons.append(f"{estimated_return:.0f}% return if target hit")

    target_move_pct = abs(price_target - underlying_price) / underlying_price * 100 if underlying_price != 0 else 0.0
    if break_even_move_pct > target_move_pct and target_move_pct > 0:
        warnings.append(
            f"Break-even requires {break_even_move_pct:.1f}% move "
            f"but target is only {target_move_pct:.1f}% away — "
            f"option expires worthless at target"
        )
    else:
        reasons.append(f"Break-even at ${break_even_price:.2f} ({break_even_move_pct:.1f}% move needed)")

    if is_cheap:
        reasons.append(f"Priced below theoretical by ${pricing_edge:.2f} — potential edge")
    elif pricing_edge < -0.10:
        warnings.append(f"Priced ${abs(pricing_edge):.2f} above theoretical — paying premium")

    if entry_cost > 0 and abs(daily_theta_drag) > entry_cost * 0.02:
        warnings.append(
            f"Heavy theta: −${abs(daily_theta_drag):.2f}/day "
            f"(total −${abs(total_theta_drag):.0f} to expiry)"
        )
    else:
        reasons.append(f"Theta drag manageable at −${abs(daily_theta_drag):.2f}/day")

    if unusual_activity:
        reasons.append(f"Unusual activity: vol/OI ratio {vol_oi_ratio:.2f} — elevated flow vs open interest")

    if entry_cost > 0 and abs(vega_dollar_per_1pct_iv) > entry_cost * 0.05:
        warnings.append(f"High vega exposure: ±${abs(vega_dollar_per_1pct_iv):.0f} per 1% IV change")

    if high_gamma_risk:
        warnings.append("High gamma risk — delta changes rapidly this close to expiry")

    if entry_cost > max_budget:
        warnings.append(
            f"Over budget — costs ${entry_cost:.0f} vs ${max_budget:.0f} max "
            f"(can afford {contracts_affordable} contract{'s' if contracts_affordable != 1 else ''})"
        )

    # ── Recommendation ────────────────────────────────────────────────────────
    if not direction_aligned or estimated_pnl <= 0 or entry_cost > max_budget * 1.5:
        recommendation = Recommendation.avoid
    elif option_score.total >= 65 and direction_aligned and estimated_return >= 30 and len(warnings) <= 1:
        recommendation = Recommendation.buy
    else:
        recommendation = Recommendation.watch

    return OptionDecisionResult(
        contract=contract,
        score=option_score,
        entry_cost=entry_cost,
        contracts_affordable=contracts_affordable,
        estimated_pnl=estimated_pnl,
        estimated_return=estimated_return,
        break_even_price=break_even_price,
        break_even_move=break_even_move,
        break_even_move_pct=break_even_move_pct,
        daily_theta_drag=daily_theta_drag,
        total_theta_drag=total_theta_drag,
        theta_decay_to_target=theta_decay_to_target,
        max_loss=max_loss,
        risk_reward_ratio=risk_reward_ratio,
        pricing_edge=pricing_edge,
        is_cheap=is_cheap,
        vol_oi_ratio=vol_oi_ratio,
        unusual_activity=unusual_activity,
        vega_dollar_per_1pct_iv=vega_dollar_per_1pct_iv,
        high_gamma_risk=high_gamma_risk,
        recommendation=recommendation,
        reasons=reasons,
        warnings=warnings,
    )


def rank_all(
    chain: dict,
    direction: TradeDirection,
    price_target: float,
    max_budget: float,
    contracts: int = 1,
    days_to_target: int = 0,
    iv_analysis: dict | None = None,
    top_n: int = 5,
) -> list[OptionDecisionResult]:
    """Rank all contracts in a chain and return top N by composite rank.

    Matches OptionDecisionEngine.rankAll() sort order: buy > watch > avoid, then score desc.
    """
    chain = normalize_chain(chain)
    is_call_direction = direction == TradeDirection.bullish
    results: list[OptionDecisionResult] = []

    for exp in chain.get("expirations", []):
        contracts_list = exp.get("calls", []) if is_call_direction else exp.get("puts", [])
        for c in contracts_list:
            if float(c.get("ask", 0)) == 0 and float(c.get("bid", 0)) == 0:
                continue
            results.append(analyze(
                contract=c,
                underlying_price=float(chain.get("underlyingPrice", 0)),
                direction=direction,
                price_target=price_target,
                max_budget=max_budget,
                contracts=contracts,
                days_to_target=days_to_target,
                iv_analysis=iv_analysis,
            ))

    def rec_order(r: Recommendation) -> int:
        return {Recommendation.buy: 0, Recommendation.watch: 1, Recommendation.avoid: 2}[r]

    results.sort(key=lambda r: (rec_order(r.recommendation), -r.score.total))
    return results[:top_n]
