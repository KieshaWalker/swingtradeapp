from __future__ import annotations

# =============================================================================
# jobs/vol_surface_pull.py
# =============================================================================
# Job 1 — Fetch Schwab options chain → upsert vol_surface_snapshots.
# Cron: 0 * * * 1-5  (top of every hour, Mon–Fri)
#
# All downstream jobs (sabr, heston, iv, greek_grid, greek_snapshots, regime)
# depend on data written here — run this first.
# =============================================================================

import asyncio
import logging
from datetime import datetime, timezone
from datetime import date

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import get_tickers, fetch_schwab_chain, _fgt0, _fne0, _fany, _igt0

log = logging.getLogger(__name__)


async def run_vol_surface_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("vol_surface_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("vol_surface_pull: no tickers")
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
                    log.warning("zero_spot ticker=%s", ticker)
                    return ticker, "zero_spot"
                points = _chain_to_vol_points(chain, spot)
                if not points:
                    return ticker, "no_points"
                _upsert_vol_surface(db, ticker, today, spot, points, user_id)
                log.info("vol_surface_ok ticker=%s points=%d", ticker, len(points))
                return ticker, "ok"
            except Exception as exc:
                log.error("vol_surface_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


def _chain_to_vol_points(chain: dict, spot: float) -> list[dict]:
    """Convert Schwab callExpDateMap/putExpDateMap to vol surface points.
    Matches VolSurfaceParser.fromChain() field set exactly.
    """
    expirations = parse_expirations(chain)
    points = []
    for exp in expirations:
        dte = exp["dte"]
        call_by_strike: dict[float, dict] = {}
        put_by_strike:  dict[float, dict] = {}

        for c in exp["calls"]:
            iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
            if iv > 0:
                call_by_strike[float(c["strikePrice"])] = c

        for p in exp["puts"]:
            iv = float(p.get("volatility") or p.get("impliedVolatility") or 0)
            if iv > 0:
                put_by_strike[float(p["strikePrice"])] = p

        for strike in sorted(set(call_by_strike) | set(put_by_strike)):
            c = call_by_strike.get(strike)
            p = put_by_strike.get(strike)

            call_iv_pct = float(c.get("volatility") or c.get("impliedVolatility") or 0) if c else 0.0
            put_iv_pct  = float(p.get("volatility") or p.get("impliedVolatility") or 0) if p else 0.0

            call_delta = _fany(c, "delta")
            put_delta  = _fany(p, "delta")

            call_prob_itm = max(0.0, min(1.0, call_delta)) if call_delta is not None and call_delta > 0 else None
            put_prob_itm  = max(0.0, min(1.0, abs(put_delta))) if put_delta is not None and put_delta < 0 else None

            row: dict = {
                "strike": strike,
                "dte":    dte,
                "call_iv": call_iv_pct / 100 if call_iv_pct > 0 else None,
                "put_iv":  put_iv_pct  / 100 if put_iv_pct  > 0 else None,
                "call_vol": _igt0(c, "totalVolume"),
                "put_vol":  _igt0(p, "totalVolume"),
                "call_oi":  _igt0(c, "openInterest"),
                "put_oi":   _igt0(p, "openInterest"),
                "call_delta": call_delta,
                "put_delta":  put_delta,
                "call_gamma": _fne0(c, "gamma"),
                "put_gamma":  _fne0(p, "gamma"),
                "call_theta": _fne0(c, "theta"),
                "put_theta":  _fne0(p, "theta"),
                "call_vega":  _fne0(c, "vega"),
                "put_vega":   _fne0(p, "vega"),
                "call_rho":   _fne0(c, "rho"),
                "put_rho":    _fne0(p, "rho"),
                "call_bid":       _fgt0(c, "bid"),
                "call_ask":       _fgt0(c, "ask"),
                "call_mark":      _fgt0(c, "mark"),
                "call_last":      _fgt0(c, "last"),
                "call_theo":      _fgt0(c, "theoreticalOptionValue"),
                "call_intrinsic": _fgt0(c, "intrinsicValue"),
                "call_extrinsic": _fgt0(c, "timeValue"),
                "call_high":      _fgt0(c, "highPrice"),
                "call_low":       _fgt0(c, "lowPrice"),
                "put_bid":        _fgt0(p, "bid"),
                "put_ask":        _fgt0(p, "ask"),
                "put_mark":       _fgt0(p, "mark"),
                "put_last":       _fgt0(p, "last"),
                "put_theo":       _fgt0(p, "theoreticalOptionValue"),
                "put_intrinsic":  _fgt0(p, "intrinsicValue"),
                "put_extrinsic":  _fgt0(p, "timeValue"),
                "put_high":       _fgt0(p, "highPrice"),
                "put_low":        _fgt0(p, "lowPrice"),
                "call_bid_size": _igt0(c, "bidSize"),
                "call_ask_size": _igt0(c, "askSize"),
                "put_bid_size":  _igt0(p, "bidSize"),
                "put_ask_size":  _igt0(p, "askSize"),
                "call_prob_itm": call_prob_itm,
                "call_prob_otm": 1.0 - call_prob_itm if call_prob_itm is not None else None,
                "put_prob_itm":  put_prob_itm,
                "put_prob_otm":  1.0 - put_prob_itm  if put_prob_itm  is not None else None,
            }
            points.append({k: v for k, v in row.items() if v is not None})

    return points


def _upsert_vol_surface(
    db, ticker: str, today: str, spot: float, points: list[dict], user_id: str
) -> None:
    db.table("vol_surface_snapshots").upsert(
        {
            "user_id":    user_id,
            "ticker":     ticker,
            "obs_date":   today,
            "spot_price": spot,
            "points":     points,
            "parsed_at":  datetime.now(timezone.utc).isoformat(),
        },
        on_conflict="user_id,ticker,obs_date",
    ).execute()
