from __future__ import annotations

# =============================================================================
# jobs/vol_period_pull.py
# =============================================================================
# Job 8a — Weekly vol period snapshot → vol_period_snapshots.
# Cron: 0 22 * * 5   (Friday 10 PM UTC — 1 hour after expected_move_pull)
#
# Job 8b — Monthly vol period snapshot → vol_period_snapshots.
# Cron: 0 22 1 * *   (1st of each month 10 PM UTC, aggregates prior month)
#
# IV source:
#   ATM IV fields (open/close/high/low/avg) come from expected_move_snapshots
#   (daily rows, populated by Job 9 at 21 UTC) — these are EOD closing IVs.
#   Falls back to iv_snapshots.atm_iv if EOD rows are absent (e.g. backfill).
#
#   iv_rank, iv_percentile, gamma_regime, skew, gex always come from
#   iv_snapshots — they are not in expected_move_snapshots.
#
# RV source:
#   Schwab price history fetched fresh for the period close.
# =============================================================================
#
# WHAT THIS TABLE IS FOR: closing the loop on the vol forecast. Every other job
# records what the market EXPECTED; this one pairs that against what actually
# HAPPENED over the same window, per week and per month:
#
#   iv_rv_spread = atm_iv_close − rv
#
# Positive means options were priced above what the underlying delivered — the
# variance risk premium, and the reason systematic premium selling works. A
# persistently negative spread is the notable finding: the market was
# UNDER-charging for risk it then delivered.
#
# ⚠️ THE UNIT TRAP THIS FILE EXISTS TO NAVIGATE ⚠️
# The two IV sources store DIFFERENT UNITS for the same quantity:
#     expected_move_snapshots.iv   DECIMAL  (0.21)
#     iv_snapshots.atm_iv          PERCENT  (21.0)
# iv_analytics computes ATM IV in percent (it reads raw Schwab contract fields,
# which are percent) and stores it unconverted, while expected_move_pull
# converts to decimal before storing. _build_snapshot below divides by 100 on
# the fallback path for exactly this reason. compute_rv() returns a DECIMAL, so
# getting this wrong would make iv_rv_spread wrong by 100x — and it would still
# look like a plausible number.
#
# NO market_session_guard() CALL — both entry points run after the close, and
# that guard rejects anything after 16:30 ET.
#
# A MISSED RUN CANNOT BE RECOVERED by the next one: each fires for a specific
# window (last week / last month) and the following run covers the next window.
# Hence the full hour of slack after expected_move_pull.

import asyncio
import logging
from datetime import date, timedelta

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_closes
from services.realized_vol import compute_rv

log = logging.getLogger(__name__)

# Calendar days of price history to pull for the RV calculation. Deliberately
# longer than the period itself so the window survives holidays: 12 calendar
# days yields ~8 trading days for a 5-session week, and 30 yields ~21 for a
# month. compute_rv uses whatever closes it receives, so an over-long fetch
# widens the RV window slightly rather than breaking it.
_WEEKLY_FETCH_DAYS  = 12
_MONTHLY_FETCH_DAYS = 30


# ── Entry points ──────────────────────────────────────────────────────────────

async def run_weekly_vol_period_pull() -> dict:
    """Friday close: summarise the week that just ended."""
    today = date.today()
    period_start, period_end = _week_range(today)
    return await _run(
        period_type="weekly",
        period_start=period_start,
        period_end=period_end,
        fetch_days=_WEEKLY_FETCH_DAYS,
    )


async def run_monthly_vol_period_pull() -> dict:
    """1st of the month: summarise the month that just ended.

    Note the 1st can land on a weekend or holiday. The job still runs and simply
    finds whatever sessions the prior month contained — the cron does not guard
    against it because the period is defined by the calendar, not by sessions.
    """
    today = date.today()
    period_start, period_end = _prior_month_range(today)
    return await _run(
        period_type="monthly",
        period_start=period_start,
        period_end=period_end,
        fetch_days=_MONTHLY_FETCH_DAYS,
    )


# ── Core pipeline ─────────────────────────────────────────────────────────────

