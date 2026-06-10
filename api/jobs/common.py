from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/common.py
# =============================================================================
# Shared helpers used by every pipeline job.
# =============================================================================

import logging
from datetime import datetime, time, timezone

import httpx
import pytz

from core.config import settings

log = logging.getLogger(__name__)

_ET = pytz.timezone("America/New_York")
_MARKET_OPEN = time(9, 30)
# Allow the 4 PM ET close-capture cycle: the staggered jobs of the cycle that
# starts at 16:00 ET keep firing until ~16:20 ET (heston batch 2).
_MARKET_LAST = time(16, 30)


def market_session_guard() -> Optional[str]:
    """Return a skip reason when outside US equity market hours (ET), else None.

    The hourly pipeline crons fire around the clock in UTC. Without this guard
    the jobs pull stale after-hours chains overnight and — between 00:00 and
    ~04:00 UTC — write rows under the *next* UTC date using the prior session's
    data (permanent pollution on market holidays).

    Known limitation: market holidays that fall Mon–Fri still run.
    """
    now_et = datetime.now(timezone.utc).astimezone(_ET)
    if now_et.weekday() >= 5:
        return "weekend"
    t = now_et.time()
    if t < _MARKET_OPEN:
        return "before_open"
    if t > _MARKET_LAST:
        return "after_close"
    return None


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {settings.supabase_service_key}",
        "Content-Type": "application/json",
    }


def get_tickers(db) -> list[dict]:
    """Return unique (ticker, user_id) rows from watched_tickers + open trades."""
    rows = (db.table("watched_tickers").select("ticker,user_id").execute()).data or []
    trades = (
        db.table("trades").select("ticker,user_id").eq("status", "open").execute()
    ).data or []
    seen = {(r["ticker"], r["user_id"]) for r in rows}
    for r in trades:
        key = (r["ticker"], r["user_id"])
        if key not in seen:
            rows.append(r)
            seen.add(key)
    return rows


async def fetch_schwab_chain(
    client: httpx.AsyncClient,
    ticker: str,
    strike_count: int = 40,
    expiration_date: Optional[str] = None,
) -> Optional[dict]:
    """Fetch options chain via the Supabase edge function. Returns None on failure.

    Pass expiration_date ("YYYY-MM-DD") to fetch a single expiry with a higher
    strike_count without blowing the Apigee payload limit.
    """
    body: dict = {"symbol": ticker, "contractType": "ALL", "strikeCount": strike_count}
    if expiration_date:
        body["expirationDate"] = expiration_date
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-chains",
            json=body,
            headers=_headers(),
            timeout=60.0,
        )
        if resp.status_code != 200:
            log.error("chain_fetch_failed ticker=%s status=%s", ticker, resp.status_code)
            return None
        return resp.json()
    except Exception as exc:
        log.error("chain_fetch_error ticker=%s error=%r", ticker, exc)
        return None


async def fetch_schwab_closes(
    client: httpx.AsyncClient, ticker: str, days: int = 65
) -> tuple[list[float], list[float]]:
    """Return (closes, volumes) oldest→newest via the pricehistory edge function."""
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={"symbol": ticker, "days": days},
            headers=_headers(),
            timeout=30.0,
        )
        if resp.status_code != 200:
            log.warning("pricehistory_failed ticker=%s status=%s", ticker, resp.status_code)
            return [], []
        data = resp.json()
        return data.get("closes", []), data.get("volumes", [])
    except Exception as exc:
        log.warning("pricehistory_error ticker=%s error=%r", ticker, exc)
        return [], []


# ── Scalar field extractors ───────────────────────────────────────────────────

def _fgt0(contract:Optional[dict], key: str) ->Optional[float]:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f > 0 else None
    except (TypeError, ValueError):
        return None


def _fne0(contract:Optional[dict], key: str) ->Optional[float]:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f != 0 else None
    except (TypeError, ValueError):
        return None


def _fany(contract:Optional[dict], key: str) ->Optional[float]:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _igt0(contract:Optional[dict], key: str) ->Optional[int]:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        i = int(v)
        return i if i > 0 else None
    except (TypeError, ValueError):
        return None


def _pct_to_dec(value) ->Optional[float]:
    if value is None:
        return None
    try:
        return float(value) / 100.0
    except (TypeError, ValueError):
        return None


def _atm_contract(contracts: list[dict]) ->Optional[dict]:
    if not contracts:
        return None
    with_delta = [c for c in contracts if c.get("delta") and c["delta"] != 0]
    if not with_delta:
        return None
    return min(with_delta, key=lambda c: abs(abs(c["delta"]) - 0.50))
