# =============================================================================
# main.py — FastAPI application (deployed as Cloud Run)
# =============================================================================
# Route registration summary:
#   /bs        -> api/routers/black_scholes.py
#   /sabr      -> api/routers/sabr.py
#   /heston    -> api/routers/heston.py
#   /fair-value-> api/routers/fair_value.py
#   /iv        -> api/routers/iv_analytics.py
#   /realized-vol -> api/routers/realized_vol.py
#   /arb       -> api/routers/arb.py
#   /scoring   -> api/routers/scoring.py
#   /decision  -> api/routers/decision.py
#   /greek-grid-> api/routers/greek_grid.py
#   /jobs      -> api/routers/scheduler_trigger.py
#   /regime    -> api/routers/regime.py
#   /macro     -> api/routers/macro.py
#   /fetch     -> api/routers/fetch_dtes.py
#
# Note: add a new router here when introducing a new backend feature.
#       The router file should define request/response Pydantic models,
#       and the Flutter client should be updated in lib/services/python_api/
#       to reflect any request or response schema changes.
# =============================================================================
#
# WHAT THIS SERVICE IS
# --------------------
# The Python math engine behind the Flutter app. Everything numerically
# non-trivial lives here rather than in Dart — pricing, calibration, IV
# analytics, regime ML — for three reasons: scipy/numpy/scikit-learn have no
# Dart equivalent, a single implementation cannot drift from a second one, and
# the scheduled jobs need the same code the interactive endpoints use.
#
# The app is a thin client over this. It reads results from Supabase (written
# by the /jobs pipeline) and calls these endpoints for on-demand computation.
#
# THREE CLASSES OF ROUTE
#   Stateless math    /bs /sabr /heston /arb /realized-vol /scoring /decision
#                     Pure functions. No DB, no auth. Same input, same output.
#   DB-backed         /fair-value /iv /regime /macro /watched-contracts
#                     Read (and sometimes write) Supabase.
#   Machine-triggered /jobs/*  — the scheduled pipeline, secret-gated.
#                     /fetch/* is the user-triggered equivalent, ungated.
#
# DEPLOYMENT: Cloud Run, which means COLD STARTS MATTER. See the lazy-import
# note in routers/scheduler_trigger.py — heavy job dependencies are imported
# inside handlers so a cold instance does not pay for scipy and scikit-learn
# before it can answer /health.
#
# NOTE ON IMPORTS: routers are imported as top-level packages ("from routers
# import ...", not "from .routers import ..."), so the service must be started
# with api/ as the working directory or on sys.path. The Dockerfile does this;
# running uvicorn from the repo root will not resolve.
# =============================================================================

import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, Request

