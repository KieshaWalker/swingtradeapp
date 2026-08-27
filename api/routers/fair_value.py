from __future__ import annotations
from typing import Optional

# =============================================================================
# routers/fair_value.py
# =============================================================================
# Backend route for fair value computations.
# If the API request/response schema changes here, update:
#   lib/services/python_api/python_api_client.dart -> fairValueCompute()
#   lib/services/python_api/python_api_client.dart -> sabrCalibrate()
#
# If ticker is provided, this module reads from Supabase table:
#   heston_calibrations
#
# Referenced by:
#   api/services/fair_value_engine.py
#   api/routers/fair_value.py
#   lib/services/python_api/python_api_client.dart
# =============================================================================
#
# WHAT THIS ANSWERS
# -----------------
# "Is this contract cheap or expensive versus what it SHOULD be worth?" — the
# question /bs and /sabr only give you the ingredients for. One POST returns a
# ladder of increasingly sophisticated model prices plus the edge against the
# broker's mid:
#
#   1. BLACK-SCHOLES at the quoted IV — the baseline.
#   2. SABR — re-prices using a smile-consistent vol at this strike, so a wing
#      option is not valued at an ATM vol.
#   3. HESTON — when a reliable stored calibration exists for the ticker, its
#      price REPLACES the SABR result as model_fair_value.
#
#   edge_bps = (model_fair_value − broker_mid) / broker_mid × 10,000
#   POSITIVE = the model prices it ABOVE the broker's mid = potentially cheap
#   to buy. Same sign convention as contract_opportunity's edge_bps, so the two
#   can be compared directly.
#
# THE TICKER PARAMETER CHANGES THE ANSWER
# ---------------------------------------
# Without `ticker` this is a pure, stateless computation. WITH it, two Supabase
# lookups fire and materially enrich the result:
#   * heston_calibrations -> a real stochastic-vol price instead of SABR
#   * expected_move_snapshots + realized_vol_snapshots -> the term comparison
# Neither is fatal if absent; both simply come back None. So the same request
# is meaningful for an untracked symbol, just less informative.
#
# UNITS: implied_vol in and sabr_vol out are DECIMALS. The term_comparison
# block, by contrast, is in PERCENT — it feeds a display widget directly. That
# inconsistency is deliberate and localized to that one nested dict.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.supabase_client import get_supabase
from services.fair_value_engine import compute
from services.heston import HestonParams

router = APIRouter()


# ── DTE → matched period bucket ───────────────────────────────────────────────

def _dte_bucket(dte: int) -> tuple[str, str, str]:
    """Map DTE to (period_type, rv_column, period_label).

    period_type matches expected_move_snapshots.period_type values.
    rv_column matches realized_vol_snapshots column names.

    The point is TERM MATCHING. Comparing a 5-day option's IV against 60-day
    realized vol is meaningless — vol has a term structure, and the honest
    comparison puts each option next to realized vol measured over a similar
    horizon. Hence three buckets, each pairing an expected-move period with the
    RV column covering roughly the same number of sessions:
        ≤ 7 DTE  -> weekly    / rv_5d   (≈1 trading week)
        ≤ 30 DTE -> monthly   / rv_21d  (≈1 trading month)
        > 30 DTE -> quarterly / rv_63d  (≈1 trading quarter)

    Note the top bucket is open-ended: a 2-year LEAP is compared against 63-day
    realized vol, which is the closest available but a genuinely loose match.
    """
    if dte <= 7:
        return "weekly",    "rv_5d",  "1-week"
    if dte <= 30:
        return "monthly",   "rv_21d", "1-month"
    return     "quarterly", "rv_63d", "3-month"