async def _run(
    period_type: str,
    period_start: date,
    period_end: date,
    fetch_days: int,
) -> dict:
    """Shared pipeline for both period types — they differ only in the window."""
    db = get_supabase()
    tickers_rows = get_tickers(db)
    if not tickers_rows:
        log.warning("vol_period_pull: no tickers")
        return {"status": "no_tickers"}

    # vol_period_snapshots is keyed (ticker, period_type, period_end_date) —
    # GLOBAL, no user_id, like the other market-data tables.
    unique_tickers = list({r["ticker"] for r in tickers_rows})
    start_str = period_start.isoformat()
    end_str   = period_end.isoformat()

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(ticker: str) -> tuple[str, str]:
            try:
                # EOD IV source — expected_move_snapshots daily rows
                em_rows = _fetch_em_period(db, ticker, start_str, end_str)

                # Intraday source — iv_percentile, iv_rank, gamma_regime, skew, gex
                iv_rows = _fetch_iv_period(db, ticker, start_str, end_str)

                # Only a total absence of both sources aborts. One source alone
                # still produces a row — see _build_snapshot for what each
                # contributes and which fields go null.
                if not em_rows and not iv_rows:
                    return ticker, "no_data"

                closes, _ = await fetch_schwab_closes(client, ticker, days=fetch_days)
                closes = [c for c in closes if c and c > 0]

                snapshot = _build_snapshot(
                    ticker, period_type, period_end, em_rows, iv_rows, closes
                )
                _upsert(db, snapshot)
                log.info(
                    "vol_period_ok ticker=%s type=%s end=%s n_days=%d rv=%s iv_src=%s",
                    ticker, period_type, period_end,
                    snapshot["n_days"],
                    f"{snapshot['rv']:.3f}" if snapshot.get("rv") else "—",
                    "eod" if em_rows else "intraday_fallback",
                )
                return ticker, "ok"
            except Exception as exc:
                log.error("vol_period_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(t) for t in unique_tickers]))

    return {
        "status":       "complete",
        "period_type":  period_type,
        "period_start": start_str,
        "period_end":   end_str,
        "tickers":      results,
    }


# ── Period date helpers ───────────────────────────────────────────────────────

def _week_range(ref: date) -> tuple[date, date]:
    """Monday-to-Friday of the week containing (or most recently before) `ref`.

    `(weekday() - 4) % 7` is the number of days back to the nearest PRIOR-or-same
    Friday: weekday() is 0=Mon..6=Sun, so Friday(4) gives 0 (today), Saturday(5)
    gives 1, and Monday(0) gives (0-4)%7 = 3 — walking back to LAST Friday.

    That makes the helper correct both on its normal Friday schedule and when
    run manually mid-week, where it summarises the last completed week rather
    than a partial current one.
    """
    friday = ref - timedelta(days=(ref.weekday() - 4) % 7)
    monday = friday - timedelta(days=4)
    return monday, friday


def _prior_month_range(ref: date) -> tuple[date, date]:
    """First and last calendar day of the month BEFORE `ref`.

    Stepping back one day from the 1st of `ref`'s month lands on the last day of
    the previous month, whatever its length — no month-length or leap-year
    special-casing needed.
    """
    last  = ref.replace(day=1) - timedelta(days=1)
    first = last.replace(day=1)
    return first, last


# ── DB helpers ────────────────────────────────────────────────────────────────

def _fetch_em_period(db, ticker: str, start: str, end: str) -> list[dict]:
    """EOD closing IV per day from expected_move_snapshots (daily rows).

    PREFERRED IV SOURCE. Filtered to period_type="daily" so each row is one
    session's closing ATM IV at ~1 DTE, giving a clean daily series. `iv` here
    is a DECIMAL — see the unit warning in the module header.

    Ascending order, and no .limit(), so `[0]` is the period open and `[-1]` the
    close. Safe without pagination because a period is at most ~23 rows, far
    under the PostgREST 1000-row cap.
    """
    resp = (
        db.table("expected_move_snapshots")
        .select("date,iv,spot")
        .eq("ticker", ticker)
        .eq("period_type", "daily")
        .gte("date", start)
        .lte("date", end)
        .order("date", desc=False)
        .execute()
    )
    return resp.data or []


def _fetch_iv_period(db, ticker: str, start: str, end: str) -> list[dict]:
    """Intraday iv_snapshots — used for rank/percentile/gamma_regime/skew/gex.

    Carries the analytics that expected_move_snapshots simply does not have.
    Also serves as the IV FALLBACK when no EOD rows exist (a backfill, or a
    period before expected_move_pull was running) — but note atm_iv here is
    PERCENT, not decimal. See the module header.
    """
    resp = (
        db.table("iv_snapshots")
        .select("date,atm_iv,skew,total_gex,iv_rank,iv_percentile,gamma_regime,underlying_price")
        .eq("ticker", ticker)
        .gte("date", start)
        .lte("date", end)
        .order("date", desc=False)
        .execute()
    )
    return resp.data or []


def _build_snapshot(
    ticker: str,
    period_type: str,
    period_end: date,
    em_rows: list[dict],
    iv_rows: list[dict],
    closes: list[float],
) -> dict:
    """Fold a period's daily rows and closes into one summary row.

    Two independent choices are made here, and conflating them is the mistake to
    avoid: the IV/spot series comes from whichever source is available (EOD
    preferred), while the analytics fields ALWAYS come from iv_snapshots
    regardless. So a period can legitimately have EOD-sourced IV alongside
    intraday-sourced skew and gamma_regime.
    """
    # IV and spot — prefer EOD source, fall back to intraday iv_snapshots
    if em_rows:
        iv_series  = [r["iv"]   for r in em_rows if r.get("iv")   is not None]
        iv_first   = em_rows[0].get("iv")
        iv_last    = em_rows[-1].get("iv")
        spot_first = em_rows[0].get("spot")
        spot_last  = em_rows[-1].get("spot")
        n_days     = len(em_rows)
    else:
        # atm_iv in iv_snapshots is stored in percent (e.g. 21.0); divide by 100
        # so units match expected_move_snapshots.iv (decimal) and compute_rv() output.
        iv_series  = [r["atm_iv"] / 100     for r in iv_rows if r.get("atm_iv")          is not None]
        iv_first   = (iv_rows[0].get("atm_iv") or 0) / 100  if iv_rows else None
        iv_last    = (iv_rows[-1].get("atm_iv") or 0) / 100 if iv_rows else None
        spot_first = iv_rows[0].get("underlying_price")      if iv_rows else None
        spot_last  = iv_rows[-1].get("underlying_price")     if iv_rows else None
        n_days     = len(iv_rows)

    # Absolute change in vol points over the period, not a percentage change:
    # IV moving 20% -> 25% is "+5 vol points", which is how vol moves are quoted.
    iv_change = (iv_last - iv_first) if (iv_last is not None and iv_first is not None) else None

    price_return_pct = (
        (spot_last - spot_first) / spot_first * 100
        if spot_first and spot_last and spot_first > 0
        else None
    )

    # Non-IV fields always come from iv_snapshots
    # These have no equivalent in expected_move_snapshots, so they go null when
    # iv_rows is empty even though the IV fields above may be fully populated.
    # skew and total_gex are AVERAGED across the period as well as sampled at
    # the close, so a period can be seen as persistently skewed rather than only
    # skewed on its final day.
    iv_last_row = iv_rows[-1] if iv_rows else {}
    skews = [r["skew"]      for r in iv_rows if r.get("skew")      is not None]
    gexes = [r["total_gex"] for r in iv_rows if r.get("total_gex") is not None]

    # Realized vol over the period, annualized, from the freshly-fetched closes.
    # Returns a DECIMAL — which is why the fallback path above had to convert
    # atm_iv from percent, or this subtraction would be off by 100x.
    rv = compute_rv(closes) if len(closes) >= 2 else None
    # THE HEADLINE NUMBER: what was priced minus what was delivered. Positive =
    # the variance risk premium was collected; negative = the market
    # under-charged for the move that followed.
    iv_rv_spread = (iv_last - rv) if (iv_last is not None and rv is not None) else None

    return {
        "ticker":           ticker,
        "period_type":      period_type,
        "period_end_date":  period_end.isoformat(),
        "spot_open":        spot_first,
        "spot_close":       spot_last,
        "price_return_pct": price_return_pct,
        "atm_iv_open":      iv_first,
        "atm_iv_close":     iv_last,
        "atm_iv_high":      max(iv_series)                     if iv_series else None,
        "atm_iv_low":       min(iv_series)                     if iv_series else None,
        "atm_iv_avg":       sum(iv_series) / len(iv_series)   if iv_series else None,
        "iv_change":        iv_change,
        "rv":               rv,
        "iv_rv_spread":     iv_rv_spread,
        "skew_avg":         sum(skews) / len(skews)            if skews     else None,
        "skew_close":       iv_last_row.get("skew"),
        "total_gex_avg":    sum(gexes) / len(gexes)            if gexes     else None,
        "iv_percentile":    iv_last_row.get("iv_percentile"),
        "iv_rank":          iv_last_row.get("iv_rank"),
        "gamma_regime":     iv_last_row.get("gamma_regime"),
        # How many daily rows backed this summary. A short n_days means the
        # period had gaps and every average above rests on thin data — check it
        # before reading anything else in the row.
        "n_days":           n_days,
    }


def _upsert(db, snapshot: dict) -> None:
    """Write the period summary, keyed (ticker, period_type, period_end_date).

    The dict is passed straight through, so _build_snapshot's keys ARE the
    column names — adding a field there requires a matching migration.
    Idempotent: re-running for the same period overwrites.
    """
    db.table("vol_period_snapshots").upsert(
        snapshot,
        on_conflict="ticker,period_type,period_end_date",
    ).execute()
