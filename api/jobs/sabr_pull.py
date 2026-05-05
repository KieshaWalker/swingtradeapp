from __future__ import annotations

# =============================================================================
# jobs/sabr_pull.py
# =============================================================================
# Job 2 — Read vol_surface_snapshots → SABR calibration → upsert sabr_calibrations.
# Cron: 3 * * * 1-5  (3 min after vol_surface_pull, Mon–Fri)
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================

import asyncio
import logging
from collections import defaultdict
from datetime import date, timedelta, datetime, timezone

from core.supabase_client import get_supabase
from jobs.common import get_tickers
from services.sabr_calibrator import calibrate_snapshot

log = logging.getLogger(__name__)


async def run_sabr_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("sabr_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("sabr_pull: no tickers")
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
                log.warning("sabr_pull: no vol_surface for ticker=%s", ticker)
                return ticker, "no_vol_surface"

            data = snap.data[0] if isinstance(snap.data, list) else snap.data
            spot   = float(data["spot_price"])
            points = data["points"] or []
            if not points:
                return ticker, "no_points"

            slices = await asyncio.to_thread(calibrate_snapshot, spot=spot, points=points)
            if not slices:
                return ticker, "no_slices"

            _upsert_sabr_calibrations(db, ticker, today, slices, user_id)
            log.info("sabr_ok ticker=%s slices=%d", ticker, len(slices))
            return ticker, "ok"
        except Exception as exc:
            log.error("sabr_failed ticker=%s error=%r", ticker, exc, exc_info=True)
            return ticker, f"error:{exc!r}"

    results = dict(await asyncio.gather(*[_process(r) for r in rows]))
    return {"status": "complete", "tickers": results, "date": today}


def fetch_nu_history(db, ticker: str, user_id: str, dte_target: int = 30) -> list[float]:
    """Return a time-ordered series of calibrated SABR ν values for the DTE
    slice closest to dte_target (prior observations only — today excluded).
    Shared by iv_pull.py.
    """
    cutoff = (date.today() - timedelta(days=365)).isoformat()
    resp = (
        db.table("sabr_calibrations")
        .select("obs_date,dte,nu")
        .eq("user_id", user_id)
        .eq("ticker", ticker)
        .gte("obs_date", cutoff)
        .gte("n_points", 5)
        .order("obs_date", desc=False)
        .execute()
    )
    rows = resp.data or []
    if not rows:
        return []

    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_date[r["obs_date"]].append(r)

    series: list[float] = []
    for obs_date in sorted(by_date):
        if obs_date == date.today().isoformat():
            continue  # exclude today
        best = min(by_date[obs_date], key=lambda s: abs(s["dte"] - dte_target))
        if best["nu"] is not None:
            series.append(float(best["nu"]))
    return series


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices, user_id: str) -> None:
    for s in slices:
        db.table("sabr_calibrations").upsert(
            {
                "user_id":   user_id,
                "ticker":    ticker,
                "obs_date":  today,
                "dte":       s.dte,
                "alpha":     s.alpha,
                "beta":      s.beta,
                "rho":       s.rho,
                "nu":        s.nu,
                "rmse":      s.rmse,
                "n_points":  s.n_points,
            },
            on_conflict="user_id,ticker,obs_date,dte",
        ).execute()
