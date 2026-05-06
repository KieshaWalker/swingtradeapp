from __future__ import annotations

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
_TENORS: list[tuple[str, str, int]] = [
    ("SOFR30DAYAVG", "30-day SOFR avg",  30),
    ("DTB3",         "3-month T-bill",   90),
    ("DTB6",         "6-month T-bill",  180),
    ("DTB1YR",       "1-year T-bill",   9999),
]

# Module-level cache — keyed by FRED series ID
_cache: dict[str, float] = {s: DEFAULT_R for s, _, _ in _TENORS}
_cache_date: str = ""
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
    for series_id, label, max_dte in _TENORS:
        if dte <= max_dte:
            return _cache[series_id], label
    # Fallback — should never reach here given 9999 sentinel
    series_id, label, _ = _TENORS[-1]
    return _cache[series_id], label


def get_sofr() -> float:
    """Return the 30-day SOFR average rate (decimal). Backward-compat alias."""
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

async def _fetch_series(client: httpx.AsyncClient, series_id: str, api_key: str) -> tuple[str, float | None, str]:
    """Fetch the most recent valid observation for one FRED series.

    Returns (series_id, rate_decimal_or_None, obs_date).
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

    if not settings.fred_api_key:
        log.warning("rate_refresh_skipped: FRED_API_KEY not set")
        return {"status": "no_api_key", **get_rates_info()}

    async with httpx.AsyncClient(timeout=10.0) as client:
        results = await asyncio.gather(
            *[_fetch_series(client, sid, settings.fred_api_key) for sid, _, _ in _TENORS]
        )

    updated: list[str] = []
    for series_id, rate, obs_date in results:
        if rate is not None:
            _cache[series_id] = rate
            _obs_dates[series_id] = obs_date
            updated.append(series_id)
            log.info("rate_updated series=%s rate=%.4f obs_date=%s", series_id, rate, obs_date)

    if updated:
        _cache_date = date.today().isoformat()

    return {
        "status": "ok" if updated else "all_failed",
        "updated": updated,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        **get_rates_info(),
    }


# Keep backward compat for sofr_pull job
async def refresh_sofr() -> dict:
    return await refresh_rates()
