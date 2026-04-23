# =============================================================================
# routers/macro.py
# =============================================================================
# POST /macro/score  — compute 8-component macro regime score from Supabase data
# =============================================================================
from fastapi import APIRouter, HTTPException

from services.macro_score import compute_macro_score

router = APIRouter()


@router.post("/score")
async def macro_score():
    try:
        result = compute_macro_score()
        return result.to_dict()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
