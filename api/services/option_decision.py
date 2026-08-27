# =============================================================================
# services/option_decision.py
# =============================================================================
# Option decision analysis engine.
# Exact port of OptionDecisionEngine from option_decision_engine.dart.
# =============================================================================
#
# SCORES THE TRADE, NOT THE INSTRUMENT. services/option_scoring.py grades the
# contract in isolation; this layer adds everything that depends on the trader's
# actual thesis — where they think the stock goes, by when, and how much they
# will spend — and embeds that score as one input among many.
#
# THE CENTRAL CALCULATION is a second-order Taylor expansion of option value in
# spot, with time decay deducted separately:
#
#     move  = price_target - underlying_price
#     gross = (delta*move + 0.5*gamma*move^2) * 100 * contracts
#     net   = gross - |daily_theta| * days_to_target
#
# The gamma term is what makes this more than a naive delta projection: for a
# long option gamma is positive, so it ADDS on a favourable move and CUSHIONS an
# adverse one — precisely the convexity being bought.
#
# THREE LIMITS TO READ THE OUTPUT AGAINST:
#   1. GREEKS ARE FROZEN at today's values. Over a large move real delta and
#      gamma both change, so accuracy decays as |move| grows. Good for a few
#      percent; indicative for a large move.
#   2. VOL IS ASSUMED CONSTANT. A move to target that also crushes IV — the
#      classic post-earnings outcome — is not modelled at all.
#      vega_dollar_per_1pct_iv exists so the caller can size that gap by hand.
#   3. days_to_target=0 (the default) deducts NO theta: the projection is an
#      instantaneous re-mark, not a hold-to-target estimate.
#
# EVERYTHING IS PER-POSITION, not per-contract: dollar figures are multiplied by
# 100 (the contract multiplier) and by the contract count, so they are what the
# trader actually risks and earns.
#
# NOTE: `Optional` is used in the signatures below but never imported. Harmless
# today only because `from __future__ import annotations` makes annotations lazy
# strings — but typing.get_type_hints() on these functions would raise NameError.

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum

from core.chain_utils import normalize_chain
from services.option_scoring import OptionScore, score as score_contract


# The trader's THESIS, deliberately independent of whether the contract is a
# call or a put. A mismatch between the two is a reported finding that forces a
# hard 'avoid', never something silently corrected.
class TradeDirection(str, Enum):
    bullish = "bullish"
    bearish = "bearish"


