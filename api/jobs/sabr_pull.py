from __future__ import annotations

# =============================================================================
# jobs/sabr_pull.py
# =============================================================================
# Job 2 — Read vol_surface_snapshots → SABR calibration → upsert sabr_calibrations.
# Cron: 3 13-21 * * 1-5  (3 min after vol_surface_pull, Mon–Fri)
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================
#
# NO SCHWAB FETCH HERE. This job reads what job 1 already stored, which is the
# central design decision of the pipeline: the expensive, rate-limited, failure-
# prone network call happens once, and every model that wants the same surface
# reads it from the database. The 3-minute cron gap is job 1's completion budget.
#
# WHAT IT PRODUCES: (alpha, rho, nu) per DTE slice — a smooth model of the vol
# smile at each expiry, so an IV can be interpolated at a strike with no quote.
# beta is fixed at 0.5 and stored unfitted. See routers/sabr.py for what the
# parameters mean.
#
# RELIABILITY IS THE THEME OF THIS FILE. Nelder-Mead is a local optimizer on a
# non-convex surface, so some slices converge to a corner rather than a fit —
# and a boundary-pinned fit is WORSE than no fit, because it looks like a
# number and gets priced off. Every read path is therefore gated through
# apply_reliability_filter() rather than re-typing the thresholds inline. That
# rule has one definition here (DB side) and one in
# services/sabr_calibrator.is_reliable_fit (in-memory side); both read the same
# two constants, and they must stay in step.
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
    """Calibrate SABR for every tracked ticker from today's stored surface."""
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
            # Selects only the two columns needed. Important on this table:
            # `points` is a wide JSONB blob, and a select("*") here would pull
            # every unread column of the largest table in the database.
            snap = (
                db.table("vol_surface_snapshots")
                .select("spot_price,points")
                .eq("user_id", user_id)
                .eq("ticker", ticker)
                .eq("obs_date", today)
                .limit(1)
                .execute()
            )
            # The expected miss: job 1 has not landed yet, or failed for this
            # ticker. Reported as a named status, not an error — nothing is
            # wrong with THIS job when its input is absent.
            if not snap or not snap.data:
                log.warning("sabr_pull: no vol_surface for ticker=%s", ticker)
                return ticker, "no_vol_surface"

            # Defensive unwrap: PostgREST normally returns a list, but tolerate
            # a bare dict rather than crashing on an indexing error.
            data = snap.data[0] if isinstance(snap.data, list) else snap.data
            spot   = float(data["spot_price"])
            points = data["points"] or []
            if not points:
                return ticker, "no_points"

            # OFFLOAD TO A THREAD. calibrate_snapshot is heavy, fully
            # synchronous scipy work — one Nelder-Mead fit per DTE slice, plus
            # retries on any slice that lands on a bound. Running it inline
            # would block the event loop and serialize the whole run.
            #
            # Note there is no semaphore here, unlike the fetch-based jobs:
            # concurrency is bounded instead by asyncio's default thread-pool
            # size, and the constraint is local CPU rather than an upstream
            # rate limit.
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

    Takes and returns a query BUILDER, so it composes: filters can be applied
    before it and ordering/pagination after, as fetch_nu_history does below.
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

    WHAT ν HISTORY IS FOR: ν is vol-of-vol, and its own percentile rank is the
    vvol_rank/vvol_percentile reported by IV analytics — "is volatility itself
    unusually jumpy right now?". That requires a trailing series of comparable
    ν values, which is exactly what this builds.

    dte_target=30 anchors the series to a roughly constant tenor. Without it,
    comparing today's 7-day ν against last month's 90-day ν would measure the
    term structure rather than any change over time.
    """
    cutoff = (date.today() - timedelta(days=365)).isoformat()
    # Paginate: a year of slices (≥1 row per DTE per day) exceeds the Supabase
    # 1000-row response cap, which would silently drop the most recent dates.
    #
    # The lambda is required by fetch_all's contract — PostgREST builders are
    # single-use, so each page needs a freshly-built query. The ordering is on
    # (obs_date, dte), which is unique per user+ticker and therefore a stable
    # pagination key.
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

    # Regroup by date so each day contributes exactly ONE ν — the slice nearest
    # dte_target. Without this the series would be dominated by however many
    # expirations happened to be listed that day.
    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_date[r["obs_date"]].append(r)

    series: list[float] = []
    today_iso = date.today().isoformat()
    for obs_date in sorted(by_date):
        # Normalize to string for safe comparison regardless of Supabase return type
        #
        # TODAY IS EXCLUDED so the caller can rank today's ν against a window
        # that does not already contain it — self-inclusion would compress every
        # percentile toward the middle. The [:10] slice tolerates a full
        # timestamp as well as a bare date string.
        if str(obs_date)[:10] >= today_iso:
            continue  # exclude today and any future-dated rows
        best = min(by_date[obs_date], key=lambda s: abs(s["dte"] - dte_target))
        if best["nu"] is not None:
            series.append(float(best["nu"]))
    return series


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices, user_id: str) -> None:
    """Write every fitted slice in ONE batched upsert.

    Note the conflict key includes `dte`, so unlike the surface snapshot this
    is one row PER SLICE per day — a ticker with 15 expirations writes 15 rows,
    each overwritten by the next hourly run.

    Unreliable fits are stored, not discarded. That is intentional: rmse and
    n_points are persisted alongside the parameters so the gate can be applied
    at READ time by apply_reliability_filter(). Keeping them makes it possible
    to see later that a slice was attempted and failed, rather than confusing
    a bad fit with a missing expiry.
    """
    rows = [
        {
            "user_id":   user_id,
            "ticker":    ticker,
            "obs_date":  today,
            "dte":       s.dte,
            "alpha":     s.alpha,
            "beta":      s.beta,    # always SABR_BETA (0.5) — stored, not fitted
            "rho":       s.rho,     # skew / tilt
            "nu":        s.nu,      # vol-of-vol / curvature; see fetch_nu_history
            # The two reliability fields. Every consumer gates on these.
            "rmse":      s.rmse,
            "n_points":  s.n_points,   # quotes the model could actually price
        }
        for s in slices
    ]
    db.table("sabr_calibrations").upsert(
        rows,
        on_conflict="user_id,ticker,obs_date,dte",
    ).execute()
