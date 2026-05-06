from __future__ import annotations

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

from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R
from core.supabase_client import get_supabase
from services.fair_value_engine import compute
from services.heston import HestonParams

router = APIRouter()


# ── DTE → matched period bucket ───────────────────────────────────────────────

def _dte_bucket(dte: int) -> tuple[str, str, str]:
    """Map DTE to (period_type, rv_column, period_label).

    period_type matches expected_move_snapshots.period_type values.
    rv_column matches realized_vol_snapshots column names.
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
    computed_iv: float | None = None      # IV back-solved from broker_mid
    iv_diff_pct: float | None = None      # computed_iv - implied_vol in vol points
    iv_note: str | None = None            # human-readable IV check message
    rate_used: float = 0.0                # risk-free rate used in pricing (decimal)
    rate_tenor: str = ""                  # e.g. "3-month T-bill"
    term_comparison: dict | None = None   # DTE-matched IV / RV / rate bucket


def _fetch_term_comparison(ticker: str, dte: int, rate_used: float, rate_tenor: str) -> dict | None:
    """Return DTE-matched {term_iv, term_rv, term_rate, vol_premium, period_label} or None."""
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

    rv_rows = (
        db.table("realized_vol_snapshots")
        .select(rv_col)
        .eq("symbol", ticker)
        .order("date", desc=True)
        .limit(1)
        .execute()
    ).data or []

    term_iv: float | None = (iv_rows[0]["iv"] if iv_rows else None)
    term_rv: float | None = (float(rv_rows[0][rv_col]) if rv_rows and rv_rows[0].get(rv_col) else None)

    if term_iv is None and term_rv is None:
        return None

    vol_premium = round((term_iv - term_rv) * 100, 2) if (term_iv and term_rv) else None

    return {
        "period_label": period_label,
        "term_iv":      round(term_iv * 100, 2) if term_iv else None,   # percent
        "term_rv":      round(term_rv * 100, 2) if term_rv else None,   # percent
        "term_rate":    round(rate_used * 100, 4),                       # percent
        "rate_tenor":   rate_tenor,
        "vol_premium":  vol_premium,   # IV - RV in pct pts; positive = options expensive vs history
    }


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
        computed_iv=result.computed_iv,
        iv_diff_pct=result.iv_diff_pct,
        iv_note=result.iv_note,
        rate_used=result.rate_used,
        rate_tenor=result.rate_tenor,
        term_comparison=_fetch_term_comparison(
            ticker=req.ticker,
            dte=req.days_to_expiry,
            rate_used=result.rate_used,
            rate_tenor=result.rate_tenor,
        ) if req.ticker else None,
    )
