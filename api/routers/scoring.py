from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.chain_utils import normalize_chain
from services.option_scoring import score

router = APIRouter()


class ScoreRequest(BaseModel):
    contract: dict        # Schwab option contract dict (IV in percent)
    underlying_price: float = Field(..., gt=0)
    iv_analysis: dict | None = None


class RankRequest(BaseModel):
    chain: dict
    underlying_price: float = Field(..., gt=0)
    iv_analysis: dict | None = None
    top_n: int = 10


def _score_to_dict(s) -> dict:
    return {
        "total": s.total,
        "base_score": s.base_score,
        "grade": s.grade,
        "delta_score": s.delta_score,
        "dte_score": s.dte_score,
        "spread_score": s.spread_score,
        "iv_score": s.iv_score,
        "liquidity_score": s.liquidity_score,
        "moneyness_score": s.moneyness_score,
        "gex_multiplier": s.gex_multiplier,
        "vanna_multiplier": s.vanna_multiplier,
        "regime_multiplier": s.regime_multiplier,
        "regime_fail": s.regime_fail,
        "ivp_used": s.ivp_used,
        "flags": s.flags,
    }


@router.post("/score")
def score_contract(req: ScoreRequest):
    s = score(req.contract, req.underlying_price, req.iv_analysis)
    return _score_to_dict(s)


@router.post("/rank")
def rank_chain(req: RankRequest):
    chain = normalize_chain(req.chain)
    results = []
    for exp in chain.get("expirations", []):
        for c in list(exp.get("calls", [])) + list(exp.get("puts", [])):
            if float(c.get("bid", 0)) == 0 and float(c.get("ask", 0)) == 0:
                continue
            s = score(c, req.underlying_price, req.iv_analysis)
            results.append({"contract": c.get("symbol", ""), "score": _score_to_dict(s)})

    results.sort(key=lambda r: -r["score"]["total"])
    return results[: req.top_n]
