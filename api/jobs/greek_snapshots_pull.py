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
#
# WHAT greek_snapshots HOLDS, and how it differs from greek_grid_snapshots:
#   greek_snapshots       ONE ATM call + ONE ATM put per DTE bucket. A narrow,
#                         precise time series for charting "how has the
#                         at-the-money option's gamma/theta/vega evolved".
#   greek_grid_snapshots  AGGREGATED cells across 5 strike bands x 5 expiry
#                         buckets. A cross-sectional view of the whole surface.
# Both come from the same chain fetch; they answer different questions.
# =============================================================================

import logging

from core.chain_utils import parse_expirations
from jobs.common import _atm_contract, _pct_to_dec

log = logging.getLogger(__name__)

# Target DTEs to snapshot. Not evenly spaced — chosen to straddle the points
# where option behaviour changes character:
#   4  — inside the final week; gamma and pin risk dominate
#   7  — the standard weekly
#   31 — just past a month, the classic swing horizon
# The nearest AVAILABLE expiration to each target is used (see below), so these
# are anchors, not requirements.
_DTE_BUCKETS = [4, 7, 31]


async def run_greek_snapshots_pull() -> dict:
    """No-op retained for backward compatibility. See the module header.

    Returns a 200 with an explicit "deprecated" status so a still-configured
    Cloud Scheduler entry succeeds quietly rather than alerting on a 404, while
    the status string makes the situation obvious to anyone reading run history.
    """
    log.info("greek_snapshots_pull: deprecated no-op (merged into greek_grid_pull)")
    return {"status": "deprecated", "merged_into": "greek_grid_pull"}


def _upsert_greek_snapshots(
    db, ticker: str, today: str, spot: float, chain: dict, user_id: str
) -> None:
    """Write one ATM call/put row per DTE bucket. The shared writer — see header.

    Takes an already-fetched chain rather than fetching one, which is the whole
    point of the merge: the caller has the chain, and this reads it a second way.

    Silent no-op when the chain yields no expirations; every other failure is
    contained per-bucket (see below) rather than raising to the caller.
    """
    expirations = parse_expirations(chain)
    if not expirations:
        return

    for target_dte in _DTE_BUCKETS:
        # Per-bucket try/except: one malformed expiry must not cost the other
        # two buckets their snapshot for this hour. Logged at WARNING and
        # skipped — the caller is never told, because a partial write is a
        # better outcome than none.
        try:
            # NEAREST available expiration, not an exact match. Real chains do
            # not list a 4-DTE expiry on most days, so the closest one stands
            # in. Note the row is still keyed by target_dte while the stored
            # call_dte/put_dte record what was ACTUALLY captured — read those,
            # not dte_bucket, when the exact tenor matters.
            exp      = min(expirations, key=lambda e: abs(e["dte"] - target_dte))
            atm_call = _atm_contract(exp["calls"])
            atm_put  = _atm_contract(exp["puts"])

            # Only skip when BOTH sides are missing — a one-sided row is still
            # worth storing, since the columns for the absent side simply stay
            # untouched by the .update() below.
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

            # Greeks are taken RAW from Schwab (no _fgt0/_fne0 filtering), so a
            # zero or null lands in the DB as-is. Deliberate here: this is a
            # point-in-time record of what the broker reported, and the
            # extractors' "0 means missing" convention would erase the
            # distinction between a genuinely tiny greek and an absent one.
            #
            # IV is the exception — it goes through _pct_to_dec because the
            # column stores DECIMALS while Schwab reports percent. The
            # `volatility or impliedVolatility` fallback covers both field
            # names Schwab has used.
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

            # One row per (user, ticker, day, bucket): the hourly runs overwrite
            # each other through the session, so the stored row is always the
            # latest intraday state and the final write of the day is the close.
            db.table("greek_snapshots").upsert(
                row,
                on_conflict="user_id,ticker,obs_date,dte_bucket",
            ).execute()

        except Exception as exc:
            log.warning("greek_snapshot_row_failed ticker=%s dte=%s error=%s", ticker, target_dte, exc)
