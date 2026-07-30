from __future__ import annotations

# =============================================================================
# jobs/sabr_pull.py
# =============================================================================
# Job 2 — Read vol_surface_snapshots → SABR calibration → upsert sabr_calibrations.
# Cron: 3 13-21 * * 1-5  (3 min after vol_surface_pull, Mon–Fri)
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================

import asyncio
import logging
from collections import defaultdict
from datetime import date, timedelta

from core.constants import SABR_RELIABLE_RMSE, SABR_RELIABLE_MIN_POINTS
from core.supabase_client import get_supabase, fetch_all
from jobs.common import get_tickers, market_session_guard
from services.sabr_calibrator import calibrate_snapshot

log = logging.getLogger(__name__)


async def run_sabr_pull() -> dict:
    skip = market_session_guard()
    if skip:
        log.info("sabr_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

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


def apply_reliability_filter(query):
    """Restrict a sabr_calibrations query to slices that track the surface.

    The DB-side counterpart to services.sabr_calibrator.is_reliable_fit; both
    read SABR_RELIABLE_RMSE / SABR_RELIABLE_MIN_POINTS so the rule has one
    definition. Every read path must go through this rather than re-typing the
    two comparisons — a boundary-pinned fit reaching a consumer is worse than
    no fit, because it is priced off silently.

    `.lt` excludes NULL rmse by design: an unscored fit is not a usable one.
    """
    return (
        query
        .lt("rmse", SABR_RELIABLE_RMSE)
        .gte("n_points", SABR_RELIABLE_MIN_POINTS)
    )


def fetch_nu_history(db, ticker: str, user_id: str, dte_target: int = 30) -> list[float]:
    """Return a time-ordered series of calibrated SABR ν values for the DTE
    slice closest to dte_target (prior observations only — today excluded).
    Shared by iv_pull.py.

    Filtered on the same reliability bar as iv_pull._fetch_today_sabr. The two
    must agree: gating only the current ν would rank it against a window that
    still contains boundary-pinned fits, which is worse than gating neither.
    """
    cutoff = (date.today() - timedelta(days=365)).isoformat()
    # Paginate: a year of slices (≥1 row per DTE per day) exceeds the Supabase
    # 1000-row response cap, which would silently drop the most recent dates.
    rows = fetch_all(
        lambda: (
            apply_reliability_filter(
                db.table("sabr_calibrations")
                .select("obs_date,dte,nu")
                .eq("user_id", user_id)
                .eq("ticker", ticker)
                .gte("obs_date", cutoff)
            )
            .order("obs_date", desc=False)
            .order("dte", desc=False)
        )
    )
    if not rows:
        return []

    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_date[r["obs_date"]].append(r)

    series: list[float] = []
    today_iso = date.today().isoformat()
    for obs_date in sorted(by_date):
        # Normalize to string for safe comparison regardless of Supabase return type
        if str(obs_date)[:10] >= today_iso:
            continue  # exclude today and any future-dated rows
        best = min(by_date[obs_date], key=lambda s: abs(s["dte"] - dte_target))
        if best["nu"] is not None:
            series.append(float(best["nu"]))
    return series


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices, user_id: str) -> None:
    rows = [
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
        }
        for s in slices
    ]
    db.table("sabr_calibrations").upsert(
        rows,
        on_conflict="user_id,ticker,obs_date,dte",
    ).execute()
