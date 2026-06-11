import math
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, field_validator

from core.config import settings
from core.supabase_client import get_supabase
from services.heston import HestonParams, heston_price
from services.kappa_estimator import EstimationError, estimate_from_closes
from services.rate_service import get_rate_for_dte

router = APIRouter()

_TICKER_RE = re.compile(r"^[A-Za-z0-9.\-/]{1,10}$")


class HestonPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price S")
    strike: float = Field(..., gt=0, description="Strike price K")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")
    is_call: bool = True
    kappa: float = Field(..., gt=0, description="Mean-reversion speed κ")
    theta: float = Field(..., gt=0, description="Long-run variance θ (long-run vol = √θ)")
    xi: float = Field(..., gt=0, description="Vol-of-vol ξ")
    rho: float = Field(..., description="Spot-vol correlation ρ ∈ (−1, 1)")
    v0: float = Field(..., gt=0, description="Initial variance V₀ (initial vol = √V₀)")


class HestonPriceResponse(BaseModel):
    price: float
    forward: float
    initial_vol: float
    long_run_vol: float
    feller_satisfied: bool


@router.post("/price", response_model=HestonPriceResponse)
def heston_price_endpoint(req: HestonPriceRequest):
    r = req.r if req.r is not None else get_rate_for_dte(req.days_to_expiry)[0]
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(r * T)
    params = HestonParams(
        kappa=req.kappa,
        theta=req.theta,
        xi=req.xi,
        rho=req.rho,
        V0=req.v0,
    )
    price = heston_price(F=F, K=req.strike, T=T, r=r, params=params, is_call=req.is_call)
    return HestonPriceResponse(
        price=price,
        forward=F,
        initial_vol=math.sqrt(req.v0),
        long_run_vol=math.sqrt(req.theta),
        feller_satisfied=params.feller_satisfied,
    )


# ── Historical (P-measure) parameter estimation ───────────────────────────────

class EstimateParamsRequest(BaseModel):
    ticker: str
    lookback_days: int = Field(default=1095, ge=365, le=3650,
                               description="Calendar days of price history")
    block_days: int = Field(default=5, ge=1, le=21,
                            description="Trading days per non-overlapping RV block")

    @field_validator("ticker")
    @classmethod
    def validate_ticker(cls, v: str) -> str:
        v = v.strip().upper()
        if not _TICKER_RE.match(v):
            raise ValueError(f"Invalid ticker format: {v!r}")
        return v


class EstimateParamsResponse(BaseModel):
    ticker: str
    kappa: float
    theta: float                    # long-run variance
    xi: float
    v0: float                       # current variance
    long_run_vol: float             # √θ
    current_vol: float              # √v₀
    half_life_days: float
    feller_satisfied: bool
    ar1_b: float
    ar1_r2: float
    n_blocks: int
    block_days: int
    calibrated_kappa: Optional[float] = None   # latest surface calibration (Q-measure)
    calibrated_rmse_iv: Optional[float] = None
    calibrated_obs_date: Optional[str] = None
    note: str


def _latest_calibration(ticker: str) -> Optional[dict]:
    rows = (
        get_supabase()
        .table("heston_calibrations")
        .select("kappa,rmse_iv,obs_date")
        .eq("ticker", ticker)
        .order("obs_date", desc=True)
        .order("id", desc=True)
        .limit(1)
        .execute()
    ).data or []
    return rows[0] if rows else None


@router.post("/estimate-params", response_model=EstimateParamsResponse)
async def heston_estimate_params(req: EstimateParamsRequest):
    """Estimate κ, θ, ξ, v₀ from daily price history via AR(1) on realized variance."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=req.lookback_days)
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={
                "symbol": req.ticker,
                "startDate": int(start.timestamp() * 1000),
                "endDate": int(end.timestamp() * 1000),
            },
            headers={
                "Authorization": f"Bearer {settings.supabase_service_key}",
                "Content-Type": "application/json",
            },
            timeout=30.0,
        )
    if resp.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail=f"Price history fetch failed for {req.ticker} "
                   f"(status {resp.status_code}).",
        )
    closes = [c for c in resp.json().get("closes", []) if c and c > 0]
    if len(closes) < 2:
        raise HTTPException(
            status_code=404,
            detail=f"No price history found for {req.ticker}.",
        )

    try:
        est = estimate_from_closes(closes, block_days=req.block_days)
    except EstimationError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    cal = _latest_calibration(req.ticker)
    return EstimateParamsResponse(
        ticker=req.ticker,
        kappa=est.kappa,
        theta=est.theta,
        xi=est.xi,
        v0=est.v0,
        long_run_vol=math.sqrt(est.theta),
        current_vol=math.sqrt(est.v0),
        half_life_days=est.half_life_days,
        feller_satisfied=est.feller_satisfied,
        ar1_b=est.ar1_b,
        ar1_r2=est.ar1_r2,
        n_blocks=est.n_blocks,
        block_days=est.block_days,
        calibrated_kappa=cal["kappa"] if cal else None,
        calibrated_rmse_iv=cal.get("rmse_iv") if cal else None,
        calibrated_obs_date=cal.get("obs_date") if cal else None,
        note=(
            "Historical (P-measure) estimate from AR(1) on non-overlapping "
            f"{est.block_days}-day realized variance. Calibrated risk-neutral "
            "κ and ξ are typically larger due to variance risk premia."
        ),
    )
