# =============================================================================
# main.py — FastAPI application (deployed as Cloud Run)
# =============================================================================

from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers import black_scholes, sabr, fair_value, iv_analytics, realized_vol, arb, scoring, decision, greek_grid, scheduler_trigger


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield  # No persistent scheduler — Cloud Scheduler triggers Cloud Functions instead


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


@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}
