from __future__ import annotations

# =============================================================================
# jobs/heston_pull.py
# =============================================================================
# Job 3 — Read vol_surface_snapshots → Heston calibration → upsert heston_calibrations.
# Cron: 6 * * * 1-5  (6 min after vol_surface_pull, Mon–Fri)
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================

import asyncio
import logging
from datetime import date, datetime, timezone

from core.supabase_client import get_supabase
from jobs.common import get_tickers
from services.heston_calibrator import calibrate_heston

log = logging.getLogger(__name__)


async def run_heston_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("heston_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("heston_pull: no tickers")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async def _process(row: dict) -> tuple[str, str]:
        ticker  = row["ticker"]
        user_id = row["user_id"]
        try:
            snap = (
                db.table("vol_surface_snapshots")
                .select("spot_price,points")
                .eq("user_id", user_id)
                .eq("ticker", ticker)
                .eq("obs_date", today)
                .limit(1)
                .execute()
            )
            if not snap or not snap.data:
                log.warning("heston_pull: no vol_surface for ticker=%s", ticker)
                return ticker, "no_vol_surface"

            data = snap.data[0] if isinstance(snap.data, list) else snap.data
            spot   = float(data["spot_price"])
            points = data["points"] or []
            if not points:
                return ticker, "no_points"

            result = await asyncio.to_thread(calibrate_heston, surface_points=points, spot=spot)
            if result is None:
                return ticker, "no_result"

            if not result.is_reliable:
                log.warning(
                    "heston_unreliable ticker=%s rmse_iv=%.4f n=%d",
                    ticker, result.rmse_iv, result.n_points,
                )
                return ticker, "unreliable"

            _upsert_heston_calibration(db, ticker, today, result, user_id)
            log.info(
                "heston_ok ticker=%s rmse_iv=%.4f n=%d converged=%s",
                ticker, result.rmse_iv, result.n_points, result.converged,
            )
            return ticker, "ok"
        except Exception as exc:
            log.error("heston_failed ticker=%s error=%r", ticker, exc, exc_info=True)
            return ticker, f"error:{exc!r}"

    results = dict(await asyncio.gather(*[_process(r) for r in rows]))
    return {"status": "complete", "tickers": results, "date": today}


def _upsert_heston_calibration(db, ticker: str, today: str, result, user_id: str) -> None:
    p = result.params
    db.table("heston_calibrations").upsert(
        {
            "user_id":   user_id,
            "ticker":    ticker,
            "obs_date":  today,
            "kappa":     float(p.kappa),
            "theta":     float(p.theta),
            "xi":        float(p.xi),
            "rho":       float(p.rho),
            "v0":        float(p.V0),
            "rmse_iv":   float(result.rmse_iv) if result.rmse_iv is not None else None,
            "n_points":  int(result.n_points) if result.n_points is not None else None,
            "converged": bool(result.converged) if result.converged is not None else None,
        },
        on_conflict="heston_calibrations_user_id_ticker_obs_date_key",
    ).execute()
