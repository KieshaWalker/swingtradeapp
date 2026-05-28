from __future__ import annotations

import math
from typing import Optional
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


class SabrPoint(BaseModel):
    strike: float = Field(..., gt=0)
    dte: int = Field(..., ge=1, le=1095)
    callIv: Optional[float] = Field(default=None, gt=0)
    putIv: Optional[float] = Field(default=None, gt=0)


class SabrCalibrateRequest(BaseModel):
    ticker: str
    obs_date: Optional[str] = None
    spot_price: float = Field(..., gt=0)
    points: list[SabrPoint] = Field(..., min_length=1)
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
    points = [p.model_dump(exclude_none=True) for p in req.points]
    slices = calibrate_snapshot(spot=req.spot_price, points=points, r=req.r)
    return SabrCalibrateResponse(slices=[s.to_dict() for s in slices])