class FairValueRequest(BaseModel):
    spot: float = Field(..., gt=0)
    strike: float = Field(..., gt=0)
    implied_vol: float = Field(..., gt=0, description="IV as decimal (e.g. 0.21)")
    days_to_expiry: int = Field(..., ge=1, le=1095)
    is_call: bool = True
    # ge=0 (not gt=0) — a genuinely worthless option can quote a zero mid, and
    # rejecting it would be wrong. The engine short-circuits on a zero mid,
    # returning model=mid and edge=0 rather than dividing by zero.
    broker_mid: float = Field(..., ge=0)
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")
    # Surface-calibrated SABR shape parameters, from /sabr/calibrate. Passing
    # them replaces the engine's generic equity defaults (ρ=-0.7, ν=0.40) with
    # this ticker's actual measured skew and smile — the single biggest accuracy
    # improvement available for a wing strike.
    calibrated_rho:Optional[float] = None
    calibrated_nu:Optional[float] = None
    ticker:Optional[str] = None   # when provided, Heston params are fetched from DB


class FairValueResponse(BaseModel):
    # ── The model ladder ─────────────────────────────────────────────────────
    bs_fair_value: float      # baseline at the quoted IV
    sabr_fair_value: float    # smile-adjusted
    # The headline number: Heston when a reliable calibration was found,
    # otherwise the SABR result. Check heston_fair_value for which applied.
    model_fair_value: float
    broker_mid: float         # echoed for a self-contained response
    edge_bps: float           # positive = model above mid; see header
    # ── Vols ─────────────────────────────────────────────────────────────────
    sabr_vol: float           # the smile vol SABR used at this strike
    implied_vol: float        # the quoted IV, echoed back
    # ── Second-order Greeks at the model vol ─────────────────────────────────
    vanna:Optional[float]
    charm:Optional[float]
    volga:Optional[float]
    # ── Heston (None unless a reliable calibration was found) ────────────────
    heston_fair_value:Optional[float] = None
    heston_rmse:Optional[float] = None   # fit quality of the calibration used
    # ── IV consistency check ─────────────────────────────────────────────────
    # Back-solve IV from the broker's own mid and compare it to the IV the
    # broker reported. A large gap means the quoted IV and the quoted price
    # disagree — usually a stale IV field or a wide/crossed market — and is a
    # warning that any edge computed here rests on inconsistent inputs.
    computed_iv:Optional[float] = None      # IV back-solved from broker_mid
    iv_diff_pct:Optional[float] = None      # computed_iv - implied_vol in vol points
    iv_note:Optional[str] = None            # human-readable IV check message
    # ── Rate provenance ──────────────────────────────────────────────────────
    # Which rate was actually used, and which tenor it came from. Exposed so a
    # valuation can be reproduced exactly later by passing `r` back in.
    rate_used: float = 0.0                # risk-free rate used in pricing (decimal)
    rate_tenor: str = ""                  # e.g. "3-month T-bill"
    term_comparison:Optional[dict] = None   # DTE-matched IV / RV / rate bucket


