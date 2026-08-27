# =============================================================================
# routers/macro.py
# =============================================================================
# POST /macro/score      — compute 8-component macro regime score
# POST /macro/calibrate  — recompute IC-based weights from Supabase history
# =============================================================================
#
# WHAT THE SCORE IS
# -----------------
# A single 0-100 read on the market backdrop, blended from eight macro series
# that each say something about risk appetite:
#
#   vix          equity fear gauge          (high = bad, inverted)
#   yield_curve  2s10s spread               (positive/steep = good)
#   fed          fed funds level            (higher = tighter = bad, inverted)
#   spy_trend    SPY vs its 30-day average  (above = good)
#   dxy          dollar index 30d change    (rising = bad for risk, inverted)
#   hy_oas       high-yield credit spread   (widening = bad, inverted)
#   ig_oas       investment-grade spread    (widening = bad, inverted)
#   gold_copper  gold/copper ratio          (rising = defensive = bad)
#
# Bands: Risk-On ≥86 | Neutral-Bullish ≥71 | Neutral ≥45 | Caution ≥30 | Crisis <30
#
# EVERY COMPONENT IS Z-SCORED, NOT LEVEL-SCORED. Each series is standardized
# against its own trailing history (up to 252 observations) and clamped to ±3σ
# before being mapped to [0,1] and multiplied by its weight. This is what makes
# the components comparable at all — a VIX of 18 and an HY OAS of 340bp have no
# common scale, but "1.2σ above its own norm" and "0.4σ below its own norm" do.
# It also means the score measures CHANGE relative to normal, not absolute
# level: a persistently high-VIX regime drifts back toward neutral as the
# trailing window absorbs it.
#
# Components with fewer than 10 observations fall back to half their weight —
# a neutral contribution rather than a spuriously extreme one.
#
# NOTE ON THE CREDIT COMPONENTS: hy_oas and ig_oas are the same family of
# signal that the backtests/ MU work found front-ran the 2025 and 2026 equity
# breaks. They carry real predictive weight here for the same reason.
# =============================================================================
from fastapi import APIRouter, HTTPException

from services.macro_score import calibrate_macro_weights, compute_macro_score

router = APIRouter()


@router.post("/score")
async def macro_score():
    """Compute the current macro regime score.

    Takes no request body — every input is read from Supabase inside the
    service, so the score is always "as of now" against stored history.

    Declared async but the service call is SYNCHRONOUS and does blocking
    Supabase I/O, so it occupies the event loop for the duration. Acceptable
    given this is a low-frequency, user-triggered endpoint; it would need
    run_in_threadpool (or a plain `def`, which FastAPI offloads automatically)
    if it were ever called on a hot path.

    The broad except -> 500 converts any data-access or arithmetic failure into
    a reported error rather than a partial score. The service is defensive about
    missing series individually — it falls back to equal weights and half-weight
    components — so reaching this handler means something structural failed.
    """
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

    HOW THE WEIGHTS ARE DERIVED
    ---------------------------
    For each component the service reconstructs the same rolling z-score signal
    that scoring uses, then correlates it against SPY's 21-day FORWARD return.
    That correlation is the Information Coefficient. Weights are proportional to
    |IC| and normalized to sum to 100:

        weight_k = (|IC_k| / Σ|IC|) × (100 − floor_total) + floor_per_component

    Spearman (rank) correlation rather than Pearson, so the fit is driven by
    monotone relationships and is not dominated by a handful of crisis outliers.
    |IC| rather than IC because the sign is already handled by each component's
    `invert` flag — calibration decides how much a signal MATTERS, not which
    direction it points.

    The 2.0-point per-component FLOOR guarantees no signal is ever zeroed out.
    That is deliberate: an IC measured over a quiet stretch can be near zero for
    a component that matters enormously in a crisis, and a zero weight would
    keep it silent exactly when it starts working again.
    """
    try:
        weights = calibrate_macro_weights()
        return {
            "status": "ok",
            "weights": {k: round(v, 2) for k, v in weights.items()},
            # Should be ~100 by construction; a materially different total means
            # the fallback to equal weights kicked in, or a component dropped.
            "total":   round(sum(weights.values()), 2),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
