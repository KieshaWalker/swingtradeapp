from __future__ import annotations
from typing import Optional

# =============================================================================
# routers/scoring.py  —  mounted at /scoring
# =============================================================================
# Contract quality scoring, 0-100. Answers "is this a well-constructed option
# to own?" — independent of any directional thesis.
#
#   POST /scoring/score  one contract -> full score breakdown
#   POST /scoring/rank   a whole chain -> top N contracts by score
#
# Engine: api/services/option_scoring.py
# Client: lib/services/python_api/python_api_client.dart
#
# SCORE vs DECISION
# -----------------
# This router and /decision are complementary and easy to confuse:
#   /scoring   grades the CONTRACT — liquidity, spread, delta, DTE, IV rank.
#              No price target, no budget, no direction. A high score means
#              "this is a clean instrument", not "this trade will make money".
#   /decision  grades the TRADE — takes a target, a budget and a direction,
#              projects P&L, and embeds this score as one input.
# Use /scoring to shortlist tradeable contracts; use /decision to choose among
# them once you have a view.
#
# COMPOSITION: six additive components sum to a 0-100 base_score
# (delta 20 + DTE 20 + IV 20 + liquidity 15 + moneyness 15 + spread 10), which
# is then multiplied by two regime factors derived from IV analytics — GEX and
# vanna positioning. Those multipliers only apply when `iv_analysis` is
# supplied; without it they are 1.0 and the score is pure contract mechanics.
#
# IV UNITS: contract["impliedVolatility"] is PERCENT here (21.0 = 21%), the raw
# Schwab convention — the opposite of /bs and /sabr, which take decimals. The
# contract dicts are forwarded from Schwab untouched, so the percent convention
# rides along with them.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.chain_utils import normalize_chain
from services.option_scoring import score

router = APIRouter()


class ScoreRequest(BaseModel):
    contract: dict        # Schwab option contract dict (IV in percent)
    underlying_price: float = Field(..., gt=0)
    # Optional IV analytics bundle (from /iv/analytics). Supplying it unlocks
    # IV-percentile-based scoring and the GEX/vanna regime multipliers; omitting
    # it makes the score purely mechanical. `ivp_used` in the response reports
    # which path was taken.
    iv_analysis:Optional[dict] = None


class RankRequest(BaseModel):
    chain: dict
    underlying_price: float = Field(..., gt=0)
    iv_analysis:Optional[dict] = None
    top_n: int = 10


def _score_to_dict(s) -> dict:
    """Flatten an OptionScore dataclass to JSON.

    Every component is exposed, not just the total, so the UI can show WHY a
    contract scored as it did — a 70 built on great liquidity and mediocre DTE
    is a different proposition from the reverse.
    """
    return {
        "total": s.total,             # base_score x regime multipliers, 0-100
        "base_score": s.base_score,   # pre-regime, so the delta is visible
        "grade": s.grade,             # A/B/C/D banding of total
        # Additive components, max values in comments:
        "delta_score": s.delta_score,          # 20 — peaks at |delta| ≈ 0.40
        "dte_score": s.dte_score,              # 20 — peaks in the 21-45d band
        "spread_score": s.spread_score,        # 10 — bid/ask width vs mid
        "iv_score": s.iv_score,                # 20 — IV percentile when available
        "liquidity_score": s.liquidity_score,  # 15 — volume and open interest
        "moneyness_score": s.moneyness_score,  # 15 — distance from the money
        # Multiplicative regime adjustments (1.0 when iv_analysis is absent).
        # They can only ever penalize or mildly reward, never rescue a bad base.
        "gex_multiplier": s.gex_multiplier,       # gamma-exposure regime
        "vanna_multiplier": s.vanna_multiplier,   # vanna-regime
        "regime_multiplier": s.regime_multiplier, # the product of the two
        # Hard veto: set when the regime makes this contract structurally
        # unattractive regardless of its mechanical quality.
        "regime_fail": s.regime_fail,
        "ivp_used": s.ivp_used,   # False => iv_score fell back to a raw-IV heuristic
        "flags": s.flags,         # human-readable notes, e.g. "DTE < 7 — pin risk"
    }


@router.post("/score")
def score_contract(req: ScoreRequest):
    """Score one contract.

    No normalization needed — the caller hands over a single Schwab contract
    dict directly rather than a chain.

    A contract with zero bid AND zero ask short-circuits to total=0 with an
    "illiquid" flag rather than erroring: no market means no score is possible.
    """
    s = score(req.contract, req.underlying_price, req.iv_analysis)
    return _score_to_dict(s)


@router.post("/rank")
def rank_chain(req: RankRequest):
    """Score every contract in a chain and return the best `top_n`.

    Scores BOTH calls and puts — unlike /decision/rank-all, which filters to
    one side based on the requested direction. That is the point: contract
    quality is direction-agnostic, so a put can outrank a call here purely on
    liquidity and structure.

    normalize_chain() flattens Schwab's nested callExpDateMap/putExpDateMap into
    a flat expirations list. It is idempotent, so passing an already-normalized
    chain is free. It defaults to include_zero_dte=False, so same-day expiries
    are excluded from the ranking entirely.

    Contracts with no market at all (bid and ask both zero) are skipped rather
    than scored-and-ranked-last, keeping them out of the response completely.
    Note the check is AND: a one-sided market (bid 0, ask > 0) still gets
    scored, and the spread component penalizes it heavily.
    """
    chain = normalize_chain(req.chain)
    results = []
    for exp in chain.get("expirations", []):
        for c in list(exp.get("calls", [])) + list(exp.get("puts", [])):
            if float(c.get("bid", 0)) == 0 and float(c.get("ask", 0)) == 0:
                continue
            s = score(c, req.underlying_price, req.iv_analysis)
            results.append({"contract": c.get("symbol", ""), "score": _score_to_dict(s)})

    # Descending by total via negation. Ties keep chain order (Python's sort is
    # stable), which means calls before puts and nearer expiries first.
    results.sort(key=lambda r: -r["score"]["total"])
    return results[: req.top_n]
