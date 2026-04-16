import math
from fastapi import APIRouter
from pydantic import BaseModel, Field

from core.constants import DEFAULT_R, SABR_BETA
from services.sabr import sabr_iv, sabr_alpha
from services.sabr_calibrator import calibrate_snapshot, SabrSlice
from core.supabase_client import get_supabase
from datetime import date

router = APIRouter()


class SabrIvRequest(BaseModel):
    F: float = Field(..., gt=0, description="Forward price")
    strike: float = Field(..., gt=0)
    T: float = Field(..., gt=0, description="Time to expiry in years")
    alpha: float = Field(..., gt=0)
    beta: float = SABR_BETA
    rho: float = Field(default=-0.7)
    nu: float = Field(default=0.40, gt=0)


class SabrIvResponse(BaseModel):
    sabr_vol: float


class SabrCalibrateRequest(BaseModel):
    ticker: str
    obs_date: str | None = None
    spot_price: float = Field(..., gt=0)
    points: list[dict]  # [{strike, dte, callIv?, putIv?}]
    r: float = DEFAULT_R


class SabrCalibrateResponse(BaseModel):
    slices: list[dict]


@router.post("/iv", response_model=SabrIvResponse)
def sabr_iv_endpoint(req: SabrIvRequest):
    vol = sabr_iv(F=req.F, K=req.strike, T=req.T, alpha=req.alpha,
                  beta=req.beta, rho=req.rho, nu=req.nu)
    return SabrIvResponse(sabr_vol=vol)


@router.post("/calibrate", response_model=SabrCalibrateResponse)
def sabr_calibrate_endpoint(req: SabrCalibrateRequest):
    slices = calibrate_snapshot(spot=req.spot_price, points=req.points, r=req.r)
    today = req.obs_date or date.today().isoformat()

    # Persist to Supabase
    if slices:
        db = get_supabase()
        for s in slices:
            db.table("sabr_calibrations").upsert({
                "ticker": req.ticker,
                "obs_date": today,
                "dte": s.dte,
                "alpha": s.alpha,
                "beta": s.beta,
                "rho": s.rho,
                "nu": s.nu,
                "rmse": s.rmse,
                "n_points": s.n_points,
            }, on_conflict="ticker,obs_date,dte").execute()

    return SabrCalibrateResponse(slices=[s.to_dict() for s in slices])
