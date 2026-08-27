from __future__ import annotations

# =============================================================================
# jobs/equity_bars_pull.py
# =============================================================================
# Ingests daily OHLCV bars for the watchlist universe into equity_bars.
# Cron: 30 21 * * 1-5  (weekdays 21:30 UTC — after expected-move-pull at 21:00)
#
# This is the FOUNDATION job for the swing-setup engine. Channel fitting, the
# 50/200-day SMAs and volume surge all read equity_bars; none of them can run
# until this has populated it. Before this job existed the system had no equity
# price bars at all — iv_snapshots carries a daily close and nothing else.
#
# WHY IT RUNS AFTER THE CLOSE, NOT HOURLY
# ---------------------------------------
# Schwab returns the CURRENT session as a candle while the session is still
# open, with a partial high/low and a "close" that is just the last print. A bar
# like that is not wrong so much as unfinished, and writing it would mean every
# downstream SMA and channel fit silently consumed a bar that changes under it
# for the rest of the day. The job therefore runs once, after the close, and
# drops today's bar outright if it somehow runs early (see _drop_partial_bar).
#
# NO market_session_guard() CALL — deliberate, matching expected_move_pull. That
# guard rejects anything after 16:30 ET, which is exactly when this job runs.
#
# WHY IT REFETCHES A FULL YEAR EVERY NIGHT
# ----------------------------------------
# A 200-day SMA needs 200 bars, so the table must hold a year per ticker.
# Fetching only the last few days would be cheaper, but it would leave any gap
# from a failed night permanently unfilled — and a gap in the middle of an SMA
# window is invisible in the output, it just shifts the average. Refetching the
# year makes every run self-healing, and the upsert makes it idempotent: bars
# that already match are rewritten with identical values. At ~52 tickers x 252
# bars this is ~13k rows a night, which is trivial for Postgres and one HTTP
# call per ticker.
#
# BARS ARE MARKET DATA, NOT USER DATA
# -----------------------------------
# get_tickers() returns (ticker, user_id) PAIRS because most tables here are
# multi-tenant. equity_bars is not: NVDA's high on a given day is the same fact
# for every user, so the universe is deduplicated to bare symbols and no user_id
# is stored. Two users watching the same name cost one fetch, not two.
# =============================================================================

import asyncio
import logging
from datetime import datetime, timezone

import httpx
import pytz

from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_ohlc, get_tickers, is_eod_capture_run

log = logging.getLogger(__name__)

_ET = pytz.timezone("America/New_York")

# One year of candles. The edge function trims to the last N, and a year of
# sessions is ~252, so 400 always yields the full available history rather than
# a silently truncated series.
_DAYS = 400

# Schwab is rate-limited and this job is pure I/O. Six matches the concurrency
# the other fan-out jobs use; raising it trades a shorter run for 429s.
_CONCURRENCY = 6

# SCHWAB CANNOT SERVE INDEX HISTORY. $VIX.X, $VVIX.X and $VIX3M.X all fail
# against its pricehistory endpoint — the same limitation regime_pull documents,
# which is why the VIX family is sourced from FRED there. These symbols appear
# in watched_tickers because the options pipeline does cover them, but they will
# never yield bars here.
#
# Skipped EXPLICITLY rather than left to fail: an unfiltered run reports VIX in
# `failures` every single night, and a permanent expected failure is exactly the
# noise that hides a real one. ETFs (SPY, GLD, TLT, SMH...) are ordinary
# securities and are NOT excluded — they return bars normally.
_INDEX_SYMBOLS = frozenset({"VIX", "VVIX", "VIX3M", "SPX", "NDX", "RUT"})

# supabase-py has no batch size limit of its own, but a single upsert carrying
# every ticker's year at once builds a multi-megabyte request body. Chunking
# keeps each statement bounded and means a failure costs one chunk, not the run.
_CHUNK = 500


