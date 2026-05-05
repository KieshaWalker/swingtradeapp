from __future__ import annotations

# =============================================================================
# jobs/iv_pull.py
# =============================================================================
# Job 4 — Fetch chain → IV analytics + vvol rank → upsert iv_snapshots.
# Cron: 9 * * * 1-5  (9 min after vol_surface_pull, Mon–Fri)
#
# Fetches the raw Schwab chain (needed by iv_analyse for GEX/RND computation).
# Reads today's sabr_calibrations for vvol rank (written by sabr_pull).
# =============================================================================

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_chain
from jobs.sabr_pull import fetch_nu_history
from services.iv_analytics import analyse as iv_analyse
from services.vvol_analytics import compute as vvol_compute

log = logging.getLogger(__name__)


async def run_iv_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("iv_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("iv_pull: no tickers")
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

                history    = _fetch_iv_history(db, ticker)
                iv_result  = iv_analyse(chain, history)

                # vvol rank uses the SABR ν series written by sabr_pull
                vvol = None
                slices = _fetch_today_sabr(db, ticker, user_id, today)
                if slices:
                    nu_history = fetch_nu_history(db, ticker, user_id)
                    if nu_history:
                        atm_slice = min(slices, key=lambda s: abs(s["dte"] - 30))
                        if atm_slice["nu"] is not None:
                            vvol = vvol_compute(float(atm_slice["nu"]), nu_history)

                _upsert_iv_snapshot(db, ticker, today, iv_result, spot, vvol)
                log.info("iv_ok ticker=%s atm_iv=%.3f", ticker, iv_result.current_iv or 0)
                return ticker, "ok"
            except Exception as exc:
                log.error("iv_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


def _fetch_iv_history(db, ticker: str) -> list[dict]:
    resp = (
        db.table("iv_snapshots")
        .select("atm_iv,skew,total_gex,date")
        .eq("ticker", ticker)
        .order("date", desc=False)
        .limit(252)
        .execute()
    )
    return resp.data or []


def _fetch_today_sabr(db, ticker: str, user_id: str, today: str) -> list[dict]:
    resp = (
        db.table("sabr_calibrations")
        .select("dte,nu")
        .eq("user_id", user_id)
        .eq("ticker", ticker)
        .eq("obs_date", today)
        .execute()
    )
    return resp.data or []


def _upsert_iv_snapshot(db, ticker: str, today: str, iv_result, spot: float, vvol=None) -> None:
    gex_by_strike = [
        {"strike": g.strike, "dealer_gex": g.dealer_gex(spot),
         "call_oi": g.call_oi, "put_oi": g.put_oi}
        for g in iv_result.gex_strikes
    ]
    row: dict = {
        "ticker":                 ticker,
        "date":                   today,
        "atm_iv":                 iv_result.current_iv,
        "skew":                   iv_result.skew,
        "gex_by_strike":          gex_by_strike,
        "total_gex":              iv_result.total_gex,
        "max_gex_strike":         iv_result.max_gex_strike,
        "put_call_ratio":         iv_result.put_call_ratio,
        "underlying_price":       spot,
        "iv_rank":                iv_result.iv_rank,
        "iv_percentile":          iv_result.iv_percentile,
        "iv_rating":              iv_result.rating.value if iv_result.rating else None,
        "gamma_regime":           iv_result.gamma_regime.value if iv_result.gamma_regime else None,
        "gamma_slope":            iv_result.gamma_slope.value if iv_result.gamma_slope else None,
        "iv_gex_signal":          iv_result.iv_gex_signal.value if iv_result.iv_gex_signal else None,
        "zero_gamma_level":       iv_result.zero_gamma_level,
        "spot_to_zero_gamma_pct": iv_result.spot_to_zero_gamma_pct,
        "delta_gex":              iv_result.delta_gex,
        "put_wall_density":       iv_result.put_wall_density,
        "vanna_regime":           iv_result.vanna_regime.value,
        "total_vex":              iv_result.total_vex,
        "total_cex":              iv_result.total_cex,
        "total_volga":            iv_result.total_volga,
        "max_vex_strike":         iv_result.max_vex_strike,
        "skew_avg_52w":           iv_result.skew_avg_52w,
        "skew_z_score":           iv_result.skew_z_score,
        "rnd":                    [s.to_dict() for s in iv_result.rnd] or None,
        # Fields read by regime_pull
        "spot_to_vt_pct":         iv_result.spot_to_vt_pct,
        "gex_0dte":               iv_result.gex_0dte,
        "gex_0dte_pct":           iv_result.gex_0dte_pct,
    }
    if vvol is not None:
        row.update({
            "vvol_nu":         vvol.nu_current,
            "vvol_rank":       vvol.vvol_rank,
            "vvol_percentile": vvol.vvol_percentile,
            "vvol_rating":     vvol.vvol_rating,
            "vvol_trend":      vvol.nu_trend,
        })
    db.table("iv_snapshots").upsert(row, on_conflict="ticker,date").execute()
