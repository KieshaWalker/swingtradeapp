# =============================================================================
# main.py — FastAPI application (deployed as Cloud Run)
# =============================================================================
# Route registration summary:
#   /bs        -> api/routers/black_scholes.py
#   /sabr      -> api/routers/sabr.py
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
#
# Note: add a new router here when introducing a new backend feature.
#       The router file should define request/response Pydantic models,
#       and the Flutter client should be updated in lib/services/python_api/
#       to reflect any request or response schema changes.
# =============================================================================

from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from routers import black_scholes, sabr, fair_value, iv_analytics, realized_vol, arb, scoring, decision, greek_grid, scheduler_trigger, regime, macro


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Attempt to load the latest trained regime ML model into the in-memory
    # inference cache.  Non-fatal: falls back to heuristic scoring if no model
    # is stored or Supabase is unreachable at startup.
    #
    # Related files:
    #   api/services/regime_ml_service.py  - load_trained_model implementation
    #   api/core/supabase_client.py      - Supabase client singleton used by loaders
    #   api/routers/regime.py           - regime endpoints that rely on the loaded model
    try:
        from core.supabase_client import get_supabase
        from services.regime_ml_service import load_trained_model
        load_trained_model(get_supabase())
    except Exception:
        pass
    yield


app = FastAPI(
    title="Swing Options Trader API",
    description="Python math engine for Black-Scholes, SABR, Heston, IV analytics, and GEX.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    # Without this, Starlette's ServerErrorMiddleware returns the 500 response
    # before CORSMiddleware can inject Access-Control-Allow-Origin headers.
    import traceback
    import logging
    _log = logging.getLogger(__name__)
    _log.error(f"Unhandled exception: {exc}", exc_info=True)
    _log.error(traceback.format_exc())
    return JSONResponse(
        status_code=500,
        content={"detail": str(exc)},
        headers={"Access-Control-Allow-Origin": "*"}
    )

app.include_router(black_scholes.router, prefix="/bs", tags=["Black-Scholes"])
app.include_router(sabr.router, prefix="/sabr", tags=["SABR"])
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


@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}
