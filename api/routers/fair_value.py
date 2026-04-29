from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R
from core.supabase_client import get_supabase
from services.fair_value_engine import compute
from services.heston import HestonParams

router = APIRouter()


class FairValueRequest(BaseModel):
    spot: float = Field(..., gt=0)
    strike: float = Field(..., gt=0)
    implied_vol: float = Field(..., gt=0, description="IV as decimal (e.g. 0.21)")
    days_to_expiry: int = Field(..., ge=1)
    is_call: bool = True
    broker_mid: float = Field(..., ge=0)
    r: float = DEFAULT_R
    calibrated_rho: float | None = None
    calibrated_nu: float | None = None
    ticker: str | None = None   # when provided, Heston params are fetched from DB


class FairValueResponse(BaseModel):
    bs_fair_value: float
    sabr_fair_value: float
    model_fair_value: float
    broker_mid: float
    edge_bps: float
    sabr_vol: float
    implied_vol: float
    vanna: float | None
    charm: float | None
    volga: float | None
    heston_fair_value: float | None = None
    heston_rmse: float | None = None


def _fetch_heston_params(ticker: str) -> tuple[HestonParams, float] | None:
    """Return (HestonParams, rmse_iv) from the most recent reliable calibration, or None."""
    db = get_supabase()
    resp = (
        db.table("heston_calibrations")
        .select("kappa,theta,xi,rho,v0,rmse_iv,n_points,converged")
        .eq("ticker", ticker)
        .order("obs_date", desc=True)
        .order("id", desc=True)
        .limit(1)
        .execute()
    )
    rows = resp.data or []
    if not rows:
        return None
    r = rows[0]
    # Only use calibrations with < 2 vol-point RMSE and at least 8 quotes
    if r["rmse_iv"] is None or r["rmse_iv"] >= 0.02 or (r["n_points"] or 0) < 8:
        return None
    params = HestonParams(
        kappa=r["kappa"],
        theta=r["theta"],
        xi=r["xi"],
        rho=r["rho"],
        V0=r["v0"],
    )
    return params, float(r["rmse_iv"])


@router.post("/compute", response_model=FairValueResponse)
def fair_value_compute(req: FairValueRequest):
    heston_params: HestonParams | None = None
    heston_rmse: float | None = None
    if req.ticker:
        fetched = _fetch_heston_params(req.ticker)
        if fetched is not None:
            heston_params, heston_rmse = fetched

    result = compute(
        spot=req.spot,
        strike=req.strike,
        implied_vol=req.implied_vol,
        days_to_expiry=req.days_to_expiry,
        is_call=req.is_call,
        broker_mid=req.broker_mid,
        r=req.r,
        calibrated_rho=req.calibrated_rho,
        calibrated_nu=req.calibrated_nu,
        heston_params=heston_params,
    )
    return FairValueResponse(
        bs_fair_value=result.bs_fair_value,
        sabr_fair_value=result.sabr_fair_value,
        model_fair_value=result.model_fair_value,
        broker_mid=result.broker_mid,
        edge_bps=result.edge_bps,
        sabr_vol=result.sabr_vol,
        implied_vol=result.implied_vol,
        vanna=result.vanna,
        charm=result.charm,
        volga=result.volga,
        heston_fair_value=result.heston_fair_value,
        heston_rmse=heston_rmse,
    )