def _fetch_term_comparison(ticker: str, dte: int, rate_used: float, rate_tenor: str) ->Optional[dict]:
    """Return DTE-matched {term_iv, term_rv, term_rate, vol_premium, period_label} or None.

    Two independent latest-row reads — expected-move IV and realized vol — for
    the term bucket this DTE falls into. Both order by date descending with
    limit 1, so each returns the most recent stored observation; neither
    checks HOW recent, so a thinly-covered ticker can yield a stale comparison.

    Returns None only when BOTH sides are missing; a one-sided result is still
    returned (with the other key null), because knowing this option's term IV
    is useful even without an RV to set against it.
    """
    period_type, rv_col, period_label = _dte_bucket(dte)
    db = get_supabase()

    iv_rows = (
        db.table("expected_move_snapshots")
        .select("iv,dte")
        .eq("ticker", ticker)
        .eq("period_type", period_type)
        .order("date", desc=True)
        .limit(1)
        .execute()
    ).data or []

    # NOTE the column here is `symbol`, not `ticker` as in the table above —
    # the two tables genuinely differ in their column naming.
    # rv_col is interpolated into the select, which is safe because it comes
    # from _dte_bucket's fixed literals, never from user input.
    rv_rows = (
        db.table("realized_vol_snapshots")
        .select(rv_col)
        .eq("symbol", ticker)
        .order("date", desc=True)
        .limit(1)
        .execute()
    ).data or []

    term_iv:Optional[float] = (iv_rows[0]["iv"] if iv_rows else None)
    term_rv:Optional[float] = (float(rv_rows[0][rv_col]) if rv_rows and rv_rows[0].get(rv_col) else None)

    if term_iv is None and term_rv is None:
        return None

    # THE VARIANCE RISK PREMIUM, term-matched. Positive means the market is
    # charging more for future vol than this name has recently delivered — the
    # normal state, and the reason systematic premium selling works until it
    # abruptly does not. A negative reading is the notable one.
    # Truthiness (not `is not None`) is used as the guard, so a genuine 0.0 on
    # either side suppresses the premium — harmless, since a zero vol reading
    # is bad data anyway.
    vol_premium = round((term_iv - term_rv) * 100, 2) if (term_iv and term_rv) else None

    # Everything below is converted to PERCENT for direct display — the one
    # place in this router that departs from the decimal convention.
    return {
        "period_label": period_label,
        "term_iv":      round(term_iv * 100, 2) if term_iv else None,   # percent
        "term_rv":      round(term_rv * 100, 2) if term_rv else None,   # percent
        "term_rate":    round(rate_used * 100, 4),                       # percent
        "rate_tenor":   rate_tenor,
        "vol_premium":  vol_premium,   # IV - RV in pct pts; positive = options expensive vs history
    }


def _fetch_heston_params(ticker: str) ->Optional[tuple[HestonParams, float]]:
    """Return (HestonParams, rmse_iv) from the most recent reliable calibration, or None.

    RELIABILITY IS GATED HERE, not by the caller. A calibration is used only if
    it fitted within 2 vol points (rmse_iv < 0.02) across at least 8 quotes.
    Below either bar the parameters describe a surface that was never really
    matched, and a Heston price from them would be worse than the SABR price it
    would replace — so None is returned and the pipeline falls back. Silent
    fallback is the right behaviour: a bad calibration should degrade the answer
    gracefully, not fail the request.

    Note the `converged` column is selected but not tested — rmse is the
    binding constraint, and a non-converged fit that still hit 2 vol points is
    usable.

    The id-descending secondary sort breaks same-obs_date ties deterministically.
    """
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
    """Run the full BS -> SABR -> Heston pipeline and report the edge.

    Note the ONLY reliability gate on Heston is inside _fetch_heston_params.
    If it returns params, the engine uses the Heston price as
    model_fair_value; heston_rmse is echoed so the caller can judge how much
    to trust the substitution.

    NOTE ON DB LATENCY: this handler makes up to three synchronous Supabase
    round trips (calibration, expected-move, realized-vol) in a plain `def`
    handler, which FastAPI runs in a threadpool — so it does not block the
    event loop, but it does make the endpoint's latency dominated by network
    I/O rather than by the pricing math. Omitting `ticker` skips all three.
    """
    heston_params:Optional[HestonParams] = None
    heston_rmse:Optional[float] = None
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
        # From the DB row, not the engine — the engine prices with the params
        # but never sees the quality metric attached to them.
        heston_rmse=heston_rmse,
        computed_iv=result.computed_iv,
        iv_diff_pct=result.iv_diff_pct,
        iv_note=result.iv_note,
        rate_used=result.rate_used,
        rate_tenor=result.rate_tenor,
        # Uses result.rate_used rather than req.r, so the comparison reports the
        # rate actually applied even when the caller let it default.
        term_comparison=_fetch_term_comparison(
            ticker=req.ticker,
            dte=req.days_to_expiry,
            rate_used=result.rate_used,
            rate_tenor=result.rate_tenor,
        ) if req.ticker else None,
    )
