from fastapi import APIRouter
from pydantic import BaseModel

from services.realized_vol import compute

router = APIRouter()


class RealizedVolRequest(BaseModel):
    closes: list[float]           # daily closes, oldest first
    history_rv20d: list[float] = []
    history_rv60d: list[float] = []


@router.post("/compute")
def realized_vol_compute(req: RealizedVolRequest):
    result = compute(req.closes, req.history_rv20d or None, req.history_rv60d or None)
    return {
        "rv20d": result.rv20d,
        "rv60d": result.rv60d,
        "rv20d_percentile": result.rv20d_percentile,
        "rv60d_percentile": result.rv60d_percentile,
        "rating": result.rating.value,
        "rv20d_history": result.rv20d_history,
        "rv60d_history": result.rv60d_history,
    }
