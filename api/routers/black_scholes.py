
# =============================================================================
# routers/black_scholes.py  —  mounted at /bs
# =============================================================================
# The raw Black-Scholes math surface exposed to the Flutter client. Three
# endpoints, all stateless (no DB, no cache): price, Greeks, and the inverse
# problem (implied vol from an observed price).
#
#   POST /bs/price   spot,strike,dte,iv  -> theoretical price
#   POST /bs/greeks  spot,strike,dte,iv  -> all 8 Greeks
#   POST /bs/iv      market_price,...    -> the σ that reproduces that price
#
# Client counterpart: lib/services/python_api/python_api_client.dart
# Math implementation: api/services/black_scholes.py
#
# SHARED CONVENTIONS (all three endpoints)
# ----------------------------------------
# Spot -> forward. The service layer works in the FORWARD form (Black-76),
# so every endpoint converts first:
#     T = days_to_expiry / 365          F = spot * exp(r * T)
# and the service discounts by exp(-r*T) internally. Callers send spot, which
# is what a UI actually has; F is echoed back in the response so the client can
# show the forward it was priced against.
#
# Day count is ACT/365 on CALENDAR days, not trading days. This is deliberate
# and must stay consistent with services/black_scholes.py, which divides theta
# and charm by 365 to report them per calendar day. Switching either side to a
# 252-day basis without the other silently rescales decay by ~1.45x.
#
# NO DIVIDEND YIELD. The forward is built with a pure carry term, q = 0. For a
# dividend payer the forward is therefore overstated by roughly the dividend
# over the option's life, which biases call values up and put values down. Fine
# for the mostly non-dividend-paying tech names this app tracks; a caveat worth
# remembering elsewhere.
#
# The `r` override. Every request takes an optional `r`. When omitted the
# rate is term-matched from the live FRED cache via get_rate_for_dte(), which
# picks a tenor bracket from the DTE (30d SOFR / 3m / 6m / 1y bill). Passing
# `r` explicitly is the way to reproduce a historical valuation, or to match a
# broker's quoted rate. Note get_rate_for_dte returns (rate, label) and these
# endpoints keep only [0], discarding the label.
# =============================================================================

import math
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from services.black_scholes import bs_price, bs_all_greeks, bs_implied_vol
from services.rate_service import get_rate_for_dte

router = APIRouter()


# ── Request / response models ────────────────────────────────────────────────
# Field(...) marks a value as REQUIRED; the gt/ge constraints are enforced by
# Pydantic before the handler body runs, so FastAPI returns a 422 with a field
# path for bad input and the math below never sees a zero strike or negative
# vol. That is the only input validation these handlers get — keep the
# constraints here rather than re-checking inside the handler.

class BSPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price")
    strike: float = Field(..., gt=0, description="Strike price")
    # ge=1 rules out same-day expiry: at T=0 the pricing formula degenerates
    # (division by σ√T) and only intrinsic value is meaningful.
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    # DECIMAL, not percent. 21% vol is 0.21. Sending 21 here produces a
    # 2100%-vol price, which is a silently plausible-looking number.
    implied_vol: float = Field(..., gt=0, description="IV as decimal (e.g. 0.21)")
    is_call: bool = True
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")


class BSPriceResponse(BaseModel):
    price: float
    forward: float   # echoed so the client can show what F the price assumed


class BSGreeksResponse(BaseModel):
    # First-order: sensitivity to spot, spot-convexity, time, vol, rate.
    delta: float
    gamma: float
    theta: float     # per CALENDAR day, already divided by 365
    vega: float      # per 1.00 of vol (i.e. per 100 vol points), not per point
    rho: float
    # Second-order (cross-)Greeks — the ones that matter for managing a
    # position as the surface moves rather than just as spot moves.
    vanna: float     # ∂delta/∂vol  — how delta drifts when IV moves
    charm: float     # ∂delta/∂time — delta decay, per calendar day
    vomma: float     # ∂vega/∂vol   — vega convexity


class BSIVRequest(BaseModel):
    market_price: float = Field(..., gt=0, description="Observed market price of the option")
    spot: float = Field(..., gt=0, description="Underlying price")
    strike: float = Field(..., gt=0, description="Strike price")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    is_call: bool = True
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")
    # Newton-Raphson seed. 0.25 suits typical equity vol; for a name running
    # 90-110% IV a closer guess converges in fewer iterations, though the
    # brentq fallback in the solver makes a poor guess non-fatal.
    initial_guess: float = Field(default=0.25, gt=0, description="Starting IV guess (decimal)")


class BSIVResponse(BaseModel):
    implied_vol: float       # decimal, e.g. 0.4213
    implied_vol_pct: float   # same number as a percent, purely for display
    # Round-trip check: bs_price() re-evaluated at the solved σ. It should
    # match market_price to within the solver's 1e-7 tolerance — a visible gap
    # means the solver stopped early and the result should not be trusted.
    price_check: float
    forward: float
    # Greeks evaluated AT the solved vol, so one call gets both the IV and the
    # risk profile that IV implies. Saves the client a second round trip.
    delta: float
    gamma: float
    theta: float
    vega: float
    rho: float
    vanna: float
    charm: float
    vomma: float


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/price", response_model=BSPriceResponse)
def bs_price_endpoint(req: BSPriceRequest):
    """Theoretical Black-Scholes value for a single European option.

    Straight forward-conversion then price. Returns F alongside the price so
    the caller can see the carry assumption baked into the number.
    """
    r = req.r if req.r is not None else get_rate_for_dte(req.days_to_expiry)[0]
    T = req.days_to_expiry / 365.0
    F = req.spot * math.exp(r * T)
    price = bs_price(F, req.strike, T, r, req.implied_vol, req.is_call)
    return BSPriceResponse(price=price, forward=F)


@router.post("/greeks", response_model=BSGreeksResponse)
def bs_greeks_endpoint(req: BSPriceRequest):
    """All eight Greeks at a GIVEN vol.

    Reuses BSPriceRequest, so `implied_vol` is required here too — this
    endpoint does not solve for vol, it takes the vol you hand it. Use /bs/iv
    when you have a market price instead, which returns the same Greeks
    evaluated at the solved σ.

    bs_all_greeks() computes them in a single pass rather than calling the
    eight individual functions, sharing d1/d2 and the normal pdf/cdf
    evaluations across all of them.
    """
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
    """Invert Black-Scholes: find the σ that reproduces an observed price.

    There is no closed form, so the service runs Newton-Raphson seeded at
    `initial_guess` and falls back to bracketed brentq over [1e-6, 20.0] if
    Newton stalls (which happens when vega collapses deep ITM/OTM, where the
    price is nearly insensitive to vol).

    Returns 422, not 500, when the solver returns None. That is a statement
    about the INPUT, not a server fault: the solver pre-checks no-arbitrage
    bounds and gives up when market_price sits at or below intrinsic, or at or
    above the discounted forward. No real σ exists in that region, so the
    honest answer is "your price is unquotable" — usually a stale quote, a
    crossed book, or a mismatched spot/strike pairing.
    """
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
    # Re-price at the solved vol so the client can verify the round trip, and
    # take the Greeks at that same vol in the same request.
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
