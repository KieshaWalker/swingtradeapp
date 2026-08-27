# =============================================================================
# routers/realized_vol.py  —  mounted at /realized-vol
# =============================================================================
# Realized (historical) volatility from a close series, plus its percentile
# rank against the ticker's own history.
#
#   POST /realized-vol/compute  closes[] -> rv20d, rv60d, percentiles, rating
#
# Math: api/services/realized_vol.py
#     RV = √(Σ ln(Pᵢ/Pᵢ₋₁)² / (n-1)) × √252     (annualized, Bessel-corrected)
#
# WHY THIS EXISTS ON THE BACKEND
# ------------------------------
# RV is the denominator of the IV/RV ratio — the single most useful read on
# whether options are rich or cheap. Implied vol says what the market EXPECTS;
# realized says what actually HAPPENED. IV persistently above RV is the
# variance risk premium; a collapse in that spread is usually the signal.
#
# This computation lives in Python on purpose and must not be reimplemented in
# Flutter: the app reads RV from the database (written by jobs/expected_move_pull
# and jobs/backfill_rv), and a second implementation on the client would drift.
# This endpoint is the ad-hoc/what-if path for a series the DB does not hold.
#
# UNITS: `closes` are raw prices; the returned rv20d/rv60d are ANNUALIZED
# DECIMALS (0.55 = 55% annualized vol). Percentiles are 0-100.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel

from services.realized_vol import compute

router = APIRouter()


class RealizedVolRequest(BaseModel):
    # OLDEST FIRST. The service walks forward taking ln(P[i]/P[i-1]), so a
    # reversed series produces sign-flipped log returns — which square to the
    # same value, meaning a reversed series yields a plausible but subtly wrong
    # answer rather than an obvious error. Order matters most for the trailing
    # window slice: closes[-20:] must be the MOST RECENT 20 sessions.
    closes: list[float]           # daily closes, oldest first
    # Prior RV readings used only for percentile ranking, not recomputed here.
    # Mutable [] defaults are safe in Pydantic (each instance gets its own copy,
    # unlike a plain Python function default), so this is not the classic bug.
    history_rv20d: list[float] = []
    history_rv60d: list[float] = []


@router.post("/compute")
def realized_vol_compute(req: RealizedVolRequest):
    """Compute 20d and 60d realized vol, and rank each against history.

    Two horizons because they answer different questions: rv20d is the current
    state (what vol IS right now), rv60d is the baseline (what vol has been).
    rv20d running well above rv60d means volatility is expanding.

    Short series are not rejected — the service falls back to computing over
    whatever closes exist when there are fewer than the full window, so a 10-day
    series returns a 10-day estimate labelled rv20d. Fewer than 2 closes returns
    zeros with rating='no_data'.

    `or None` converts an empty history list to None, which the service reads as
    "no history available" and answers with a null percentile rather than a
    meaningless 50.0. It also requires a minimum history length before ranking
    at all — a percentile against three prior observations is noise.

    The `rating` (extreme / elevated / normal / suppressed / extreme_low) is
    derived from the 20-DAY percentile only, defaulting to the 50.0 midpoint
    when that percentile is unavailable — so an unranked series always rates
    'normal'.
    """
    result = compute(req.closes, req.history_rv20d or None, req.history_rv60d or None)
    return {
        "rv20d": result.rv20d,
        "rv60d": result.rv60d,
        "rv20d_percentile": result.rv20d_percentile,   # None when history too short
        "rv60d_percentile": result.rv60d_percentile,
        "rating": result.rating.value,                  # str enum -> plain string
        # Trailing history echoed back for charting. When no history was sent,
        # the service substitutes a single-element list holding the value just
        # computed, so this is never empty.
        "rv20d_history": result.rv20d_history,
        "rv60d_history": result.rv60d_history,
    }
