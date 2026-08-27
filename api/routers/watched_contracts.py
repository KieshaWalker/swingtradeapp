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
#
# WHY THE CALLER SUPPLIES THE DATA
# --------------------------------
# The statelessness is a security decision, not a convenience one. Watched
# contracts and target levels are per-user rows protected by Supabase RLS. This
# service authenticates with the SERVICE KEY, which bypasses RLS entirely — so
# if it queried those tables itself it would have to re-implement the ownership
# check, and any mistake there leaks one user's watchlist to another. Letting
# the client read its own rows under its own token and post them here means the
# database enforces ownership and this endpoint is pure computation.
#
# WHAT MAKES THIS DIFFERENT FROM /scoring
# ---------------------------------------
# /scoring compares a contract against absolute standards (is the spread tight?
# is the delta in a good band?). This compares a contract against ITS OWN
# HISTORY: is this contract's IV low FOR THIS CONTRACT, and is it more
# underpriced than it usually is? That needs a stored time series, which is why
# it takes snapshots rather than a single quote.
#
# THE SIGNAL IS AN AND, NOT AN OR
# -------------------------------
# A signal fires only when the contract is cheap on its own history AND spot is
# sitting near a tracked level. Cheapness alone fires constantly in a trending
# name — the same false-positive problem the MFI/OBV backtests in backtests/
# were built to measure. Requiring level proximity is the noise filter, and it
# is why `levels` is worth populating even though it is optional.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.contract_opportunity import evaluate_watch_signal

router = APIRouter()


class EvaluateRequest(BaseModel):
    # max_length caps the payload — 2000 daily snapshots is ~8 years, far more
    # than the scoring needs, and the bound stops a runaway client request from
    # becoming a memory problem here. Order does not matter: the service sorts
    # by snapshot_date internally and treats the latest row as "today".
    # Each row needs at least: snapshot_date, implied_vol, market_price, model_theo.
    snapshots: list[dict] = Field(..., max_length=2000)  # watched_contract_snapshots / position_leg_snapshots rows
    # Optional — when omitted the service falls back to underlying_price on the
    # most recent snapshot row. Pass it explicitly for a live intraday read,
    # since the snapshot's value is end-of-day.
    underlying_price:Optional[float] = None
    # User targets and system-derived levels (zero-gamma, max-GEX strike) go in
    # the SAME list; proximity does not care which kind a level is. Empty list
    # means no level can ever be near, so the signal can never fire.
    levels: list[dict] = Field(default_factory=list)      # target_levels rows + any system-derived levels
    tolerance_pct: float = 2.0   # how close counts as "at" a level


def _signal_to_dict(ws) -> dict:
    """Flatten the WatchSignal dataclass tree to JSON.

    The full opportunity breakdown is returned even when signal is False, so
    the UI can show a near-miss ("grade B but not near a level") rather than
    just a silent no.
    """
    o = ws.opportunity
    return {
        "signal": ws.signal,   # the AND of cheapness and proximity
        "reason": ws.reason,   # always populated, including on a False signal
        "opportunity": {
            "snapshot_count": o.snapshot_count,
            # True when there is too little history to percentile-rank against.
            # Everything below is then null/zero — check this first.
            "insufficient_history": o.insufficient_history,
            # ── IV leg: is premium cheap for this contract? ────────────────
            "current_iv": o.current_iv,
            # rank = position between the historical min and max (span-based).
            # percentile = share of history strictly below today.
            # They disagree when the distribution is skewed; both are exposed
            # because a single outlier day compresses rank but not percentile.
            "iv_rank": o.iv_rank,
            "iv_percentile": o.iv_percentile,
            # ── Edge leg: is it more underpriced than usual? ───────────────
            # (model_theo − market_price)/market_price × 10,000. POSITIVE means
            # the model thinks it is worth more than the market does.
            "current_edge_bps": o.current_edge_bps,
            "edge_rank": o.edge_rank,
            "edge_percentile": o.edge_percentile,
            # ── Scores ────────────────────────────────────────────────────
            # 0-50 each, so they weigh equally. iv_score rewards LOW IV
            # percentile (cheap vol); edge_score rewards HIGH edge percentile
            # (unusually underpriced) — mirror-image bucket thresholds.
            "iv_score": o.iv_score,
            "edge_score": o.edge_score,
            "opportunity_score": o.opportunity_score,   # the sum, 0-100
            # Uses the same A/B/C thresholds as option_scoring, so a "B" here
            # means the same band as a "B" there.
            "grade": o.grade,
            "flags": o.flags,   # e.g. which leg's percentile was unavailable
        },
        # None when nothing is within tolerance_pct — which alone blocks the
        # signal regardless of how good the opportunity score is.
        "nearby_level": None if ws.nearby_level is None else {
            "label": ws.nearby_level.label,
            "price": ws.nearby_level.price,
            "source": ws.nearby_level.source,   # "user" or a system origin
            "distance_pct": ws.nearby_level.distance_pct,  # closest one wins
        },
    }


@router.post("/evaluate")
def evaluate_endpoint(req: EvaluateRequest):
    """Score one watched contract and decide whether it warrants attention.

    Pure function of the request body — no DB access, no auth beyond the app's
    own. See the header for why.
    """
    ws = evaluate_watch_signal(
        snapshots=req.snapshots,
        underlying_price=req.underlying_price,
        levels=req.levels,
        tolerance_pct=req.tolerance_pct,
    )
    return _signal_to_dict(ws)
