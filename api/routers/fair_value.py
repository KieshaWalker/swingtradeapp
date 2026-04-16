from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R
from services.fair_value_engine import compute

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


@router.post("/compute", response_model=FairValueResponse)
def fair_value_compute(req: FairValueRequest):
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
    )
