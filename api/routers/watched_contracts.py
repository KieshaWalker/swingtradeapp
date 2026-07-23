from __future__ import annotations
from typing import Optional

# =============================================================================
# routers/watched_contracts.py
# =============================================================================
# POST /watched-contracts/evaluate -> evaluate_endpoint
#
# Stateless, same shape as routers/scoring.py: the caller (Flutter, via its
# own RLS-scoped Supabase reads) supplies the contract's snapshot history
# and any levels to check proximity against; this endpoint does no Supabase
# I/O itself. See services/contract_opportunity.py for the actual math.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.contract_opportunity import evaluate_watch_signal

router = APIRouter()


class EvaluateRequest(BaseModel):
    snapshots: list[dict] = Field(..., max_length=2000)  # watched_contract_snapshots / position_leg_snapshots rows
    underlying_price:Optional[float] = None
    levels: list[dict] = Field(default_factory=list)      # target_levels rows + any system-derived levels
    tolerance_pct: float = 2.0


def _signal_to_dict(ws) -> dict:
    o = ws.opportunity
    return {
        "signal": ws.signal,
        "reason": ws.reason,
        "opportunity": {
            "snapshot_count": o.snapshot_count,
            "insufficient_history": o.insufficient_history,
            "current_iv": o.current_iv,
            "iv_rank": o.iv_rank,
            "iv_percentile": o.iv_percentile,
            "current_edge_bps": o.current_edge_bps,
            "edge_rank": o.edge_rank,
            "edge_percentile": o.edge_percentile,
            "iv_score": o.iv_score,
            "edge_score": o.edge_score,
            "opportunity_score": o.opportunity_score,
            "grade": o.grade,
            "flags": o.flags,
        },
        "nearby_level": None if ws.nearby_level is None else {
            "label": ws.nearby_level.label,
            "price": ws.nearby_level.price,
            "source": ws.nearby_level.source,
            "distance_pct": ws.nearby_level.distance_pct,
        },
    }


@router.post("/evaluate")
def evaluate_endpoint(req: EvaluateRequest):
    ws = evaluate_watch_signal(
        snapshots=req.snapshots,
        underlying_price=req.underlying_price,
        levels=req.levels,
        tolerance_pct=req.tolerance_pct,
    )
    return _signal_to_dict(ws)
