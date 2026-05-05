from __future__ import annotations

# =============================================================================
# jobs/common.py
# =============================================================================
# Shared helpers used by every pipeline job.
# =============================================================================

import logging

import httpx

from core.config import settings

log = logging.getLogger(__name__)


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
    client: httpx.AsyncClient, ticker: str, strike_count: int = 40
) -> dict | None:
    """Fetch options chain via the Supabase edge function. Returns None on failure."""
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-chains",
            json={"symbol": ticker, "contractType": "ALL", "strikeCount": strike_count},
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

def _fgt0(contract: dict | None, key: str) -> float | None:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f > 0 else None
    except (TypeError, ValueError):
        return None


def _fne0(contract: dict | None, key: str) -> float | None:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f != 0 else None
    except (TypeError, ValueError):
        return None


def _fany(contract: dict | None, key: str) -> float | None:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _igt0(contract: dict | None, key: str) -> int | None:
    if contract is None:
        return None
    v = contract.get(key)
    try:
        i = int(v)
        return i if i > 0 else None
    except (TypeError, ValueError):
        return None


def _pct_to_dec(value) -> float | None:
    if value is None:
        return None
    try:
        return float(value) / 100.0
    except (TypeError, ValueError):
        return None


def _atm_contract(contracts: list[dict]) -> dict | None:
    if not contracts:
        return None
    with_delta = [c for c in contracts if c.get("delta") and c["delta"] != 0]
    if not with_delta:
        return None
    return min(with_delta, key=lambda c: abs(abs(c["delta"]) - 0.50))
