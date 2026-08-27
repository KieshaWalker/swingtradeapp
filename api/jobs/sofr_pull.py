from __future__ import annotations

# =============================================================================
# jobs/sofr_pull.py
# =============================================================================
# Job — Fetch the latest SOFR rate from FRED and refresh the in-process cache.
# Cron: 30 13 * * 1-5  (8:30 AM ET, Mon–Fri — after NY Fed publishes)
#
# FRED series SOFR is published by the NY Fed each business day by ~8 AM ET.
# Running at 8:30 AM ET ensures we catch the day's rate before any pricing runs.
# =============================================================================
#
# JOB ZERO of the daily pipeline. Every pricing path — Black-Scholes, SABR,
# Heston, fair value — needs a discount rate, so this runs before the hourly
# jobs begin at 13:00 UTC.
#
# Despite the name it refreshes ALL FOUR tenors (30d SOFR, 3m/6m/1y T-bills),
# not just SOFR; refresh_sofr() is a backward-compatible alias for
# refresh_rates(). The tenor a given option uses is picked by DTE at pricing
# time via get_rate_for_dte().
#
# THE IMPORTANT CAVEAT: this writes to a MODULE-LEVEL DICT in
# services/rate_service.py, not to a database. On Cloud Run that means only the
# single instance that happened to serve this HTTP trigger gets the fresh
# rates. Other live instances keep whatever they had; cold instances start from
# DEFAULT_R (4.33%) until they serve their own refresh.
#
# That is accepted rather than fixed because the blast radius is genuinely
# small: short-rate moves are slow, and r affects an option price far less than
# vol does — an instance running a stale rate misprices by well under a tick.
# Persisting rates to a table would fix it, at the cost of a DB read on every
# pricing call. If this ever needs fixing, that is the trade to make.
#
# Failure is non-fatal by design: refresh_rates() falls back to the previous
# cached values (or DEFAULT_R) and reports status rather than raising, so a
# FRED outage degrades precision instead of stopping the pipeline.
# =============================================================================

import logging

from services.rate_service import refresh_sofr

log = logging.getLogger(__name__)


async def run_sofr_pull() -> dict:
    """Refresh the term-matched rate cache from FRED.

    No market_session_guard() call — unlike every other job here. Correct:
    rates are published once daily on a fixed schedule and are not chain data,
    so there is no stale-quote or date-rollover hazard to guard against.

    Returns the service's own result dict, which carries `status`
    ("ok" / "all_failed" / "no_api_key") plus every cached rate and its FRED
    observation date. Check `status` rather than assuming success — a missing
    FRED_API_KEY returns "no_api_key" with a 200, and the pipeline then runs
    the whole day on DEFAULT_R.

    The log line's `result.get("rate", 0)` reads a key the service does not
    return (rates are nested under "rates" by tenor label), so it always logs
    0.0000 — cosmetic only; the returned dict carries the real values.
    """
    result = await refresh_sofr()
    log.info("sofr_pull_complete status=%s rate=%.4f", result.get("status"), result.get("rate", 0))
    return result
