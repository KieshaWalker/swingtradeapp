# =============================================================================
# routers/arb.py  —  mounted at /arb
# =============================================================================
# Static no-arbitrage validation of a vol surface snapshot.
#
#   POST /arb/check  points[] + spot -> violations, worst offenders, summary
#
# Math: api/services/arb_checker.py
#
# WHY CHECK THIS
# --------------
# A vol surface assembled from real quotes is not automatically consistent.
# Wide markets, stale mid-prices, and thin wings routinely produce a surface
# that implies a risk-free profit. Anything downstream that INTERPOLATES the
# surface — SABR fits, RND extraction, fair-value comparisons — will amplify
# such a defect into a confident, wrong number, so this runs as a gate rather
# than as a trading signal. Violations mean "do not trust this snapshot",
# almost never "there is free money here".
#
# TWO CONDITIONS ARE TESTED
# -------------------------
# 1. CALENDAR (across time, at fixed strike)
#    Total variance w = σ²·T must be NON-DECREASING in T. Variance accumulates;
#    it cannot un-happen. Note this is total variance, not vol — a σ that FALLS
#    with maturity is perfectly normal and not a violation, as long as σ²·T
#    still rises. Adjacent DTE pairs are compared after sorting, which is
#    sufficient by transitivity.
#
# 2. BUTTERFLY (across strike, at fixed T)
#    Call price C(K) must be CONVEX in K, i.e. C(K₋) - 2C(K₀) + C(K₊) ≥ 0.
#    A concave point means a butterfly spread could be bought for a negative
#    cost with a non-negative payoff. Checked on PRICES, not IVs, because
#    convexity is a statement about prices — which is why this check needs a
#    rate to build the forward, while the calendar check does not.
#
# Both use ARB_EPSILON as a tolerance so floating-point noise and one-tick
# rounding in the quotes do not register as violations.
# =============================================================================

import statistics
from typing import Optional
from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.arb_checker import check
from services.rate_service import get_rate_for_dte

router = APIRouter()


class ArbCheckRequest(BaseModel):
    # Untyped dicts (rather than a Pydantic point model) so the raw
    # vol_surface_snapshots.points JSONB can be forwarded verbatim. The service
    # reads defensively with .get() and skips malformed entries, so a bad point
    # is dropped rather than failing the whole request.
    points: list[dict]   # [{strike, dte, callIv?, putIv?}]
    spot_price: float = Field(..., gt=0)
    r: Optional[float] = Field(default=None, description="Risk-free rate as decimal; defaults to term-matched live rate")


@router.post("/check")
def arb_check(req: ArbCheckRequest):
    """Run the calendar and butterfly checks over one snapshot.

    Rate selection mirrors /sabr/calibrate: one rate for the entire surface,
    term-matched to the MEDIAN DTE. r only affects the butterfly check (via the
    forward), and convexity in K is overwhelmingly driven by the smile shape,
    so a per-slice rate would not change the verdict. The 30-day fallback
    covers a request whose points all lack a "dte" key — in which case the
    service will skip every point anyway and return a clean result.

    Returns 200 with violations listed, never an error status: an arbitrageable
    surface is a valid finding about the data, not a bad request.
    """
    if req.r is not None:
        r = req.r
    else:
        dtes = [p["dte"] for p in req.points if "dte" in p]
        median_dte = int(statistics.median(dtes)) if dtes else 30
        r = get_rate_for_dte(median_dte)[0]
    result = check(req.points, req.spot_price, r)
    return {
        # Computed properties on the dataclass, flattened here so the client
        # gets a headline verdict without having to count the arrays itself.
        "is_arbitrage_free": result.is_arbitrage_free,
        "total_violations": result.total_violations,
        "summary": result.summary,
        # Severity of the single worst offender in each family. Useful as a
        # threshold: a handful of tiny violations is quote noise, one large one
        # is a genuinely broken slice.
        "worst_calendar_violation": result.worst_calendar_violation,
        "worst_butterfly_violation": result.worst_butterfly_violation,
        # Full detail, hand-serialized because the service returns dataclasses.
        # Both near and far total variance are echoed so a client can show the
        # inversion rather than just its magnitude.
        "calendar_violations": [
            {
                "strike": v.strike, "near_dte": v.near_dte, "far_dte": v.far_dte,
                "near_total_var": v.near_total_var, "far_total_var": v.far_total_var,
                "violation": v.violation,
            }
            for v in result.calendar_violations
        ],
        # convexity_value is negative by construction — only concave points are
        # recorded — so its magnitude is the severity.
        "butterfly_violations": [
            {"dte": v.dte, "strike": v.strike, "convexity_value": v.convexity_value}
            for v in result.butterfly_violations
        ],
    }
