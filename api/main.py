# =============================================================================
# main.py — FastAPI application (deployed as Cloud Run)
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
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})

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
