from __future__ import annotations

# =============================================================================
# jobs/heston_pull.py
# =============================================================================
# Job 3 — Read vol_surface_snapshots → Heston calibration → upsert heston_calibrations.
# Cron: 6 13-21 * * 1-5 (batch 1) / 20 13-21 * * 1-5 (batch 2), Mon–Fri
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================

import asyncio
import logging
from datetime import date

from core.supabase_client import get_supabase
from jobs.common import get_tickers, market_session_guard
from services.heston_calibrator import calibrate_heston

log = logging.getLogger(__name__)

# Cooperative calibration deadline. Slightly under the asyncio.wait_for backstop
# so the optimizer stops itself and the worker thread actually exits — wait_for
# alone abandons the thread, which keeps burning the single Cloud Run CPU.
_CALIBRATION_DEADLINE_S = 170.0
_CALIBRATION_BACKSTOP_S = 180.0


async def run_heston_pull(batch: int = 1) -> dict:
    skip = market_session_guard()
    if skip:
        log.info("heston_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    today = date.today().isoformat()
    all_rows = get_tickers(db)
    # Deterministic first-letter split (A–M / N–Z) so a watchlist change between
    # the batch-1 (:06) and batch-2 (:20) runs can't skip a boundary ticker.
    rows = [r for r in all_rows if (r["ticker"][:1].upper() <= "M") == (batch == 1)]
    rows.sort(key=lambda r: r["ticker"])

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

            # Calibration with cooperative deadline + hard backstop per ticker
            try:
                result = await asyncio.wait_for(
                    asyncio.to_thread(
                        calibrate_heston,
                        surface_points=points,
                        spot=spot,
                        deadline_s=_CALIBRATION_DEADLINE_S,
                    ),
                    timeout=_CALIBRATION_BACKSTOP_S,
                )
            except asyncio.TimeoutError:
                log.warning("heston_calibration_timeout ticker=%s — writing sentinel row", ticker)
                _upsert_timeout_sentinel(db, ticker, today, user_id)
                return ticker, "calibration_timeout"
            
            if result is None:
                return ticker, "no_result"

            _upsert_heston_calibration(db, ticker, today, result, user_id)
            log.info(
                "heston_ok ticker=%s rmse_iv=%.4f n=%d converged=%s",
                ticker, result.rmse_iv, result.n_points, result.converged,
            )
            return ticker, "ok"
        except Exception as exc:
            log.error("heston_failed ticker=%s error=%r", ticker, exc, exc_info=True)
            return ticker, f"error:{exc!r}"

    # Limit concurrency to 3 tickers at a time to prevent timeout
    semaphore = asyncio.Semaphore(3)
    async def _process_limited(row: dict) -> tuple[str, str]:
        async with semaphore:
            return await _process(row)
    
    results = dict(await asyncio.gather(*[_process_limited(r) for r in rows]))
    return {"status": "complete", "tickers": results, "date": today}


def _upsert_timeout_sentinel(db, ticker: str, today: str, user_id: str) -> None:
    """Write a sentinel row so downstream can detect a timed-out calibration.

    All numeric params are NULL; rmse_iv=NULL causes _fetch_heston_params to reject
    this row (rmse_iv is None → return None), preventing yesterday's stale params
    from being served as if they were fresh.

    Skipped if a successful calibration (rmse_iv IS NOT NULL) already exists for
    today — the cron runs hourly, so a timeout on run N must not overwrite a
    successful result from run N-1.
    """
    try:
        existing = (
            db.table("heston_calibrations")
            .select("rmse_iv")
            .eq("user_id", user_id)
            .eq("ticker", ticker)
            .eq("obs_date", today)
            .limit(1)
            .execute()
        )
        rows = existing.data or []
        if rows and rows[0].get("rmse_iv") is not None:
            log.info(
                "heston_sentinel_skipped ticker=%s — successful calibration already exists for today",
                ticker,
            )
            return
        db.table("heston_calibrations").upsert(
            {
                "user_id":   user_id,
                "ticker":    ticker,
                "obs_date":  today,
                "kappa":     None,
                "theta":     None,
                "xi":        None,
                "rho":       None,
                "v0":        None,
                "rmse_iv":   None,
                "n_points":  None,
                "converged": False,
            },
            on_conflict="user_id,ticker,obs_date",
        ).execute()
    except Exception as exc:
        log.error("heston_sentinel_upsert_failed ticker=%s error=%r", ticker, exc)


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
        on_conflict="user_id,ticker,obs_date",
    ).execute()
