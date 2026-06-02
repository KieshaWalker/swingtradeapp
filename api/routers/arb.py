import statistics
from typing import Optional
from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.arb_checker import check
from services.rate_service import get_rate_for_dte

router = APIRouter()


class ArbCheckRequest(BaseModel):
    points: list[dict]   # [{strike, dte, callIv?, putIv?}]
    spot_price: float = Field(..., gt=0)
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")


@router.post("/check")
def arb_check(req: ArbCheckRequest):
    if req.r is not None:
        r = req.r
    else:
        dtes = [p["dte"] for p in req.points if "dte" in p]
        median_dte = int(statistics.median(dtes)) if dtes else 30
        r = get_rate_for_dte(median_dte)[0]
    result = check(req.points, req.spot_price, r)
    return {
        "is_arbitrage_free": result.is_arbitrage_free,
        "total_violations": result.total_violations,
        "summary": result.summary,
        "worst_calendar_violation": result.worst_calendar_violation,
        "worst_butterfly_violation": result.worst_butterfly_violation,
        "calendar_violations": [
            {
                "strike": v.strike, "near_dte": v.near_dte, "far_dte": v.far_dte,
                "near_total_var": v.near_total_var, "far_total_var": v.far_total_var,
                "violation": v.violation,
            }
            for v in result.calendar_violations
        ],
        "butterfly_violations": [
            {"dte": v.dte, "strike": v.strike, "convexity_value": v.convexity_value}
            for v in result.butterfly_violations
        ],
    }
