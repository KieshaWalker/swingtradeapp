from datetime import datetime, date, timezone
from fastapi import APIRouter
from pydantic import BaseModel

from services.greek_grid_ingester import ingest
from core.supabase_client import get_supabase

router = APIRouter()


class GreekGridRequest(BaseModel):
    chain: dict
    obs_date: str | None = None
    ticker: str | None = None


@router.post("/ingest")
def greek_grid_ingest(req: GreekGridRequest):
    today = req.obs_date or date.today().isoformat()
    obs_dt = datetime.fromisoformat(today) if req.obs_date else datetime.now(timezone.utc)

    cells = ingest(req.chain, obs_dt)
    ticker = req.ticker or req.chain.get("symbol", "")
    spot = float(req.chain.get("underlyingPrice", 0))

    if cells and ticker:
        db = get_supabase()
        for cell in cells:
            db.table("greek_grid_snapshots").upsert({
                "ticker": ticker,
                "obs_date": today,
                "strike_band": cell.strike_band.value,
                "expiry_bucket": cell.expiry_bucket.value,
                "strike": cell.strike,
                "delta": cell.delta,
                "gamma": cell.gamma,
                "vega": cell.vega,
                "theta": cell.theta,
                "iv": cell.iv,
                "vanna": cell.vanna,
                "charm": cell.charm,
                "volga": cell.volga,
                "open_interest": cell.open_interest,
                "volume": cell.volume,
                "contract_count": cell.contract_count,
                "spot_at_obs": spot,
            }, on_conflict="ticker,obs_date,strike_band,expiry_bucket").execute()

    return {
        "cells_written": len(cells),
        "ticker": ticker,
        "date": today,
        "cells": [
            {
                "strike_band": c.strike_band.value,
                "expiry_bucket": c.expiry_bucket.value,
                "strike": c.strike,
                "delta": c.delta,
                "gamma": c.gamma,
                "vega": c.vega,
                "theta": c.theta,
                "iv": c.iv,
                "vanna": c.vanna,
                "charm": c.charm,
                "volga": c.volga,
                "open_interest": c.open_interest,
                "volume": c.volume,
                "contract_count": c.contract_count,
            }
            for c in cells
        ],
    }
