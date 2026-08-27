# =============================================================================
# routers/decision.py  —  mounted at /decision
# =============================================================================
# Trade-level decision analysis: given a price target, a budget and a
# direction, work out whether a specific contract is worth buying.
#
#   POST /decision/analyze   one contract -> full analysis + buy/watch/avoid
#   POST /decision/rank-all  a whole chain -> top N contracts for the thesis
#
# Engine: api/services/option_decision.py
# UI:     lib/features/options/screens/option_decision_wizard.dart
#
# THIS vs /scoring
# ----------------
# /scoring grades the CONTRACT in isolation (liquidity, spread, DTE, IV rank).
# This router grades the TRADE: it embeds that score as one input and adds
# everything that depends on the trader's actual thesis — where they think the
# stock goes, by when, and how much they will spend.
#
# THE CENTRAL CALCULATION
# -----------------------
# Projected P&L is a second-order Taylor expansion of the option value in spot,
# with time decay deducted separately:
#
#     move    = price_target - underlying_price
#     gross   = (delta·move + ½·gamma·move²) · 100 · contracts
#     net     = gross - |daily_theta| · days_to_target
#
# The gamma term is what makes this more than a naive delta projection: for a
# long option gamma is positive, so it ADDS to the estimate on a favourable
# move and CUSHIONS an adverse one, which is precisely the convexity being
# bought. Two limits worth knowing when reading the output:
#
#   * Greeks are frozen at their current values. Over a large move, real delta
#     and gamma both change, so accuracy decays as |move| grows. It is a good
#     estimate for a move of a few percent, indicative for a large one.
#   * Vol is assumed CONSTANT. A move to the target that also crushes IV — the
#     classic post-earnings outcome — is not modelled here. vega_dollar_per_1pct_iv
#     is returned precisely so the caller can size that missing risk by hand.
#
# days_to_target=0 (the default) means "no time passes": theta is not deducted
# at all and the projection is an instantaneous re-mark. Set it to the expected
# holding period to see the decay the thesis actually has to overcome.
# =============================================================================

from typing import Optional
from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.option_decision import analyze, rank_all, TradeDirection, Recommendation

router = APIRouter()


class DecisionRequest(BaseModel):
    contract: dict                    # raw Schwab contract dict
    underlying_price: float = Field(..., gt=0)
    # Call/put is NOT taken from this field — the engine parses it out of the
    # OCC symbol (e.g. ORCL260117C00155000). `direction` is the trader's THESIS,
    # and a mismatch between thesis and instrument is a deliberate, reported
    # finding (it forces a hard 'avoid'), not something silently corrected.
    direction: TradeDirection = TradeDirection.bullish
    price_target: float = Field(..., gt=0)
    max_budget: float = Field(..., gt=0)
    contracts: int = 1
    # Expected holding period in days. 0 = deduct no theta (see header).
    days_to_target: int = 0
    iv_analysis:Optional[dict] = None   # optional; enables regime-aware scoring


class RankAllRequest(BaseModel):
    # Note there is no underlying_price here, unlike DecisionRequest — rank_all
    # reads it from chain["underlyingPrice"] instead. A chain missing that key
    # silently yields 0.0, which makes every percentage-of-spot figure nonsense,
    # so the chain must be a complete Schwab payload.
    chain: dict
    direction: TradeDirection = TradeDirection.bullish
    price_target: float = Field(..., gt=0)
    max_budget: float = Field(..., gt=0)
    contracts: int = 1
    days_to_target: int = 0
    iv_analysis:Optional[dict] = None
    top_n: int = 5


