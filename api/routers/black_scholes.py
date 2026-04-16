import math
from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R
from services.black_scholes import bs_price, bs_all_greeks

router = APIRouter()


class BSPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price")
    strike: float = Field(..., gt=0, description="Strike price")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    implied_vol: float = Field(..., gt=0, description="IV as decimal (e.g. 0.21)")
    is_call: bool = True
    r: float = DEFAULT_R


class BSPriceResponse(BaseModel):
    price: float
    forward: float


class BSGreeksResponse(BaseModel):
    delta: float
    gamma: float
    theta: float
    vega: float
    rho: float
    vanna: float
    charm: float
    vomma: float


@router.post("/price", response_model=BSPriceResponse)
def bs_price_endpoint(req: BSPriceRequest):
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(req.r * T)
    price = bs_price(F, req.strike, T, req.r, req.implied_vol, req.is_call)
    return BSPriceResponse(price=price, forward=F)


@router.post("/greeks", response_model=BSGreeksResponse)
def bs_greeks_endpoint(req: BSPriceRequest):
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(req.r * T)
    g = bs_all_greeks(F, req.strike, T, req.r, req.implied_vol, req.is_call)
    return BSGreeksResponse(
        delta=g.delta, gamma=g.gamma, theta=g.theta, vega=g.vega,
        rho=g.rho, vanna=g.vanna, charm=g.charm, vomma=g.vomma,
    )
