# =============================================================================
# routers/macro.py
# =============================================================================
# POST /macro/score      — compute 8-component macro regime score
# POST /macro/calibrate  — recompute IC-based weights from Supabase history
# =============================================================================
from fastapi import APIRouter, HTTPException

from services.macro_score import calibrate_macro_weights, compute_macro_score

router = APIRouter()


@router.post("/score")
async def macro_score():
    try:
        result = compute_macro_score()
        return result.to_dict()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/calibrate")
async def macro_calibrate():
    """Recompute component weights from Spearman IC vs SPY forward returns.

    Call this after accumulating significant new history, or whenever you want
    to refresh the weight derivation.  Results are cached in-process until the
    next call.
    """
    try:
        weights = calibrate_macro_weights()
        return {
            "status": "ok",
            "weights": {k: round(v, 2) for k, v in weights.items()},
            "total":   round(sum(weights.values()), 2),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
