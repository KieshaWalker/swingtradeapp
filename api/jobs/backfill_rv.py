from __future__ import annotations
from typing import Optional

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
#
# MANUAL ONLY — there is no cron entry for this and none should be added. It is
# long-running and write-heavy, and it exists for two situations:
#   * a new ticker joins the watchlist with no RV history behind it, or
#   * the RV computation changes and stored history must be rebuilt.
#
# SAFE TO RE-RUN. Every write is an upsert on (symbol, date), so a second run
# over the same window recomputes and overwrites rather than duplicating. That
# also makes it the tool for correcting historical rows after a formula change.
#
# THE HEADER ABOVE IS SLIGHTLY STALE: it says "2 years" and "rv_1d/rv_5d/rv_21d",
# but _START_YEAR_OFFSET is 10 and _build_rows also computes rv_63d. Trust the
# code.
#
# WHY RV LIVES IN PYTHON. Realized vol must be computed here in the backend and
# read from the database by the app — never recomputed in Flutter. A second
# implementation on the client would inevitably drift from this one, and RV is
# the denominator of the IV/RV ratio that most of the app's richness judgements
# rest on. jobs/expected_move_pull.py is the daily writer; this is the
# historical backfill for the same table.

import asyncio
import logging
import math
from datetime import datetime, timezone, date

import httpx

from core.config import settings
from core.supabase_client import get_supabase
from jobs.common import get_tickers
from services.realized_vol import compute_rv as _rv_base

def _compute_rv(closes: list[float]) -> Optional[float]:
    """compute_rv, but returning None instead of 0.0 for an unusable window.

    The shared service returns 0.0 when it has fewer than two valid closes.
    Storing that as a realized vol of zero would be a lie — it means "not
    computable", not "the stock did not move" — and it would drag any
    percentile ranking built over the column. NULL is the honest value.
    """
    rv = _rv_base(closes)
    return rv if rv > 0 else None

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# Fetch 10 years of daily history
# Long enough to span several distinct volatility regimes, so a percentile rank
# computed against it means something more than "versus the recent past".
_START_YEAR_OFFSET = 10

# Max concurrent Schwab requests — avoids rate-limiting on large ticker lists
_CONCURRENCY = 5


def _epoch_ms(d: date) -> int:
    """Convert a date to the epoch MILLISECONDS Schwab's API expects.

    Pinned to UTC midnight. The exact instant does not matter here — the range
    spans a decade and the API returns whole trading days — so no market-timezone
    handling is needed.

    Note date(year - 10, month, day) raises on 29 February in a leap year whose
    target year is not one. A once-in-four-years annoyance on a manual job; not
    worth guarding.
    """
    return int(datetime(d.year, d.month, d.day, tzinfo=timezone.utc).timestamp() * 1000)



async def _fetch_history(
    client: httpx.AsyncClient,
    ticker: str,
    start_ms: int,
    end_ms: int,
) -> tuple[list[str], list[float]]:
    """Returns (dates, closes) oldest→newest for the given epoch-ms range.

    A local variant of jobs.common.fetch_schwab_closes rather than a reuse of
    it: that helper takes a `days` count and returns (closes, volumes), while
    this needs an explicit start/end range and the DATES, since each computed RV
    row must be stamped with the session it belongs to.

    Returns ([], []) on any failure — never raises, matching the convention in
    jobs/common.py.
    """
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
    """Compute rv_1d/rv_5d/rv_21d for each date and return upsert rows.

    Walks the series once, emitting one row per session with four trailing
    windows measured as of that session. Every window is BACKWARD-looking, so no
    row uses data from after its own date — essential, since these rows are
    later ranked against each other and any lookahead would leak the future into
    a historical percentile.

    Rows are computed for every session from the second onward; short windows
    near the start of the series are computed over whatever closes exist rather
    than skipped, so early rows are noisier estimates, not absent ones.
    """
    now = datetime.now(timezone.utc).isoformat()
    rows = []
    # Drop null and non-positive closes BEFORE pairing, so the surviving dates
    # and closes stay aligned. Note this makes the windows below count VALID
    # OBSERVATIONS rather than calendar sessions — a gap in the data shortens
    # the effective lookback rather than reaching further back in time.
    clean = [(d, c) for d, c in zip(dates, closes) if c and c > 0]
    if len(clean) < 2:
        return rows

    clean_dates  = [d for d, _ in clean]
    clean_closes = [c for _, c in clean]

    for i in range(1, len(clean_closes)):  # start at 1 — need at least 2 closes for rv_1d
        # rv_1d is a SINGLE-RETURN estimator, not a sample standard deviation:
        # |ln(P_t/P_{t-1})| x sqrt(252). With one observation there is no
        # dispersion to measure, so the absolute move itself is annualized. It
        # is extremely noisy by construction — useful as a "how big was today"
        # marker, not as a vol estimate. The windowed columns below use the
        # proper Bessel-corrected formula via _compute_rv.
        rv1d = abs(math.log(clean_closes[i] / clean_closes[i - 1])) * math.sqrt(252)

        # Window sizes are CLOSE COUNTS, one more than the return count they
        # produce: 5 closes -> 4 returns, 21 -> 20, 63 -> 62. The column names
        # (rv_5d, rv_21d, rv_63d) refer to the return counts, which is why the
        # slice offsets are 4/20/62 rather than 5/21/63.
        #
        # max(0, ...) clamps at the start of the series, so early rows are
        # computed over a short window rather than being skipped.
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
            # One timestamp shared by every row in the batch — records when the
            # backfill ran, which is what distinguishes a backfilled row from
            # one written live by expected_move_pull on its own session date.
            "persisted_at": now,
        })
    return rows


async def run_backfill_rv() -> dict:
    """Backfill realized vol for every watched ticker over the last decade."""
    db   = get_supabase()
    rows = get_tickers(db)
    if not rows:
        log.warning("backfill_rv: no tickers found")
        return {"status": "no_tickers"}

    # De-duplicated to TICKER only, dropping user_id: realized_vol_snapshots is
    # keyed (symbol, date) with no user column, because a stock's realized
    # volatility is a property of the stock, not of who is watching it.
    #
    # Set iteration order is arbitrary, so run order varies between invocations.
    # Harmless here — every ticker is independent and the writes are idempotent.
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
                    # A decade is ~2,500 rows per ticker, so this is a real
                    # constraint, not a formality — roughly five requests each.
                    # Chunks are NOT transactional: a failure partway leaves
                    # earlier chunks written. Safe, because re-running upserts
                    # over the same keys.
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


# Runnable directly as a module, which is the documented invocation:
#   python -m jobs.backfill_rv
# The module-level logging.basicConfig above exists for this path — under Cloud
# Run the platform configures logging instead.
if __name__ == "__main__":
    asyncio.run(run_backfill_rv())
