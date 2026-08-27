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
#
# TWO TABLES, ONE FETCH — the point of the merge. A Schwab chain call is the
# scarcest resource in the pipeline, and both outputs are just different
# readings of the same chain:
#
#   greek_grid_snapshots  AGGREGATED into a 5x5 matrix of (strike band x expiry
#                         bucket) cells — deep_itm..deep_otm across
#                         weekly..quarterly. A cross-sectional map of where
#                         risk sits on the surface.
#   greek_snapshots       The single ATM call and put at each of three DTE
#                         anchors. A narrow, precise time series.
#
# WHY THIS FETCHES ITS OWN CHAIN rather than reading vol_surface_snapshots like
# sabr_pull does: the grid ingester recomputes second-order Greeks (vanna,
# charm, volga) from a true Black-Scholes forward, and needs contract fields
# the stored surface points do not all retain. The 12-minute offset from job 1
# spaces the two fetches rather than sequencing a dependency.
#
# PARTIAL SUCCESS IS EXPLICITLY SUPPORTED: the ATM snapshots are written even
# when the grid produces no cells, and the ticker is reported as "no_cells"
# rather than failed. Losing one output should not cost the other.
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

# Same budget as vol_surface_pull — bounded by Schwab's rate limit, not CPU.
# The 12-minute cron stagger keeps the two jobs' fetch windows apart.
_CONCURRENCY = 5


async def run_greek_grid_pull() -> dict:
    """Fetch each ticker's chain once and write both Greek tables from it."""
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
                # Semaphore covers only the network call; the ingest and both
                # writes run outside it so a slot is not held during CPU work.
                async with sem:
                    chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"
                spot = float(chain.get("underlyingPrice", 0))
                # Spot is required by both writers — it sets moneyness for the
                # band classification and is stored as spot_at_obs.
                if spot <= 0:
                    return ticker, "zero_spot"

                # The ingester takes an explicit "now" rather than reading the
                # clock itself, so DTE and time-to-expiry are computed against
                # one consistent instant for every cell in the grid.
                cells = grid_ingest(chain, datetime.now(timezone.utc))
                if cells:
                    _upsert_greek_grid(db, ticker, today, cells, spot, user_id)

                # ATM greek snapshots from the same chain — one fetch, two tables
                # Deliberately OUTSIDE the `if cells` above: the ATM snapshots
                # are independent of whether grid aggregation produced anything.
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


# Chunk size for the batched upsert below. Defensive rather than load-bearing:
# the grid is at most 5 bands x 5 buckets = 25 cells per ticker, so a single
# batch always suffices in practice. It costs nothing and bounds the request
# size if the band/bucket taxonomy is ever widened.
_UPSERT_BATCH_SIZE = 200


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float, user_id: str) -> None:
    """Write the aggregated grid cells for one ticker.

    Each row is an AGGREGATE over every contract that fell into that
    (strike_band, expiry_bucket) cell — which is why the conflict key is the
    band/bucket pair and not a strike. `strike` and `expiry_date` on the row are
    representative values for the cell (the ingester takes medians), not the
    identity of a single contract; `contract_count` says how many contracts
    were folded in, and is the field to check before trusting a thin cell.

    `spot_at_obs` is stored per row rather than derived later because the band
    classification is relative to spot — without the spot it was computed
    against, "otm" is uninterpretable in hindsight.
    """
    rows = [
        {
            "user_id":        user_id,
            "ticker":         ticker,
            "obs_date":       today,
            # str Enums -> their wire values ("atm", "weekly", ...).
            "strike_band":    cell.strike_band.value,
            "expiry_bucket":  cell.expiry_bucket.value,
            "strike":         cell.strike,
            # A DATE column, so the datetime is reduced to its date part with
            # no timezone shift applied.
            "expiry_date":    cell.expiry_date.date().isoformat() if cell.expiry_date else None,
            # First-order Greeks, aggregated across the cell.
            "delta":          cell.delta,
            "gamma":          cell.gamma,
            "vega":           cell.vega,
            "theta":          cell.theta,
            "iv":             cell.iv,
            # Second-order — recomputed by the ingester from a true BS forward
            # (F = S·e^{rT}) rather than taken from Schwab, which does not
            # supply them. This is the main reason the job re-fetches a chain.
            "vanna":          cell.vanna,
            "charm":          cell.charm,
            "volga":          cell.volga,
            "open_interest":  cell.open_interest,
            "volume":         cell.volume,
            "spot_at_obs":    spot,
            # How many contracts this cell aggregates — a 1-contract cell is
            # not a reading about a band, it is a single strike.
            "contract_count": cell.contract_count,
        }
        for cell in cells
    ]
    for i in range(0, len(rows), _UPSERT_BATCH_SIZE):
        db.table("greek_grid_snapshots").upsert(
            rows[i : i + _UPSERT_BATCH_SIZE],
            on_conflict="user_id,ticker,obs_date,strike_band,expiry_bucket",
        ).execute()
