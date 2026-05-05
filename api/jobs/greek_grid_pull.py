from __future__ import annotations

# =============================================================================
# jobs/greek_grid_pull.py
# =============================================================================
# Job 5 — Fetch chain → greek grid aggregation → upsert greek_grid_snapshots.
# Cron: 12 * * * 1-5  (12 min after vol_surface_pull, Mon–Fri)
# =============================================================================

import asyncio
import logging
from datetime import datetime, date, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_chain
from services.greek_grid_ingester import ingest as grid_ingest

log = logging.getLogger(__name__)


async def run_greek_grid_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("greek_grid_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("greek_grid_pull: no tickers")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(row: dict) -> tuple[str, str]:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"
                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    return ticker, "zero_spot"

                cells = grid_ingest(chain, datetime.now(timezone.utc))
                if not cells:
                    return ticker, "no_cells"

                _upsert_greek_grid(db, ticker, today, cells, spot, user_id)
                log.info("greek_grid_ok ticker=%s cells=%d", ticker, len(cells))
                return ticker, "ok"
            except Exception as exc:
                log.error("greek_grid_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float, user_id: str) -> None:
    for cell in cells:
        db.table("greek_grid_snapshots").upsert(
            {
                "user_id":        user_id,
                "ticker":         ticker,
                "obs_date":       today,
                "strike_band":    cell.strike_band.value,
                "expiry_bucket":  cell.expiry_bucket.value,
                "strike":         cell.strike,
                "expiry_date":    cell.expiry_date.date().isoformat() if cell.expiry_date else None,
                "delta":          cell.delta,
                "gamma":          cell.gamma,
                "vega":           cell.vega,
                "theta":          cell.theta,
                "iv":             cell.iv,
                "vanna":          cell.vanna,
                "charm":          cell.charm,
                "volga":          cell.volga,
                "open_interest":  cell.open_interest,
                "volume":         cell.volume,
                "spot_at_obs":    spot,
                "contract_count": cell.contract_count,
            },
            on_conflict="user_id,ticker,obs_date,strike_band,expiry_bucket",
        ).execute()
