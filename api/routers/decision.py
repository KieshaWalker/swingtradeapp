from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.option_decision import analyze, rank_all, TradeDirection, Recommendation

router = APIRouter()


class DecisionRequest(BaseModel):
    contract: dict
    underlying_price: float = Field(..., gt=0)
    direction: TradeDirection = TradeDirection.bullish
    price_target: float = Field(..., gt=0)
    max_budget: float = Field(..., gt=0)
    contracts: int = 1
    days_to_target: int = 0
    iv_analysis: dict | None = None


class RankAllRequest(BaseModel):
    chain: dict
    direction: TradeDirection = TradeDirection.bullish
    price_target: float = Field(..., gt=0)
    max_budget: float = Field(..., gt=0)
    contracts: int = 1
    days_to_target: int = 0
    iv_analysis: dict | None = None
    top_n: int = 5


def _result_to_dict(r) -> dict:
    return {
        "symbol": r.contract.get("symbol", ""),
        "score": {
            "total": r.score.total,
            "grade": r.score.grade,
            "regime_fail": r.score.regime_fail,
            "flags": r.score.flags,
        },
        "entry_cost": r.entry_cost,
        "contracts_affordable": r.contracts_affordable,
        "estimated_pnl": r.estimated_pnl,
        "estimated_return": r.estimated_return,
        "break_even_price": r.break_even_price,
        "break_even_move_pct": r.break_even_move_pct,
        "daily_theta_drag": r.daily_theta_drag,
        "total_theta_drag": r.total_theta_drag,
        "theta_decay_to_target": r.theta_decay_to_target,
        "max_loss": r.max_loss,
        "risk_reward_ratio": r.risk_reward_ratio,
        "pricing_edge": r.pricing_edge,
        "is_cheap": r.is_cheap,
        "vol_oi_ratio": r.vol_oi_ratio,
        "unusual_activity": r.unusual_activity,
        "vega_dollar_per_1pct_iv": r.vega_dollar_per_1pct_iv,
        "high_gamma_risk": r.high_gamma_risk,
        "recommendation": r.recommendation.value,
        "reasons": r.reasons,
        "warnings": r.warnings,
    }


@router.post("/analyze")
def decision_analyze(req: DecisionRequest):
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
