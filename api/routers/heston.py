import math
from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R
from services.heston import HestonParams, heston_price

router = APIRouter()


class HestonPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price S")
    strike: float = Field(..., gt=0, description="Strike price K")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    r: float = Field(DEFAULT_R, description="Risk-free rate as decimal")
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
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(req.r * T)
    params = HestonParams(
        kappa=req.kappa,
        theta=req.theta,
        xi=req.xi,
        rho=req.rho,
        V0=req.v0,
    )
    price = heston_price(F=F, K=req.strike, T=T, r=req.r, params=params, is_call=req.is_call)
    return HestonPriceResponse(
        price=price,
        forward=F,
        initial_vol=math.sqrt(req.v0),
        long_run_vol=math.sqrt(req.theta),
        feller_satisfied=params.feller_satisfied,
    )
