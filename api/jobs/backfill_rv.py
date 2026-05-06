from __future__ import annotations

# =============================================================================
# jobs/backfill_rv.py
# =============================================================================
# One-time backfill: fetch 2 years of daily closes from Schwab for every
# watched ticker, compute rolling rv_1d / rv_5d / rv_21d for each trading day,
# and bulk-upsert to realized_vol_snapshots.
#
# Run once from the terminal (inside the api/ venv):
#   python -m jobs.backfill_rv
#
# Or trigger via Cloud Run (add a temporary scheduler job or curl it manually):
#   curl -X POST https://<your-cloud-run-url>/jobs/backfill-rv \
#        -H "X-CloudScheduler-JobName: backfill-rv"
# =============================================================================

import asyncio
import logging
import math
from datetime import datetime, timezone, date

import httpx

from core.config import settings
from core.supabase_client import get_supabase
from jobs.common import get_tickers

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# Fetch 10 years of daily history
_START_YEAR_OFFSET = 10

# Max concurrent Schwab requests — avoids rate-limiting on large ticker lists
_CONCURRENCY = 5


def _epoch_ms(d: date) -> int:
    return int(datetime(d.year, d.month, d.day, tzinfo=timezone.utc).timestamp() * 1000)


def _compute_rv(closes: list[float]) -> float | None:
    """Annualized RV from a window of closes using Bessel correction."""
    if len(closes) < 2:
        return None
    sum_sq = 0.0
    n = 0
    for i in range(1, len(closes)):
        if closes[i - 1] > 0:
            sum_sq += math.log(closes[i] / closes[i - 1]) ** 2
            n += 1
    if n < 2:
        return None
    return math.sqrt(sum_sq / (n - 1) * 252)


async def _fetch_history(
    client: httpx.AsyncClient,
    ticker: str,
    start_ms: int,
    end_ms: int,
) -> tuple[list[str], list[float]]:
    """Returns (dates, closes) oldest→newest for the given epoch-ms range."""
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={"symbol": ticker, "startDate": start_ms, "endDate": end_ms},
            headers={
                "Authorization": f"Bearer {settings.supabase_service_key}",
                "Content-Type": "application/json",
            },
            timeout=30.0,
        )
        if resp.status_code != 200:
            log.warning("pricehistory_failed ticker=%s status=%s", ticker, resp.status_code)
            return [], []
        data = resp.json()
        return data.get("dates", []), data.get("closes", [])
    except Exception as exc:
        log.warning("pricehistory_error ticker=%s error=%s", ticker, exc)
        return [], []


def _build_rows(ticker: str, dates: list[str], closes: list[float]) -> list[dict]:
    """Compute rv_1d/rv_5d/rv_21d for each date and return upsert rows."""
    now = datetime.now(timezone.utc).isoformat()
    rows = []
    clean = [(d, c) for d, c in zip(dates, closes) if c and c > 0]
    if len(clean) < 2:
        return rows

    clean_dates  = [d for d, _ in clean]
    clean_closes = [c for _, c in clean]

    for i in range(1, len(clean_closes)):  # start at 1 — need at least 2 closes for rv_1d
        rv1d = abs(math.log(clean_closes[i] / clean_closes[i - 1])) * math.sqrt(252)

        w5  = clean_closes[max(0, i - 4):  i + 1]
        w21 = clean_closes[max(0, i - 20): i + 1]
        w63 = clean_closes[max(0, i - 62): i + 1]
        rv5d  = _compute_rv(w5)
        rv21d = _compute_rv(w21)
        rv63d = _compute_rv(w63)

        rows.append({
            "symbol":       ticker,
            "date":         clean_dates[i],
            "rv_1d":        rv1d,
            "rv_5d":        rv5d,
            "rv_21d":       rv21d,
            "rv_63d":       rv63d,
            "persisted_at": now,
        })
    return rows


async def run_backfill_rv() -> dict:
    db   = get_supabase()
    rows = get_tickers(db)
    if not rows:
        log.warning("backfill_rv: no tickers found")
        return {"status": "no_tickers"}

    unique_tickers = list({r["ticker"] for r in rows})
    log.info("backfill_rv: %d tickers", len(unique_tickers))

    today     = date.today()
    start     = date(today.year - _START_YEAR_OFFSET, today.month, today.day)
    start_ms  = _epoch_ms(start)
    end_ms    = _epoch_ms(today)

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    async with httpx.AsyncClient(timeout=90.0) as client:
        async def _process(ticker: str) -> tuple[str, str]:
            async with sem:
                try:
                    dates, closes = await _fetch_history(client, ticker, start_ms, end_ms)
                    if not dates:
                        return ticker, "no_data"

                    upsert_rows = _build_rows(ticker, dates, closes)
                    if not upsert_rows:
                        return ticker, "no_rows"

                    # Batch upsert in chunks of 500 to stay within Supabase limits
                    for i in range(0, len(upsert_rows), 500):
                        db.table("realized_vol_snapshots").upsert(
                            upsert_rows[i: i + 500],
                            on_conflict="symbol,date",
                        ).execute()

                    log.info("backfill_ok ticker=%s rows=%d", ticker, len(upsert_rows))
                    return ticker, f"ok:{len(upsert_rows)}"
                except Exception as exc:
                    log.error("backfill_failed ticker=%s error=%r", ticker, exc)
                    return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(t) for t in unique_tickers]))

    log.info("backfill_rv complete: %s", results)
    return {"status": "complete", "tickers": results}


if __name__ == "__main__":
    asyncio.run(run_backfill_rv())
