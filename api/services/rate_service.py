from __future__ import annotations
from typing import Optional

# =============================================================================
# services/rate_service.py
# =============================================================================
# Term-matched risk-free rate cache — fetched once daily from FRED.
#
# Tenor mapping (DTE → rate):
#   ≤ 30 DTE   → 30-day SOFR average    (SOFR30DAYAVG)
#   31–90 DTE  → 3-month T-bill         (DTB3)
#   91–180 DTE → 6-month T-bill         (DTB6)
#   > 180 DTE  → 1-year T-bill          (DTB1YR)
#
# FRED API key: free at https://fred.stlouisfed.org/docs/api/api_key.html
#               Set FRED_API_KEY in api/.env
#
# Usage:
#   from services.rate_service import get_rate_for_dte, get_sofr
#   r, label = get_rate_for_dte(45)   # → (0.0428, "3-month T-bill")
#   r         = get_sofr()            # overnight/short-term fallback
#
#   await refresh_rates()             # called by sofr_pull job
# =============================================================================
#
# TERM MATCHING IS THE POINT. Rates have a term structure, so discounting a
# 7-day option at a 1-year rate is simply wrong. Every pricing path calls
# get_rate_for_dte(), which picks the bracket matching the option's own tenor.
#
# ⚠️ THIS IS AN IN-PROCESS CACHE, NOT A TABLE. On Cloud Run each instance holds
# its own _cache dict, and only the instance that served the /jobs/sofr-pull
# trigger gets the fresh values. Others keep theirs until recycled; a cold
# instance starts from DEFAULT_R.
#
# That is accepted rather than fixed because the blast radius is small — short
# rates move slowly, and r affects an option price far less than vol does, so a
# stale-rate instance misprices by well under a tick. Persisting to a table
# would fix it at the cost of a DB read on every pricing call. That is the trade
# if it ever needs making.
#
# NEVER RAISES. Every failure path falls back to the previous cached value (or
# DEFAULT_R) and reports status in the return dict. A FRED outage degrades
# precision; it does not stop the pipeline.

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.config import settings
from core.constants import DEFAULT_R

log = logging.getLogger(__name__)

_FRED_BASE = "https://api.stlouisfed.org/fred/series/observations"

# (fred_series_id, label, max_dte_inclusive)
# Ordered from shortest to longest; last entry has no upper bound.
# The tenor ladder, ordered shortest-first — get_rate_for_dte walks it and takes
# the FIRST bracket whose ceiling the DTE fits under, so order is load-bearing.
# The 9999 sentinel on the last entry makes it an unconditional catch-all.
_TENORS: list[tuple[str, str, int]] = [
    ("SOFR30DAYAVG", "30-day SOFR avg",  30),
    ("DTB3",         "3-month T-bill",   90),
    ("DTB6",         "6-month T-bill",  180),
    ("DTB1YR",       "1-year T-bill",   9999),
]

# Module-level cache — keyed by FRED series ID
# Seeded with DEFAULT_R for every tenor, so pricing works from the first request
# even before any refresh has run — a flat curve at ~4.33% rather than a crash.
_cache: dict[str, float] = {s: DEFAULT_R for s, _, _ in _TENORS}
# Empty until the first successful refresh. get_rates_info() uses its emptiness
# to report whether the served rates are real or the DEFAULT_R fallback — the
# only way to tell from outside.
_cache_date: str = ""
# FRED observation dates per series, distinct from _cache_date: one is when the
# rate was PUBLISHED, the other when it was FETCHED. A stale observation date
# with a current cache date means FRED itself has not updated.
_obs_dates: dict[str, str] = {}


# ── Public accessors ──────────────────────────────────────────────────────────

def get_rate_for_dte(dte: int) -> tuple[float, str]:
    """Return (rate_decimal, tenor_label) for the given days-to-expiry.

    Examples:
        get_rate_for_dte(20)  → (0.0433, "30-day SOFR avg")
        get_rate_for_dte(60)  → (0.0428, "3-month T-bill")
        get_rate_for_dte(120) → (0.0421, "6-month T-bill")
        get_rate_for_dte(200) → (0.0415, "1-year T-bill")
    """
    # First match wins, so the ladder must stay sorted shortest-first.
    for series_id, label, max_dte in _TENORS:
        if dte <= max_dte:
            return _cache[series_id], label
    # Unreachable in practice — 9999 catches everything. Retained as a defence
    # against someone editing the ladder and removing the sentinel.
    # Fallback — should never reach here given 9999 sentinel
    series_id, label, _ = _TENORS[-1]
    return _cache[series_id], label