def _today_et() -> str:
    """Today's date in ET as an ISO string.

    ET, never UTC: between 00:00 and ~04:00 UTC the ET date is still the
    previous day, so a UTC-derived "today" would file the prior session under
    tomorrow. The same rollover hazard market_session_guard documents.
    """
    return datetime.now(timezone.utc).astimezone(_ET).date().isoformat()


def _drop_partial_bar(bars: list[dict]) -> list[dict]:
    """Drop the trailing bar when it is today's still-forming session.

    Only the LAST bar can be partial, and only when its date is today in ET and
    the close has not yet happened. is_eod_capture_run() is True from 16:00 ET
    onward, which is precisely when today's daily candle stops changing.

    On a weekend or holiday run the newest bar is Friday's, today's ET date does
    not match it, and nothing is dropped — which is correct, that bar is final.
    """
    if not bars:
        return bars
    if bars[-1]["date"] == _today_et() and not is_eod_capture_run():
        return bars[:-1]
    return bars


def _rows_for(ticker: str, bars: list[dict]) -> list[dict]:
    """Map fetched bars to equity_bars rows.

    bar_seq is 0 for every daily bar — the column exists so the 4h layer can
    number its two intraday bars within a date without a schema change. See
    migration 080 for the layout that reserves.
    """
    return [
        {
            "ticker":    ticker,
            "timeframe": "daily",
            "bar_date":  b["date"],
            "bar_seq":   0,
            "open":      b["open"],
            "high":      b["high"],
            "low":       b["low"],
            "close":     b["close"],
            "volume":    int(b["volume"]) if b.get("volume") is not None else None,
        }
        for b in bars
    ]


async def run() -> dict:
    """Fetch and upsert daily bars for the watchlist universe.

    Reports per-ticker outcomes in the returned dict rather than raising, so a
    single bad symbol costs one ticker's bars and not the whole night.
    """
    db = get_supabase()

    # Deduplicated to bare symbols: bars are not user-scoped. sorted() only so
    # the logs read in a stable order across runs.
    universe = {r["ticker"] for r in get_tickers(db)}
    skipped = sorted(universe & _INDEX_SYMBOLS)
    tickers = sorted(universe - _INDEX_SYMBOLS)
    if not tickers:
        log.warning("equity_bars_no_universe")
        return {"status": "skipped", "reason": "empty_universe", "tickers": 0}

    sem = asyncio.Semaphore(_CONCURRENCY)
    results: dict[str, int] = {}
    failures: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(ticker: str) -> None:
            async with sem:
                bars = await fetch_schwab_ohlc(client, ticker, days=_DAYS)
                if not bars:
                    failures[ticker] = "no_bars"
                    return
                bars = _drop_partial_bar(bars)
                if not bars:
                    failures[ticker] = "only_partial_bar"
                    return
                rows = _rows_for(ticker, bars)
                try:
                    # Chunked, and each chunk upserted on the natural key so a
                    # rerun overwrites rather than duplicating.
                    for i in range(0, len(rows), _CHUNK):
                        db.table("equity_bars").upsert(
                            rows[i:i + _CHUNK],
                            on_conflict="ticker,timeframe,bar_date,bar_seq",
                        ).execute()
                    results[ticker] = len(rows)
                except Exception as exc:
                    log.error("equity_bars_upsert_failed ticker=%s error=%r", ticker, exc)
                    failures[ticker] = f"upsert_failed: {exc!r}"[:200]

        await asyncio.gather(*(_process(t) for t in tickers))

    total = sum(results.values())
    log.info(
        "equity_bars_done tickers=%d ok=%d failed=%d rows=%d",
        len(tickers), len(results), len(failures), total,
    )
    return {
        "status":       "ok" if results else "failed",
        "tickers":      len(tickers),
        "succeeded":    len(results),
        "failed":       len(failures),
        "rows_written": total,
        # Reported, not hidden: these are deliberate exclusions, and naming them
        # keeps the difference between "skipped by design" and "broke" legible.
        "skipped_index_symbols": skipped,
        "failures":     failures,
    }
