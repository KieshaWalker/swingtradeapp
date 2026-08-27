from __future__ import annotations

# =============================================================================
# jobs/heston_pull.py
# =============================================================================
# Job 3 — Read vol_surface_snapshots → Heston calibration → upsert heston_calibrations.
# Cron: 6 13-21 * * 1-5 (batch 1) / 20 13-21 * * 1-5 (batch 2), Mon–Fri
#
# Reads today's vol_surface_snapshots.points written by vol_surface_pull.
# =============================================================================
#
# THE HEAVIEST JOB IN THE PIPELINE. Heston fits FIVE parameters (kappa, theta,
# xi, rho, V0) GLOBALLY across the entire surface at once — every strike and
# every expiry share one parameter set — using differential evolution followed
# by Nelder-Mead refinement. SABR, by contrast, fits three parameters
# independently per DTE slice. That difference is why this job needs batching,
# deadlines and a timeout sentinel while sabr_pull needs none of them.
#
# THREE DEFENCES AGAINST THE RUNTIME, each solving a different failure:
#
#   1. ALPHABETICAL BATCHING (A-M at :06, N-Z at :20). A whole-universe
#      calibration exceeds the Cloud Run request timeout outright.
#
#   2. COOPERATIVE DEADLINE + HARD BACKSTOP (see the constants below). The
#      optimizer is told to stop at 170s so its worker thread actually exits;
#      asyncio.wait_for at 180s is only the backstop. Order matters — see the
#      note on the constants.
#
#   3. TIMEOUT SENTINEL ROW. A timed-out ticker writes an all-NULL row rather
#      than nothing, so yesterday's parameters cannot be served as if fresh.
#
# Scheduler 502s on this endpoint are EXPECTED and cosmetic: the job completes
# and the rows land, the HTTP response just outlives the scheduler's patience.
# Confirm a run by querying heston_calibrations for the obs_date, not by the
# scheduler's reported status.

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
#
# THE 10-SECOND GAP IS THE WHOLE POINT. asyncio.wait_for cannot kill a thread —
# it only stops AWAITING one. A thread cancelled that way keeps running the
# optimizer to completion, invisibly, still consuming the single Cloud Run CPU
# that every remaining ticker needs. So the deadline is passed INTO
# calibrate_heston, which checks it between iterations and returns on its own.
# wait_for is the backstop for the case where even that fails.
#
# If these are ever retuned, the deadline must stay strictly below the backstop,
# and the backstop below the Cloud Run request timeout.
_CALIBRATION_DEADLINE_S = 170.0
_CALIBRATION_BACKSTOP_S = 180.0


async def run_heston_pull(batch: int = 1) -> dict:
    """Calibrate Heston for one alphabetical half of the ticker universe.

    batch=1 is A-M, batch=2 is N-Z. Any value other than 1 is treated as
    batch 2 by the comparison below — there is no validation, matching the
    router, which also passes the query parameter through unchecked.
    """
    skip = market_session_guard()
    if skip:
        log.info("heston_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    today = date.today().isoformat()
    all_rows = get_tickers(db)
    # Deterministic first-letter split (A–M / N–Z) so a watchlist change between
    # the batch-1 (:06) and batch-2 (:20) runs can't skip a boundary ticker.
    #
    # The XOR-style comparison reads oddly but is exact: `is_first_half ==
    # is_batch_one` keeps A-M when batch==1 and N-Z otherwise. Splitting on the
    # LETTER rather than on a list index or a row count is what makes it stable
    # — an index split would shift every ticker's batch membership when one
    # symbol is added between the two runs, so a ticker could be processed twice
    # or not at all. A letter-based split cannot drift.
    #
    # Non-alpha first characters sort below "M" and land in batch 1. `[:1]`
    # rather than `[0]` tolerates an empty ticker string without an IndexError.
    rows = [r for r in all_rows if (r["ticker"][:1].upper() <= "M") == (batch == 1)]
    # Sorted so the run order is reproducible across invocations, which makes a
    # timeout attributable to a specific ticker rather than to scheduling luck.
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
            # Both layers are PER-TICKER, not per-run: one pathological surface
            # consumes its own budget and the batch continues.
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
                # Reached only if the cooperative deadline failed to stop the
                # optimizer. The thread is now orphaned and still running — see
                # the note on the constants for why that is the expensive case.
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
    #
    # Lower than the 5 used by the fetch-based jobs, and for the opposite
    # reason: those are bounded by Schwab's rate limit while this is bounded by
    # CPU. Cloud Run gives this service a single core, so running more
    # calibrations at once does not finish them sooner — it just makes every
    # one of them slower, pushing them all toward the 170s deadline
    # simultaneously. Three is what keeps the per-ticker budget realistic.
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

    WHY WRITE ANYTHING AT ALL. The alternative — leaving no row — is actively
    dangerous, because _fetch_heston_params in routers/fair_value.py takes the
    most recent calibration by obs_date WITHOUT checking how recent it is. With
    no row for today it would happily serve yesterday's parameters as current.
    A NULL-rmse row for today is newer, and its NULL rmse fails that function's
    reliability gate, so fair value cleanly falls back to SABR instead.

    The whole body is wrapped in try/except: failing to write the sentinel must
    not turn a calibration timeout into a job-level error. It is logged and the
    ticker still reports "calibration_timeout".
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
    """Write a successful calibration. One row per (user, ticker, day).

    Note theta and v0 are VARIANCES, not vols — a stored theta of 0.09 means a
    30% long-run vol. Consumers converting for display take the square root.

    The float()/int()/bool() casts coerce numpy scalars (which scipy returns)
    into plain Python types the JSON serializer can handle; each is guarded
    against None so a partially-populated result still writes.

    `converged` records whether local refinement reported success. It is stored
    but NOT gated on by readers — rmse_iv is the binding constraint, and a
    non-converged fit that still landed within 2 vol points is usable.
    """
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