def get_sofr() -> float:
    """Return the 30-day SOFR average rate (decimal). Backward-compat alias.

    Predates term matching, when one rate served every tenor. Kept so existing
    callers keep working; new code should use get_rate_for_dte() so the rate
    matches the option's actual maturity.
    """
    return _cache["SOFR30DAYAVG"]


def get_rates_info() -> dict:
    """Return all cached rates and metadata — used by /sofr-pull diagnostic response."""
    return {
        "cache_date": _cache_date,
        "source": "FRED" if _cache_date else "DEFAULT_R fallback",
        "rates": {
            label: {
                "rate": _cache[sid],
                "rate_pct": round(_cache[sid] * 100, 4),
                "obs_date": _obs_dates.get(sid, ""),
            }
            for sid, label, _ in _TENORS
        },
    }


# ── Refresh ───────────────────────────────────────────────────────────────────

async def _fetch_series(client: httpx.AsyncClient, series_id: str, api_key: str) -> tuple[str, Optional[float], str]:
    """Fetch the most recent valid observation for one FRED series.

    Returns (series_id, rate_decimal_or_None, obs_date).

    Requests the last 5 observations rather than 1 and walks them for the first
    with a real value: FRED marks holidays and not-yet-published days with a "."
    placeholder, so asking for one row can return no usable rate on a Monday
    after a long weekend. Five is enough to clear any holiday run.

    The /100 converts FRED's percent (4.33) to the decimal (0.0433) every pricing
    function expects.

    Returns None for the rate on ANY failure — network, HTTP status, or a series
    that is all placeholders — and refresh_rates() then leaves that tenor's
    cached value untouched.
    """
    url = (
        f"{_FRED_BASE}?series_id={series_id}&file_type=json"
        f"&sort_order=desc&limit=5&api_key={api_key}"
    )
    try:
        resp = await client.get(url)
        resp.raise_for_status()
        for obs in resp.json().get("observations", []):
            val = obs.get("value", ".")
            if val != ".":
                return series_id, float(val) / 100.0, obs.get("date", "")
    except Exception as exc:
        log.warning("fred_fetch_failed series=%s error=%r", series_id, exc)
    return series_id, None, ""


async def refresh_rates() -> dict:
    """Fetch all four tenor rates from FRED in parallel and update the cache.

    Called by sofr_pull job. Falls back to previous cached values on error.
    """
    global _cache_date, _obs_dates

    # No key configured means no refresh is even attempted; the caller sees
    # "no_api_key" with a 200 and the whole day runs on DEFAULT_R. Worth checking
    # in the sofr_pull job's response rather than assuming success.
    if not settings.fred_api_key:
        log.warning("rate_refresh_skipped: FRED_API_KEY not set")
        return {"status": "no_api_key", **get_rates_info()}

    async with httpx.AsyncClient(timeout=10.0) as client:
        results = await asyncio.gather(
            *[_fetch_series(client, sid, settings.fred_api_key) for sid, _, _ in _TENORS]
        )

    # PER-TENOR partial success: each series updates independently, so one FRED
    # series being down leaves the other three fresh rather than aborting the
    # refresh. A tenor that failed simply keeps its previous cached value.
    updated: list[str] = []
    for series_id, rate, obs_date in results:
        if rate is not None:
            _cache[series_id] = rate
            _obs_dates[series_id] = obs_date
            updated.append(series_id)
            log.info("rate_updated series=%s rate=%.4f obs_date=%s", series_id, rate, obs_date)

    # Only stamped when at least one tenor actually updated, so _cache_date
    # never claims freshness the cache does not have.
    if updated:
        _cache_date = date.today().isoformat()

    return {
        "status": "ok" if updated else "all_failed",
        "updated": updated,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        **get_rates_info(),
    }


# Keep backward compat for sofr_pull job
# Despite the name it refreshes ALL FOUR tenors — jobs/sofr_pull.py still calls
# this alias, and the name predates the term-structure work.
async def refresh_sofr() -> dict:
    return await refresh_rates()
