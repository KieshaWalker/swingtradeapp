from __future__ import annotations

# =============================================================================
# jobs/greek_snapshots_pull.py
# =============================================================================
# ATM greek snapshot writer (greek_snapshots table).
#
# DEPRECATED as a standalone job: the snapshots are now written by
# jobs/greek_grid_pull.py from its single chain fetch — running this job too
# duplicated a full Schwab chain fetch per ticker per hour for the same data.
# run_greek_snapshots_pull() is kept as a cheap no-op so any still-configured
# greek-snapshots-pull Cloud Scheduler job degrades gracefully; delete that
# scheduler job (see deploy.sh).
#
# _upsert_greek_snapshots() remains the shared writer, used by:
#   jobs/greek_grid_pull.py   (hourly pipeline)
#   jobs/ticker_dtes_pull.py  (on-demand fetch)
# =============================================================================

import logging

from core.chain_utils import parse_expirations
from jobs.common import _atm_contract, _pct_to_dec

log = logging.getLogger(__name__)

_DTE_BUCKETS = [4, 7, 31]


async def run_greek_snapshots_pull() -> dict:
    log.info("greek_snapshots_pull: deprecated no-op (merged into greek_grid_pull)")
    return {"status": "deprecated", "merged_into": "greek_grid_pull"}


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
                    "call_iv":     _pct_to_dec(atm_call.get("volatility") or atm_call.get("impliedVolatility")),
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
                    "put_iv":     _pct_to_dec(atm_put.get("volatility") or atm_put.get("impliedVolatility")),
                    "put_oi":     atm_put.get("openInterest"),
                })

            db.table("greek_snapshots").upsert(
                row,
                on_conflict="user_id,ticker,obs_date,dte_bucket",
            ).execute()

        except Exception as exc:
            log.warning("greek_snapshot_row_failed ticker=%s dte=%s error=%s", ticker, target_dte, exc)
