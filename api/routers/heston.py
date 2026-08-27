# =============================================================================
# routers/heston.py  —  mounted at /heston
# =============================================================================
# Heston (1993) stochastic-volatility endpoints.
#
#   POST /heston/price            price one option from given (κ,θ,ξ,ρ,V₀)
#   POST /heston/estimate-params  estimate P-measure params from price history
#
# Pricer:    api/services/heston.py           (Gil-Pelaez Fourier inversion)
# Estimator: api/services/kappa_estimator.py  (AR(1) on realized variance)
# Fitter:    api/services/heston_calibrator.py (surface fit — NOT this router;
#            that runs as the heston_pull job)
#
# WHY HESTON ON TOP OF BLACK-SCHOLES
# ----------------------------------
# Black-Scholes assumes vol is a constant. Heston makes variance itself a
# mean-reverting random process correlated with spot:
#
#     dS/S = r dt + √V dW₁
#     dV   = κ(θ − V) dt + ξ√V dW₂,     Corr(dW₁, dW₂) = ρ
#
#     κ  speed of mean reversion   (how fast vol snaps back)
#     θ  long-run variance         (where it snaps back TO; long-run vol = √θ)
#     ξ  vol-of-vol                (how violently it moves — creates SMILE)
#     ρ  spot/vol correlation      (negative for equities — creates SKEW)
#     V₀ current variance          (where vol is right now; vol = √V₀)
#
# One parameter set therefore prices EVERY strike and expiry at once, and
# produces skew and smile endogenously rather than needing a separate σ per
# strike. That is what makes it useful for spotting a contract mispriced
# relative to the whole surface rather than to its immediate neighbours.
#
# THE P/Q DISTINCTION — the most important thing in this file
# ----------------------------------------------------------
# The same five parameters can be obtained two entirely different ways, and
# they are NOT interchangeable:
#
#   Q-measure (risk-neutral) — fit to today's OPTION PRICES. This is what the
#     heston_pull job stores in heston_calibrations, and the only correct
#     input to /heston/price, because pricing must reproduce market prices.
#
#   P-measure (physical/historical) — estimated from the stock's REALIZED
#     price history, as /heston/estimate-params does. This is what volatility
#     has actually DONE.
#
# They differ systematically, not randomly: options embed a variance risk
# premium (people pay up for vol protection), so calibrated Q-measure κ and ξ
# are typically LARGER than their historical counterparts. The gap is the
# premium itself. /heston/estimate-params returns both — its own P estimate
# plus the latest stored Q calibration — specifically so that gap is visible
# rather than accidentally conflated.
#
# Feller condition (2κθ ≥ ξ²) is reported by both endpoints. When it fails,
# the variance process can touch zero, and both the pricer's numerics and the
# parameters' interpretability degrade — a fitted set that violates it is
# usable but should be treated with suspicion.
# =============================================================================

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

# Whitelist for anything interpolated into an outbound request or a DB filter.
# Permissive enough for share classes and pairs (BRK.B, RDS-A) but no
# whitespace, quotes or separators.
_TICKER_RE = re.compile(r"^[A-Za-z0-9.\-/]{1,10}$")


class HestonPriceRequest(BaseModel):
    spot: float = Field(..., gt=0, description="Underlying price S")
    strike: float = Field(..., gt=0, description="Strike price K")
    days_to_expiry: int = Field(..., ge=1, description="Calendar days to expiry")
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")
    is_call: bool = True
    # All five are REQUIRED — there is no sensible default parameter set, since
    # they are ticker- and date-specific. Get them from heston_calibrations
    # (Q-measure) rather than from /heston/estimate-params (P-measure).
    # NOTE these are VARIANCES, not vols: theta=0.09 means 30% long-run vol.
    kappa: float = Field(..., gt=0, description="Mean-reversion speed κ")
    theta: float = Field(..., gt=0, description="Long-run variance θ (long-run vol = √θ)")
    xi: float = Field(..., gt=0, description="Vol-of-vol ξ")
    rho: float = Field(..., description="Spot-vol correlation ρ ∈ (−1, 1)")
    v0: float = Field(..., gt=0, description="Initial variance V₀ (initial vol = √V₀)")


class HestonPriceResponse(BaseModel):
    price: float
    forward: float
    # Variances converted to vols for display — the units traders actually read.
    initial_vol: float     # √V₀ — where vol is now
    long_run_vol: float    # √θ  — where it reverts to
    feller_satisfied: bool  # 2κθ ≥ ξ²; see header


