from __future__ import annotations

# =============================================================================
# jobs/greek_grid_pull.py
# =============================================================================
# Job 5 — Fetch chain → greek grid + ATM greek snapshots from ONE shared fetch.
# Cron: 12 13-21 * * 1-5  (12 min after vol_surface_pull, Mon–Fri)
#
# Writes both greek_grid_snapshots and greek_snapshots. The former standalone
# greek_snapshots_pull job (:15 cron) duplicated this job's chain fetch for
# every ticker and is now a deprecated no-op — see jobs/greek_snapshots_pull.py.
# =============================================================================

import asyncio
import logging
from datetime import datetime, date, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_chain, market_session_guard
from jobs.greek_snapshots_pull import _upsert_greek_snapshots
from services.greek_grid_ingester import ingest as grid_ingest

log = logging.getLogger(__name__)

_CONCURRENCY = 5


async def run_greek_grid_pull() -> dict:
    skip = market_session_guard()
    if skip:
        log.info("greek_grid_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("greek_grid_pull: no tickers")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(row: dict) -> tuple[str, str]:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                async with sem:
                    chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"
                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    return ticker, "zero_spot"

                cells = grid_ingest(chain, datetime.now(timezone.utc))
                if cells:
                    _upsert_greek_grid(db, ticker, today, cells, spot, user_id)

                # ATM greek snapshots from the same chain — one fetch, two tables
                _upsert_greek_snapshots(db, ticker, today, spot, chain, user_id)

                if not cells:
                    log.warning("greek_grid_no_cells ticker=%s (snapshots still written)", ticker)
                    return ticker, "no_cells"
                log.info("greek_grid_ok ticker=%s cells=%d", ticker, len(cells))
                return ticker, "ok"
            except Exception as exc:
                log.error("greek_grid_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


_UPSERT_BATCH_SIZE = 200


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float, user_id: str) -> None:
    rows = [
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
        }
        for cell in cells
    ]
    for i in range(0, len(rows), _UPSERT_BATCH_SIZE):
        db.table("greek_grid_snapshots").upsert(
            rows[i : i + _UPSERT_BATCH_SIZE],
            on_conflict="user_id,ticker,obs_date,strike_band,expiry_bucket",
        ).execute()
