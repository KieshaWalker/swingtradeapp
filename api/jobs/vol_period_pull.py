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

import asyncio
import logging
from datetime import date, timedelta

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_closes
from services.realized_vol import compute_rv

log = logging.getLogger(__name__)

_WEEKLY_FETCH_DAYS  = 12
_MONTHLY_FETCH_DAYS = 30


# ── Entry points ──────────────────────────────────────────────────────────────

async def run_weekly_vol_period_pull() -> dict:
    today = date.today()
    period_start, period_end = _week_range(today)
    return await _run(
        period_type="weekly",
        period_start=period_start,
        period_end=period_end,
        fetch_days=_WEEKLY_FETCH_DAYS,
    )


async def run_monthly_vol_period_pull() -> dict:
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
    db = get_supabase()
    tickers_rows = get_tickers(db)
    if not tickers_rows:
        log.warning("vol_period_pull: no tickers")
        return {"status": "no_tickers"}

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
    friday = ref - timedelta(days=(ref.weekday() - 4) % 7)
    monday = friday - timedelta(days=4)
    return monday, friday


def _prior_month_range(ref: date) -> tuple[date, date]:
    last  = ref.replace(day=1) - timedelta(days=1)
    first = last.replace(day=1)
    return first, last


# ── DB helpers ────────────────────────────────────────────────────────────────

def _fetch_em_period(db, ticker: str, start: str, end: str) -> list[dict]:
    """EOD closing IV per day from expected_move_snapshots (daily rows)."""
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
    """Intraday iv_snapshots — used for rank/percentile/gamma_regime/skew/gex."""
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
    # IV and spot — prefer EOD source, fall back to intraday iv_snapshots
    if em_rows:
        iv_series  = [r["iv"]   for r in em_rows if r.get("iv")   is not None]
        iv_first   = em_rows[0].get("iv")
        iv_last    = em_rows[-1].get("iv")
        spot_first = em_rows[0].get("spot")
        spot_last  = em_rows[-1].get("spot")
        n_days     = len(em_rows)
    else:
        iv_series  = [r["atm_iv"]          for r in iv_rows if r.get("atm_iv")          is not None]
        iv_first   = iv_rows[0].get("atm_iv")           if iv_rows else None
        iv_last    = iv_rows[-1].get("atm_iv")           if iv_rows else None
        spot_first = iv_rows[0].get("underlying_price")  if iv_rows else None
        spot_last  = iv_rows[-1].get("underlying_price") if iv_rows else None
        n_days     = len(iv_rows)

    iv_change = (iv_last - iv_first) if (iv_last is not None and iv_first is not None) else None

    price_return_pct = (
        (spot_last - spot_first) / spot_first * 100
        if spot_first and spot_last and spot_first > 0
        else None
    )

    # Non-IV fields always come from iv_snapshots
    iv_last_row = iv_rows[-1] if iv_rows else {}
    skews = [r["skew"]      for r in iv_rows if r.get("skew")      is not None]
    gexes = [r["total_gex"] for r in iv_rows if r.get("total_gex") is not None]

    rv = compute_rv(closes) if len(closes) >= 2 else None
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
        "n_days":           n_days,
    }


def _upsert(db, snapshot: dict) -> None:
    db.table("vol_period_snapshots").upsert(
        snapshot,
        on_conflict="ticker,period_type,period_end_date",
    ).execute()