@router.post("/price", response_model=HestonPriceResponse)
def heston_price_endpoint(req: HestonPriceRequest):
    """Price one European option under Heston.

    Same spot→forward convention and ACT/365 day count as /bs, so a Heston
    price and a Black-Scholes price are directly comparable — which is the
    usual reason to call this: the difference is the value of the smile/skew
    that Black-Scholes cannot see.

    Parameter validation happens inside HestonParams.__post_init__ (κ,θ,ξ,V₀ > 0
    and ρ strictly inside (−1,1)), which raises ValueError and surfaces as a 500
    via main.py's global handler. Pydantic's gt=0 constraints catch most of it
    first; ρ's range is the one only HestonParams enforces.
    """
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
    # Uses the accurate scipy.quad pricer (~5ms), not the fast Gauss-Laguerre
    # variant — a single interactive price can afford the precision, whereas
    # the calibrator, which prices thousands of options per fit, cannot.
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
    # 1095 days ≈ 3 years. The lower bound of 365 is not arbitrary: κ is
    # estimated from how autocovariance of variance DECAYS with lag, and a
    # short sample cannot resolve the decay of a slowly mean-reverting process.
    lookback_days: int = Field(default=1095, ge=365, le=3650,
                               description="Calendar days of price history")
    # Realized variance is measured over NON-OVERLAPPING blocks of this many
    # trading days. Non-overlapping matters enormously — rolling windows share
    # returns, which inflates the autocorrelation and collapses the κ estimate.
    # Larger blocks mean less measurement noise per block but fewer blocks; 5
    # (one trading week) is the compromise. The estimator needs ≥ 40 blocks.
    block_days: int = Field(default=5, ge=1, le=21,
                            description="Trading days per non-overlapping RV block")

    @field_validator("ticker")
    @classmethod
    def validate_ticker(cls, v: str) -> str:
        """Normalize to upper case and reject anything not matching _TICKER_RE.

        Runs before the handler, so the value interpolated into the edge-function
        payload and the Supabase filter below is always known-safe.
        """
        v = v.strip().upper()
        if not _TICKER_RE.match(v):
            raise ValueError(f"Invalid ticker format: {v!r}")
        return v


class EstimateParamsResponse(BaseModel):
    ticker: str
    # ── P-measure estimates ──────────────────────────────────────────────────
    kappa: float
    theta: float                    # long-run variance
    xi: float
    v0: float                       # current variance
    long_run_vol: float             # √θ
    current_vol: float              # √v₀
    # ln(2)/κ in calendar days — the intuitive reading of κ: how long a vol
    # shock takes to half-decay. A 30-day half-life is a fast-reverting name.
    half_life_days: float
    feller_satisfied: bool
    # ── Fit diagnostics ──────────────────────────────────────────────────────
    ar1_b: float     # persistence per block; κ = −ln(b)/Δt, so b→1 means κ→0
    # Lag-1 r² of the block variance series. A SIGNAL-TO-NOISE diagnostic only
    # — deliberately not the basis for b, because RV measurement error
    # attenuates an OLS slope and would inflate κ by an order of magnitude.
    ar1_r2: float
    n_blocks: int    # ≥ 40 enforced by the estimator
    block_days: int
    # ── Q-measure comparison (may be absent) ─────────────────────────────────
    # The latest stored surface calibration, for the P-vs-Q gap described in the
    # header. None when this ticker has never been calibrated.
    calibrated_kappa: Optional[float] = None   # latest surface calibration (Q-measure)
    calibrated_rmse_iv: Optional[float] = None  # fit quality; < 0.02 is reliable
    calibrated_obs_date: Optional[str] = None   # may be stale — check the date
    note: str


def _latest_calibration(ticker: str) -> Optional[dict]:
    """Most recent Q-measure calibration for this ticker, or None.

    The secondary sort on id descending breaks ties when a ticker was
    calibrated more than once on the same obs_date (a re-run, or a backfill
    overlapping live data) — without it the row returned would be arbitrary.
    """
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
    """Estimate κ, θ, ξ, v₀ from daily price history via AR(1) on realized variance.

    Pipeline:
      1. Pull daily closes from Schwab through the Supabase edge function.
      2. Chop log returns into non-overlapping block_days blocks and compute
         annualized realized variance per block.
      3. Fit the decay of that series' autocovariance across lags to get the
         per-block persistence b, then κ = −ln(b)/Δt.
      4. Derive θ from the mean, ξ from the CIR stationary-variance relation,
         and v₀ from the last ~21 daily returns.
      5. Attach the latest stored Q-measure calibration for comparison.

    Price history is fetched via the edge function rather than Schwab directly
    because the OAuth token lives there — this service holds no broker
    credentials, only the Supabase service key.

    Status codes are deliberately distinct so the client can tell the failures
    apart:
      502  upstream price fetch failed          — retry may help
      404  ticker returned no usable closes     — bad symbol or no coverage
      422  data fetched but cannot support a fit — the estimator's own
           diagnosis is passed through verbatim (too few blocks, flat variance,
           insignificant lag-1 autocorrelation, or non-decaying autocovariance).
           A 422 here is usually a genuine finding about the name: a stock whose
           vol shows no mean reversion over the window has no meaningful κ, and
           inventing one would be worse than refusing.
    """
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=req.lookback_days)
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={
                "symbol": req.ticker,
                # Schwab's API takes epoch MILLISECONDS, hence the x1000.
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
    # Filter falsy AND non-positive closes: a zero or null slips through gapped
    # data and would blow up the log-return computation downstream.
    closes = [c for c in resp.json().get("closes", []) if c and c > 0]
    if len(closes) < 2:
        raise HTTPException(
            status_code=404,
            detail=f"No price history found for {req.ticker}.",
        )

    # EstimationError carries a human-readable reason; surface it as 422 rather
    # than letting it become an opaque 500. See the docstring above.
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
        # Shipped in the response body so the P/Q caveat travels with the
        # numbers, wherever they end up displayed.
        note=(
            "Historical (P-measure) estimate from AR(1) on non-overlapping "
            f"{est.block_days}-day realized variance. Calibrated risk-neutral "
            "κ and ξ are typically larger due to variance risk premia."
        ),
    )
