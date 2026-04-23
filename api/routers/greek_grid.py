from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Any

from services.greek_interpreter import interpret_greek_grid, interpret_greek_chart

router = APIRouter()


# ── Interpretation ─────────────────────────────────────────────────────────────

class InterpretGridRequest(BaseModel):
    grid_cells: list[dict[str, Any]]


class InterpretChartRequest(BaseModel):
    chart_history: list[dict[str, Any]]
    dte_bucket: int


@router.post("/interpret-grid")
def greek_grid_interpret_grid(req: InterpretGridRequest):
    try:
        return interpret_greek_grid(req.grid_cells)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/interpret-chart")
def greek_grid_interpret_chart(req: InterpretChartRequest):
    try:
        return interpret_greek_chart(req.chart_history, req.dte_bucket)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
