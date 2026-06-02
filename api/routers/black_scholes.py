
import math
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from services.black_scholes import bs_price, bs_all_greeks, bs_implied_vol
from services.rate_service import get_rate_for_dte

router = APIRouter()


class BSPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price")
    strike: float = Field(..., gt=0, description="Strike price")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    implied_vol: float = Field(..., gt=0, description="IV as decimal (e.g. 0.21)")
    is_call: bool = True
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")


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


class BSIVRequest(BaseModel):
    market_price: float = Field(..., gt=0, description="Observed market price of the option")
    spot: float = Field(..., gt=0, description="Underlying price")
    strike: float = Field(..., gt=0, description="Strike price")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    is_call: bool = True
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")
    initial_guess: float = Field(default=0.25, gt=0, description="Starting IV guess (decimal)")


class BSIVResponse(BaseModel):
    implied_vol: float
    implied_vol_pct: float
    price_check: float
    forward: float
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
    r = req.r if req.r is not None else get_rate_for_dte(req.days_to_expiry)[0]
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(r * T)
    price = bs_price(F, req.strike, T, r, req.implied_vol, req.is_call)
    return BSPriceResponse(price=price, forward=F)


@router.post("/greeks", response_model=BSGreeksResponse)
def bs_greeks_endpoint(req: BSPriceRequest):
    r = req.r if req.r is not None else get_rate_for_dte(req.days_to_expiry)[0]
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(r * T)
    g = bs_all_greeks(F, req.strike, T, r, req.implied_vol, req.is_call)
    return BSGreeksResponse(
        delta=g.delta, gamma=g.gamma, theta=g.theta, vega=g.vega,
        rho=g.rho, vanna=g.vanna, charm=g.charm, vomma=g.vomma,
    )


@router.post("/iv", response_model=BSIVResponse)
def bs_iv_endpoint(req: BSIVRequest):
    r = req.r if req.r is not None else get_rate_for_dte(req.days_to_expiry)[0]
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(r * T)
    sigma = bs_implied_vol(
        market_price=req.market_price,
        F=F,
        K=req.strike,
        T=T,
        r=r,
        is_call=req.is_call,
        initial_guess=req.initial_guess,
    )
    if sigma is None:
        raise HTTPException(
            status_code=422,
            detail=(
                "Newton-Raphson did not converge. "
                "Check that the market price is within no-arbitrage bounds "
                "(above intrinsic, below discounted forward)."
            ),
        )
    price_check = bs_price(F, req.strike, T, r, sigma, req.is_call)
    g = bs_all_greeks(F, req.strike, T, r, sigma, req.is_call)
    return BSIVResponse(
        implied_vol=sigma,
        implied_vol_pct=sigma * 100,
        price_check=price_check,
        forward=F,
        delta=g.delta,
        gamma=g.gamma,
        theta=g.theta,
        vega=g.vega,
        rho=g.rho,
        vanna=g.vanna,
        charm=g.charm,
        vomma=g.vomma,
    )
