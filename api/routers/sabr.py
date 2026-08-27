from __future__ import annotations

# =============================================================================
# routers/sabr.py  —  mounted at /sabr
# =============================================================================
# SABR stochastic-volatility surface endpoints.
#
#   POST /sabr/iv         evaluate the Hagan closed form at one strike
#   POST /sabr/calibrate  fit (α, ρ, ν) per DTE slice to a whole snapshot
#
# Math:        api/services/sabr.py            (Hagan 2002 approximation)
# Calibration: api/services/sabr_calibrator.py (Nelder-Mead, per-DTE slices)
# Client:      lib/services/python_api/python_api_client.dart
#
# WHAT SABR IS FOR HERE
# ---------------------
# Black-Scholes needs one σ per strike; the market quotes a different σ at
# every strike (the smile/skew). SABR is a four-parameter model of that whole
# curve, so a fitted slice can interpolate an IV at a strike that has no quote,
# and extrapolate sanely into the wings where quotes are wide or absent.
#
#   α (alpha)  overall vol level — sets the height of the smile
#   β (beta)   CEV exponent, FIXED at 0.5 here (see below)
#   ρ (rho)    spot/vol correlation — sets the SKEW (tilt); negative for
#              equities, where vol rises as price falls
#   ν (nu)     vol-of-vol — sets the CURVATURE (smile depth)
#
# β is not fitted. It is pinned at SABR_BETA = 0.5 because β and ρ are nearly
# indistinguishable from a single smile — they trade off against each other and
# fitting both makes the optimizer wander along a flat valley. Fixing β at the
# square-root-CEV value is the standard equity convention and leaves three
# well-identified parameters.
#
# UNITS: every vol in and out of this router is a DECIMAL (0.42 = 42%), unlike
# the raw Schwab chain fields elsewhere in the codebase which are percent.
# =============================================================================

import statistics
from typing import Optional
from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import SABR_BETA
from services.sabr import sabr_iv, sabr_alpha
from services.sabr_calibrator import calibrate_snapshot, SabrSlice
from services.rate_service import get_rate_for_dte

router = APIRouter()


class SabrIvRequest(BaseModel):
    # Note this takes F (the FORWARD) directly, not spot — unlike /bs, which
    # takes spot and converts. Callers evaluating a fitted slice already have
    # the forward that slice was calibrated against, so asking for it avoids a
    # second, possibly inconsistent, carry assumption.
    F: float = Field(..., gt=0, description="Forward price")
    strike: float = Field(..., gt=0)
    # Years, not days — again unlike /bs. Matches the service signature.
    T: float = Field(..., gt=0, description="Time to expiry in years")
    alpha: float = Field(..., gt=0)
    beta: float = SABR_BETA          # defaulted, not validated: see header
    rho: float = Field(default=-0.7)  # equity default: strong negative skew
    nu: float = Field(default=0.40, gt=0)


class SabrIvResponse(BaseModel):
    sabr_vol: float   # decimal


class SabrPoint(BaseModel):
    """One (strike, DTE) node of a vol surface snapshot.

    Both IVs are optional because a snapshot row typically carries a usable
    quote on only one side. The calibrator's _select_iv() applies the OTM
    convention — call IV at or above the forward, put IV below — and falls back
    to whichever side is present. That convention matters: OTM options are the
    liquid ones, so their IVs are the trustworthy ones.
    """
    strike: float = Field(..., gt=0)
    # le=1095 caps at ~3 years; beyond that the Hagan expansion (an expansion
    # in T) degrades badly and LEAPS quotes are too thin to fit anyway.
    dte: int = Field(..., ge=1, le=1095)
    callIv: Optional[float] = Field(default=None, gt=0)
    putIv: Optional[float] = Field(default=None, gt=0)


class SabrCalibrateRequest(BaseModel):
    ticker: str
    # Accepted and echoed by the caller for bookkeeping, but NOT used by the
    # fit — calibration is a pure function of the points and the spot below.
    obs_date: Optional[str] = None
    spot_price: float = Field(..., gt=0)
    points: list[SabrPoint] = Field(..., min_length=1)
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")


class SabrCalibrateResponse(BaseModel):
    # Deliberately list[dict] rather than a typed model: SabrSlice.to_dict() is
    # the contract, and keeping it loose means adding a diagnostic field to the
    # dataclass does not require editing this router too.
    slices: list[dict]


@router.post("/iv", response_model=SabrIvResponse)
def sabr_iv_endpoint(req: SabrIvRequest):
    """Evaluate the Hagan SABR implied vol at a single strike.

    Pure formula evaluation — no fitting, no data access. Used to draw a fitted
    smile curve across strikes once /sabr/calibrate has produced parameters.

    Returns 0.0 (not an error) for degenerate inputs, matching the service's
    behaviour; a zero here means the parameters were unusable, not that the
    market vol is zero.
    """
    vol = sabr_iv(F=req.F, K=req.strike, T=req.T, alpha=req.alpha,
                  beta=req.beta, rho=req.rho, nu=req.nu)
    return SabrIvResponse(sabr_vol=vol)


@router.post("/calibrate", response_model=SabrCalibrateResponse)
def sabr_calibrate_endpoint(req: SabrCalibrateRequest):
    """Fit SABR to every DTE slice in one vol-surface snapshot.

    Slicing: the points are grouped by DTE and each slice is fitted
    INDEPENDENTLY — there is no term-structure smoothing tying adjacent
    expiries together. That keeps a bad slice local, but it also means
    parameters can jump between neighbouring DTEs; consumers should gate on
    each slice's own rmse/n_points (SabrSlice.is_reliable) rather than assuming
    the surface is coherent across T.

    Slices with too few usable quotes are dropped entirely, so the response can
    contain fewer slices than the request had distinct DTEs.

    RATE HANDLING: one rate is chosen for the WHOLE snapshot from the MEDIAN
    DTE, rather than term-matching each slice. r only enters through the
    forward F = spot·e^{rT}, and the fit is dominated by the shape of the smile
    in strike, so the simplification is cheap. It does mean a snapshot spanning
    7 DTE to 700 DTE prices its long wing off a short rate; pass `r` explicitly
    if that matters.
    """
    if req.r is not None:
        r = req.r
    else:
        median_dte = int(statistics.median(p.dte for p in req.points))
        r = get_rate_for_dte(median_dte)[0]
    # exclude_none drops absent callIv/putIv keys entirely rather than sending
    # them through as None — the calibrator's _select_iv() probes with .get()
    # and treats a missing key and a None value the same, but dropping them
    # keeps the dicts the same shape as the raw Supabase JSONB rows.
    points = [p.model_dump(exclude_none=True) for p in req.points]
    slices = calibrate_snapshot(spot=req.spot_price, points=points, r=r)
    return SabrCalibrateResponse(slices=[s.to_dict() for s in slices])
