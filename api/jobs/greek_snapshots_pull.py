from __future__ import annotations

# =============================================================================
# jobs/greek_snapshots_pull.py
# =============================================================================
# Job 6 — Fetch chain → ATM greek snapshots → upsert greek_snapshots.
# Cron: 15 * * * 1-5  (15 min after vol_surface_pull, Mon–Fri)
# =============================================================================

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import get_tickers, fetch_schwab_chain, _atm_contract, _pct_to_dec

log = logging.getLogger(__name__)

_DTE_BUCKETS = [4, 7, 31]


async def run_greek_snapshots_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("greek_snapshots_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("greek_snapshots_pull: no tickers")
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

                _upsert_greek_snapshots(db, ticker, today, spot, chain, user_id)
                log.info("greek_snapshots_ok ticker=%s", ticker)
                return ticker, "ok"
            except Exception as exc:
                log.error("greek_snapshots_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


def _upsert_greek_snapshots(
    db, ticker: str, today: str, spot: float, chain: dict, user_id: str
) -> None:
    expirations = parse_expirations(chain)
    if not expirations:
        return

    for target_dte in _DTE_BUCKETS:
        try:
            exp      = min(expirations, key=lambda e: abs(e["dte"] - target_dte))
            atm_call = _atm_contract(exp["calls"])
            atm_put  = _atm_contract(exp["puts"])

            if not atm_call and not atm_put:
                log.warning("greek_snapshot_no_atm ticker=%s dte=%s", ticker, target_dte)
                continue

            row: dict = {
                "user_id":          user_id,
                "ticker":           ticker,
                "obs_date":         today,
                "dte_bucket":       target_dte,
                "underlying_price": spot,
            }

            if atm_call:
                row.update({
                    "call_strike": atm_call.get("strikePrice"),
                    "call_dte":    atm_call.get("daysToExpiration"),
                    "call_delta":  atm_call.get("delta"),
                    "call_gamma":  atm_call.get("gamma"),
                    "call_theta":  atm_call.get("theta"),
                    "call_vega":   atm_call.get("vega"),
                    "call_rho":    atm_call.get("rho"),
                    "call_iv":     _pct_to_dec(atm_call.get("impliedVolatility")),
                    "call_oi":     atm_call.get("openInterest"),
                })

            if atm_put:
                row.update({
                    "put_strike": atm_put.get("strikePrice"),
                    "put_dte":    atm_put.get("daysToExpiration"),
                    "put_delta":  atm_put.get("delta"),
                    "put_gamma":  atm_put.get("gamma"),
                    "put_theta":  atm_put.get("theta"),
                    "put_vega":   atm_put.get("vega"),
                    "put_rho":    atm_put.get("rho"),
                    "put_iv":     _pct_to_dec(atm_put.get("impliedVolatility")),
                    "put_oi":     atm_put.get("openInterest"),
                })

            db.table("greek_snapshots").upsert(
                row,
                on_conflict="user_id,ticker,obs_date,dte_bucket",
            ).execute()

        except Exception as exc:
            log.warning("greek_snapshot_row_failed ticker=%s dte=%s error=%s", ticker, target_dte, exc)
