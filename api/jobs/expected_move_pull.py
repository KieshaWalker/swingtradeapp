from __future__ import annotations

# =============================================================================
# jobs/expected_move_pull.py
# =============================================================================
# Job 9 — EOD chain → expected_move_snapshots (daily / weekly / monthly bands).
# Cron: 0 21 * * 1-5   (weekdays 9 PM UTC — after US market close at ~8 PM UTC)
#
# Runs ONCE per day at close, NOT hourly.  The intraday 4 PM UTC guard used
# by jobs 1-7 does NOT apply here — this job IS the end-of-day capture.
#
# For each ticker, fetches the EOD chain and computes expected-move bands at
# three DTE targets:
#   daily   → DTE ≈ 1   (tomorrow's expiry)
#   weekly  → DTE ≈ 7   (next-Friday expiry)
#   monthly → DTE ≈ 30  (front-month expiry)
#
# All three are upserted as separate rows in expected_move_snapshots.
# =============================================================================

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import get_tickers, fetch_schwab_chain
from services.expected_move import compute as em_compute, atm_iv_from_chain

log = logging.getLogger(__name__)

_DTE_TARGETS = {
    "daily":   1,
    "weekly":  7,
    "monthly": 30,
}


async def run_expected_move_pull() -> dict:
    db     = get_supabase()
    today  = date.today().isoformat()
    rows   = get_tickers(db)
    if not rows:
        log.warning("expected_move_pull: no tickers")
        return {"status": "no_tickers"}

    # Market-wide table — deduplicate to unique tickers
    unique_tickers = list({r["ticker"] for r in rows})
    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(ticker: str) -> tuple[str, str]:
            try:
                chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"

                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    return ticker, "zero_spot"

                expirations = parse_expirations(chain)
                if not expirations:
                    return ticker, "no_expirations"

                slices_written = 0
                for period_type, target_dte in _DTE_TARGETS.items():
                    iv, actual_dte = atm_iv_from_chain(expirations, spot, target_dte)
                    if iv is None or iv <= 0:
                        log.warning(
                            "expected_move_no_iv ticker=%s period=%s target_dte=%d",
                            ticker, period_type, target_dte,
                        )
                        continue

                    result = em_compute(spot=spot, iv=iv, dte=actual_dte)
                    _upsert(db, ticker, today, spot, period_type, result)
                    slices_written += 1
                    log.info(
                        "em_ok ticker=%s period=%s dte=%d iv=%.3f em=$%.2f (%.2f%%)",
                        ticker, period_type, actual_dte, iv,
                        result.em_dollars, result.em_pct,
                    )

                return ticker, f"ok:{slices_written}"
            except Exception as exc:
                log.error("expected_move_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(t) for t in unique_tickers]))

    return {"status": "complete", "tickers": results, "date": today}


def _upsert(db, ticker: str, today: str, spot: float, period_type: str, result) -> None:
    db.table("expected_move_snapshots").upsert(
        {
            "ticker":      ticker,
            "date":        today,
            "period_type": period_type,
            "spot":        spot,
            "iv":          result.iv,
            "dte":         result.dte,
            "em_dollars":  result.em_dollars,
            "em_pct":      result.em_pct,
            "upper_1s":    result.upper_1s,
            "lower_1s":    result.lower_1s,
            "upper_2s":    result.upper_2s,
            "lower_2s":    result.lower_2s,
            "upper_3s":    result.upper_3s,
            "lower_3s":    result.lower_3s,
            "computed_at": datetime.now(timezone.utc).isoformat(),
        },
        on_conflict="ticker,date,period_type",
    ).execute()