log = logging.getLogger(__name__)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from routers import black_scholes, sabr, heston, fair_value, iv_analytics, realized_vol, arb, scoring, decision, greek_grid, scheduler_trigger, regime, macro, fetch_dtes, watched_contracts, trend_lines


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown hook. Everything before `yield` runs once at boot.

    The one job here is warming the regime ML inference cache, which lives in a
    module-level variable in regime_ml_service. Doing it at startup means the
    first /regime/ml-analyze request does not pay the model-load cost.

    THIS IS WHY THE PER-INSTANCE HOT RELOAD IN /regime/train IS ACCEPTABLE: an
    instance that missed a training run picks up the newest stored model the
    next time it cold-starts, right here. The fleet converges without any
    cross-instance coordination.

    Nothing runs after `yield` — no explicit shutdown work. The Supabase client
    and its httpx session are process-lifetime and released with the process.
    """
    # Attempt to load the latest trained regime ML model into the in-memory
    # inference cache.  Non-fatal: falls back to heuristic scoring if no model
    # is stored or Supabase is unreachable at startup.
    #
    # Related files:
    #   api/services/regime_ml_service.py  - load_trained_model implementation
    #   api/core/supabase_client.py      - Supabase client singleton used by loaders
    #   api/routers/regime.py           - regime endpoints that rely on the loaded model
    #
    # The blanket except is deliberate and important: a Supabase hiccup at boot
    # must not stop the service from starting. Every other endpoint is
    # unaffected by a missing model, and /regime/ml-analyze degrades to its
    # heuristic scoring path (reported as scoring_method="heuristic") rather
    # than failing. A crash-on-boot here would take the whole API down over an
    # optional feature.
    try:
        # Imported inside the function so a Supabase misconfiguration surfaces
        # as this warning rather than an import-time crash.
        from core.supabase_client import get_supabase
        from services.regime_ml_service import load_trained_model
        load_trained_model(get_supabase())
    except Exception as exc:
        log.warning("regime_ml_load_failed at startup (heuristic fallback active): %r", exc)
    yield


app = FastAPI(
    title="Swing Options Trader API",
    description="Python math engine for Black-Scholes, SABR, Heston, IV analytics, and GEX.",
    version="1.0.0",
    lifespan=lifespan,
)

# Wide-open CORS. The API holds no user credentials and issues no cookies —
# every route is either pure math, a read of shared market data, or gated on
# the X-Job-Secret header — so there is no browser-origin trust to protect.
# Per-user data is deliberately never queried here (see core/config.py on the
# service key), which is what makes this safe.
#
# It is also load-bearing for the Flutter web build, whose origin changes
# between local dev, preview deploys and production.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    """Catch-all 500 handler that preserves CORS headers.

    Without this, Starlette's ServerErrorMiddleware sits OUTSIDE CORSMiddleware
    in the stack and returns its 500 before CORS can add
    Access-Control-Allow-Origin. The browser then blocks the response, and the
    Flutter client sees an opaque network failure instead of the actual error —
    which is why the header is set explicitly below rather than left to the
    middleware.

    NOTE this leaks str(exc) to the client. Acceptable for a single-user
    internal tool where a specific error message is worth far more than the
    information hiding, but it is the reason not to put secrets in exception
    messages.
    """
    # Without this, Starlette's ServerErrorMiddleware returns the 500 response
    # before CORSMiddleware can inject Access-Control-Allow-Origin headers.
    #
    # Local imports shadow the module-level `log` with a function-scoped one.
    # Redundant, since logging is already imported at module level, but
    # harmless — and it guarantees the handler works even if module state is
    # somehow compromised during the failure being reported.
    import traceback
    import logging
    _log = logging.getLogger(__name__)
    # Logged twice by design: exc_info=True gives the structured traceback that
    # Cloud Logging groups into a single error entry, while format_exc() gives
    # a plain-text copy that survives log-processing that strips exc_info.
    _log.error(f"Unhandled exception: {exc}", exc_info=True)
    _log.error(traceback.format_exc())
    return JSONResponse(
        status_code=500,
        content={"detail": str(exc)},
        headers={"Access-Control-Allow-Origin": "*"}
    )

# Router mounting. The `prefix` here is the ONLY place a route's base path is
# set — the router files declare paths relative to it ("/price", not
# "/bs/price"). Changing a prefix silently breaks the Dart client, which
# hardcodes full paths; the mapping table in python_api_client.dart's header is
# the counterpart to this block.
app.include_router(black_scholes.router, prefix="/bs", tags=["Black-Scholes"])
app.include_router(sabr.router, prefix="/sabr", tags=["SABR"])
app.include_router(heston.router, prefix="/heston", tags=["Heston"])
app.include_router(fair_value.router, prefix="/fair-value", tags=["Fair Value"])
app.include_router(iv_analytics.router, prefix="/iv", tags=["IV Analytics"])
app.include_router(realized_vol.router, prefix="/realized-vol", tags=["Realized Vol"])
app.include_router(arb.router, prefix="/arb", tags=["Arbitrage"])
app.include_router(scoring.router, prefix="/scoring", tags=["Scoring"])
app.include_router(decision.router, prefix="/decision", tags=["Decision"])
app.include_router(greek_grid.router, prefix="/greek-grid", tags=["Greek Grid"])
app.include_router(scheduler_trigger.router, prefix="/jobs", tags=["Scheduled Jobs"])
app.include_router(regime.router, prefix="/regime", tags=["Regime"])
app.include_router(macro.router, prefix="/macro", tags=["Macro"])
app.include_router(fetch_dtes.router, prefix="/fetch", tags=["Fetch"])
# Note: watched_contracts is mounted here but is absent from the summary table
# at the top of this file — the table predates it.
app.include_router(watched_contracts.router, prefix="/watched-contracts", tags=["Watched Contracts"])
app.include_router(trend_lines.router, prefix="/trend-lines", tags=["Trend Lines"])


@app.get("/health")
async def health():
    """Liveness probe for Cloud Run.

    Deliberately shallow — it does NOT check Supabase, the ML model, or the rate
    cache. A dependency outage should not cause Cloud Run to kill and restart
    instances that are still serving the stateless math routes perfectly well.
    The timestamp makes it easy to confirm a response is not cached.
    """
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}