# Three-way verdict. 'watch' is the honest middle: the trade is not disqualified
# but does not clear the bar for conviction.
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

    Parsed from the SYMBOL rather than taken from a field, because the OCC
    symbol is the one piece of contract identity that is never ambiguous.

    The regex anchors on 6 digits (the YYMMDD expiry) followed by C or P and
    then a digit, which cannot collide with letters in the underlying's ticker.

    NOTE it FALLS BACK TO True (call) on an unparseable symbol — a silent
    default. A malformed symbol on a put would be analysed as a call, producing
    a wrong break-even and an inverted direction-alignment check.
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
    iv_analysis:Optional[dict] = None,
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
    # The contract-quality score is computed first and carried through — it is
    # one input to the recommendation, not a separate output.
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
    # Priced off the ASK, not the mid — what you actually pay to lift the offer.
    # Conservative by design: every downstream return and ratio is measured
    # against a realistic entry rather than an optimistic one.
    # int() below TRUNCATES, giving whole contracts that fit the budget.
    entry_cost = ask * c * 100
    contracts_affordable = 0 if ask == 0 else int(max_budget / (ask * 100))

    # ── Theta drag ────────────────────────────────────────────────────────────
    # Schwab reports theta per contract per calendar day; x100 x contracts makes
    # it the position's dollar decay per day.
    daily_theta_drag = theta * 100 * c
    # LINEAR extrapolation of TODAY's theta to expiry. Real decay ACCELERATES
    # into expiry, so this UNDERSTATES total drag — most on short-dated options,
    # which is exactly where it matters most.
    total_theta_drag = daily_theta_drag * dte  # full decay to expiry (linear approx)

    # ── P&L projection (gamma-adjusted, theta-deducted to target date) ────────
    # Signed move — negative for a bearish target, which combines correctly with
    # a put's negative delta to give positive P&L.
    move = price_target - underlying_price
    # Second-order Taylor expansion. The gamma term is ALWAYS POSITIVE for a long
    # option (gamma > 0) regardless of the move's direction — that is the
    # convexity being paid for, and why this beats a pure delta projection in
    # both directions.
    pnl_gross = (delta * move + 0.5 * gamma * move ** 2) * 100 * c
    # abs() so decay is always subtracted, whatever sign Schwab reports theta
    # with. Zero when days_to_target is 0 — see limit 3 in the header.
    theta_decay_to_target = abs(daily_theta_drag) * days_to_target if days_to_target > 0 else 0.0
    estimated_pnl = pnl_gross - theta_decay_to_target
    estimated_return = estimated_pnl / entry_cost * 100 if entry_cost != 0 else 0.0

    # ── Break-even ────────────────────────────────────────────────────────────
    # Break-even AT EXPIRY, computed off the ask. Two consequences worth knowing:
    # it uses what you pay rather than the mid, and it ignores any extrinsic
    # value still left if you sell early — so selling before expiry generally
    # breaks even sooner than this implies.
    break_even_price = strike + ask if is_call else strike - ask
    break_even_move = abs(break_even_price - underlying_price)
    break_even_move_pct = break_even_move / underlying_price * 100 if underlying_price != 0 else 0.0

    # ── Pricing edge ──────────────────────────────────────────────────────────
    # Schwab's own theoretical value against the market mid. Depends entirely on
    # Schwab's vol assumption, so it is a cross-check rather than an independent
    # valuation — services/fair_value_engine.py is the real model comparison.
    pricing_edge = theo - mid
    # Threshold of max($0.05, 2% of mid): an absolute floor for cheap options
    # where 2% is less than a tick, and a relative one for expensive ones, so a
    # penny of rounding is never reported as an edge.
    edge_threshold = max(0.05, mid * 0.02)
    is_cheap = pricing_edge > edge_threshold

    # ── Risk framing ──────────────────────────────────────────────────────────
    # LONG OPTIONS ONLY: max loss equals the premium paid. This engine has no
    # concept of a short or spread position, where max loss can be unbounded or
    # defined by a spread width.
    max_loss = entry_cost
    # Deliberately 0.0 when projected P&L is negative rather than a negative
    # ratio — a losing projection has no meaningful risk/reward, and a negative
    # value would sort misleadingly.
    risk_reward_ratio = estimated_pnl / max_loss if max_loss > 0 and estimated_pnl > 0 else 0.0

    # ── Volume / OI ratio ─────────────────────────────────────────────────────
    # Today's volume against total open interest. Above 0.5 means more than half
    # the outstanding contracts changed hands today — a positioning signal, since
    # it implies someone is establishing or unwinding at scale.
    vol_oi_ratio = vol / oi if oi > 0 else 0.0
    unusual_activity = vol_oi_ratio > 0.5

    # ── Vega exposure ─────────────────────────────────────────────────────────
    # Dollar P&L per ONE vol point. The header's blind spot (limit 2) made
    # measurable: the projection assumes constant vol, so this is how much a
    # post-event IV crush would cost on top of the modelled outcome.
    vega_dollar_per_1pct_iv = vega * 100 * c

    # ── Gamma risk ────────────────────────────────────────────────────────────
    # Near expiry, high gamma cuts both ways: delta swings violently, so the
    # position stops behaving like the one that was sized. A warning about
    # MANAGEABILITY, not about expected value.
    high_gamma_risk = dte < 10 and gamma > 0.05

    # ── Direction alignment ────────────────────────────────────────────────────
    # Does the INSTRUMENT match the THESIS? A call with a bearish view is not a
    # trade with a bad score — it is the wrong instrument entirely, and it forces
    # a hard 'avoid' below.
    direction_aligned = (
        (is_call and direction == TradeDirection.bullish) or
        (not is_call and direction == TradeDirection.bearish)
    )

    # ── Reasons & warnings ────────────────────────────────────────────────────
    # Two parallel narratives — what argues FOR the trade and what argues
    # AGAINST it. The warning COUNT is not merely informational: it gates the
    # 'buy' verdict at the bottom, so each append below tightens the bar.
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
    # THE MOST IMPORTANT CHECK IN THE FILE. If break-even needs a larger move
    # than the target itself, the option expires WORTHLESS at the trader's own
    # price target — the thesis can be exactly right and the trade still loses
    # everything. Easy to miss when eyeballing a chain.
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

    # Theta measured RELATIVE to what was paid: losing 2% of the position's
    # value per day is heavy regardless of the absolute dollar figure.
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
    # THREE HARD DISQUALIFIERS, any one of which forces 'avoid': wrong instrument
    # for the thesis, a projection that does not make money even if the target is
    # hit, or a cost more than 1.5x over budget. Note the 1.5x tolerance —
    # modestly over budget is a warning, not a veto.
    if not direction_aligned or estimated_pnl <= 0 or entry_cost > max_budget * 1.5:
        recommendation = Recommendation.avoid
    # 'buy' requires FOUR conditions simultaneously: a good contract (>= 65),
    # aligned direction, a meaningful projected return (>= 30%), AND at most one
    # warning. That last clause is the strictest — an otherwise excellent setup
    # carrying two concerns drops to 'watch'.
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
    iv_analysis:Optional[dict] = None,
    top_n: int = 5,
) -> list[OptionDecisionResult]:
    """Rank all contracts in a chain and return top N by composite rank.

    Matches OptionDecisionEngine.rankAll() sort order: buy > watch > avoid, then score desc.

    Analyses only ONE SIDE of the chain — calls when bullish, puts when bearish —
    so results are never mixed, unlike /scoring/rank which is direction-agnostic.

    Ordering puts the recommendation band FIRST and contract score second, so a
    modestly-scored 'buy' outranks a high-scoring 'watch'. That is the right
    precedence once the caller has committed to a direction and a target: the
    thesis-level verdict dominates instrument quality.

    NOTE underlying_price is read from chain["underlyingPrice"], NOT passed in.
    A chain missing that key yields 0.0, which makes every percentage-of-spot
    figure nonsense — so the chain must be a complete Schwab payload.
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