def _result_to_dict(r) -> dict:
    """Flatten an OptionDecisionResult to JSON.

    Hand-written rather than generic serialization for two reasons: the nested
    OptionScore needs flattening to a summary (the full breakdown lives at
    /scoring), and the raw `contract` dict is dropped — the client already has
    it and echoing a whole Schwab contract per result would dominate the payload.

    One field is intentionally not exposed: `break_even_move` (absolute
    dollars). Only `break_even_move_pct` is sent, since percent is what the UI
    displays and what is comparable across strikes.
    """
    return {
        "symbol": r.contract.get("symbol", ""),
        "score": {
            "total": r.score.total,
            "grade": r.score.grade,
            "regime_fail": r.score.regime_fail,
            "flags": r.score.flags,
        },
        # ── Cost ─────────────────────────────────────────────────────────────
        "entry_cost": r.entry_cost,                    # ask x 100 x contracts
        "contracts_affordable": r.contracts_affordable,  # at max_budget
        # ── Projection (see header for the model and its limits) ─────────────
        "estimated_pnl": r.estimated_pnl,        # gamma-adjusted, theta-deducted
        "estimated_return": r.estimated_return,  # percent of entry_cost
        # ── Break-even ───────────────────────────────────────────────────────
        # Computed off the ASK (what you actually pay), not the mid, and at
        # EXPIRY — so it ignores any extrinsic value still left when you sell.
        # Selling before expiry generally breaks even sooner than this implies.
        "break_even_price": r.break_even_price,
        "break_even_move_pct": r.break_even_move_pct,
        # ── Decay ────────────────────────────────────────────────────────────
        "daily_theta_drag": r.daily_theta_drag,
        # Linear extrapolation of today's theta to expiry. Real decay
        # accelerates into expiry, so this UNDERSTATES total drag on a
        # short-dated option.
        "total_theta_drag": r.total_theta_drag,
        "theta_decay_to_target": r.theta_decay_to_target,  # only over days_to_target
        # ── Risk ─────────────────────────────────────────────────────────────
        "max_loss": r.max_loss,                  # = entry_cost; long options only
        "risk_reward_ratio": r.risk_reward_ratio,  # 0.0 when projected P&L ≤ 0
        # ── Pricing edge ─────────────────────────────────────────────────────
        # theoretical value minus mid. is_cheap requires clearing a threshold of
        # max($0.05, 2% of mid) so a penny of rounding is not called an edge.
        # Depends on Schwab's own theoretical value and its vol assumption.
        "pricing_edge": r.pricing_edge,
        "is_cheap": r.is_cheap,
        # ── Flow ─────────────────────────────────────────────────────────────
        "vol_oi_ratio": r.vol_oi_ratio,          # today's volume / open interest
        "unusual_activity": r.unusual_activity,  # ratio > 0.5
        # ── Vol exposure ─────────────────────────────────────────────────────
        # Dollar P&L per 1 vol point. The header's blind spot made measurable.
        "vega_dollar_per_1pct_iv": r.vega_dollar_per_1pct_iv,
        "high_gamma_risk": r.high_gamma_risk,    # dte < 10 and gamma > 0.05
        # ── Verdict ──────────────────────────────────────────────────────────
        # 'avoid' on any hard fail (direction mismatch, non-positive projected
        # P&L, or >1.5x over budget); 'buy' only on score ≥ 65 AND ≥ 30%
        # projected return AND at most one warning; otherwise 'watch'.
        "recommendation": r.recommendation.value,
        "reasons": r.reasons,      # what argues for the trade
        "warnings": r.warnings,    # what argues against it — count gates 'buy'
    }


@router.post("/analyze")
def decision_analyze(req: DecisionRequest):
    """Analyze one contract against the trader's thesis."""
    result = analyze(
        contract=req.contract,
        underlying_price=req.underlying_price,
        direction=req.direction,
        price_target=req.price_target,
        max_budget=req.max_budget,
        contracts=req.contracts,
        days_to_target=req.days_to_target,
        iv_analysis=req.iv_analysis,
    )
    return _result_to_dict(result)


@router.post("/rank-all")
def decision_rank_all(req: RankAllRequest):
    """Analyze every contract on the thesis-appropriate side and return top N.

    Only ONE side of the chain is considered — calls when bullish, puts when
    bearish — so unlike /scoring/rank the results are never mixed. Contracts
    with no market (bid and ask both zero) are skipped.

    Ordering is by recommendation band FIRST (buy > watch > avoid), then by
    contract score descending within a band. So a modestly-scored 'buy' outranks
    a high-scoring 'watch': the thesis-level verdict dominates instrument
    quality, which is the right precedence when the caller has already
    committed to a direction and a target.
    """
    results = rank_all(
        chain=req.chain,
        direction=req.direction,
        price_target=req.price_target,
        max_budget=req.max_budget,
        contracts=req.contracts,
        days_to_target=req.days_to_target,
        iv_analysis=req.iv_analysis,
        top_n=req.top_n,
    )
    return [_result_to_dict(r) for r in results]
