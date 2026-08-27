from __future__ import annotations

# =============================================================================
# jobs/iv_pull.py
# =============================================================================
# Job 4 — Fetch chain → IV analytics + vvol rank → upsert iv_snapshots.
# Cron: 9 13-21 * * 1-5  (9 min after vol_surface_pull, Mon–Fri)
#
# Fetches the raw Schwab chain (needed by iv_analyse for GEX/RND computation).
# Reads today's sabr_calibrations for vvol rank (written by sabr_pull).
# =============================================================================
#
# THE ANALYTICS WORKHORSE. Produces the iv_snapshots row that the app's IV tab,
# the option scorer's regime multipliers, and regime_pull all read: GEX/VEX/CEX,
# zero-gamma level, IVR/IVP across three windows, skew, RND, and vol-of-vol.
#
# WHY IT RE-FETCHES A CHAIN instead of reading vol_surface_snapshots like
# sabr_pull and heston_pull do: the exposure sums need FULL open-interest detail
# across every strike including 0DTE, and RND extraction needs the raw call
# prices. The stored surface points are a filtered projection (IV > 0 only, no
# 0DTE), so they cannot reproduce a gamma total.
#
# IT WRITES A DIFFERENT SHAPE OF ROW FROM ITS SIBLINGS. iv_snapshots is keyed
# (ticker, date) — GLOBAL, with no user_id — because dealer positioning is a
# property of the market, not of a watcher. Every other pipeline table is keyed
# per-user. That mismatch is what forces the ticker de-duplication below.
#
# The same rows are also written on demand by POST /iv/snapshot. The two paths
# must stay schema-compatible; see routers/iv_analytics.py.

import asyncio
import logging
from datetime import date

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_chain, market_session_guard
from jobs.sabr_pull import fetch_nu_history, apply_reliability_filter
from services.iv_analytics import analyse as iv_analyse
from services.vvol_analytics import compute as vvol_compute

log = logging.getLogger(__name__)

# Bounded by Schwab's rate limit, as in the other fetch-based jobs.
_CONCURRENCY = 5


async def run_iv_pull() -> dict:
    """Compute and store IV analytics for every tracked ticker."""
    skip = market_session_guard()
    if skip:
        log.info("iv_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    today = date.today().isoformat()
    all_rows = get_tickers(db)
    if not all_rows:
        log.warning("iv_pull: no tickers")
        return {"status": "no_tickers"}

    # iv_snapshots is keyed (ticker, date) — global, not per-user — so process
    # each ticker once. Pick the lowest user_id per ticker deterministically
    # for the per-user SABR/vvol inputs (was last-writer-wins before).
    #
    # The subtlety: the OUTPUT is global but two of the INPUTS (sabr_calibrations
    # and its ν history) are per-user. Some user's calibrations must be chosen,
    # and processing every user would have them overwrite each other's identical
    # analytics while attaching different vvol figures — the last writer winning
    # arbitrarily. Sorting by (ticker, user_id) and taking the first via
    # setdefault makes the choice deterministic, so vvol_rank stops flickering
    # between runs on a ticker that two users watch.
    by_ticker: dict[str, dict] = {}
    for r in sorted(all_rows, key=lambda r: (r["ticker"], r["user_id"])):
        by_ticker.setdefault(r["ticker"], r)
    rows = list(by_ticker.values())

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    # Prefetch all DB reads before the concurrent HTTP section so synchronous
    # Supabase calls don't block the event loop mid-gather.
    #
    # This is the one structural difference from the other fetch jobs and it
    # matters: the supabase-py client is SYNCHRONOUS. A .execute() inside
    # _process would stall the entire event loop — every other ticker's
    # in-flight HTTP request included — for the duration of the round trip.
    # Hoisting all three reads out front makes the gather below purely I/O-bound
    # on HTTP. The cost is that these run serially, which is why they are kept
    # to narrow column selections.
    iv_history_map: dict[str, list[dict]] = {
        r["ticker"]: _fetch_iv_history(db, r["ticker"], today) for r in rows
    }
    sabr_map: dict[tuple[str, str], list[dict]] = {
        (r["ticker"], r["user_id"]): _fetch_today_sabr(db, r["ticker"], r["user_id"], today)
        for r in rows
    }
    # The `if` guard skips the ν-history read entirely for tickers with no
    # reliable SABR slice today — that read paginates a full year of rows, so
    # skipping it when the result cannot be used is a real saving.
    nu_map: dict[tuple[str, str], list[float]] = {
        (r["ticker"], r["user_id"]): fetch_nu_history(db, r["ticker"], r["user_id"])
        for r in rows
        if sabr_map.get((r["ticker"], r["user_id"]))
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(row: dict) -> tuple[str, str]:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                async with sem:
                    chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"
                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    return ticker, "zero_spot"

                # `history` drives ONLY the rank/percentile and skew z-score
                # windows — every exposure figure comes from the fresh chain.
                # An empty history yields null ranks, not a failed run.
                history   = iv_history_map.get(ticker, [])
                iv_result = iv_analyse(chain, history)

                # vvol rank uses the SABR ν series written by sabr_pull
                #
                # VOL-OF-VOL: how much IV itself moves. ν is SABR's vol-of-vol
                # parameter, so ranking today's ν against its own trailing year
                # answers "is volatility unusually jumpy right now?". Entirely
                # optional — three separate conditions can leave it None, and
                # the snapshot is written regardless.
                vvol = None
                slices = sabr_map.get((ticker, user_id), [])
                if slices:
                    nu_history = nu_map.get((ticker, user_id), [])
                    if nu_history:
                        # ~30 DTE anchor, matching fetch_nu_history's default,
                        # so today's ν is compared against a series of the same
                        # tenor rather than against the term structure.
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


def _fetch_iv_history(db, ticker: str, before_date: str) -> list[dict]:
    """Most recent 252 prior-day rows, returned oldest→newest.

    Order desc + reverse: ascending order with a limit returns the *oldest*
    rows once the table outgrows the limit, freezing IVR/IVP/skew windows on
    ancient data. Excludes before_date (today) so the rank window holds prior
    sessions only.
    """
    resp = (
        db.table("iv_snapshots")
        .select("atm_iv,skew,total_gex,date")
        .eq("ticker", ticker)
        .lt("date", before_date)
        .order("date", desc=True)
        .limit(252)
        .execute()
    )
    rows = resp.data or []
    rows.reverse()
    return rows


def _fetch_today_sabr(db, ticker: str, user_id: str, today: str) -> list[dict]:
    """Today's SABR slices, restricted to fits that actually track the surface.

    Unreliable slices are dropped rather than ranked: a boundary-pinned fit
    reports the same ν every session, which collapses the vvol rank window to a
    single value and makes vvol_compute return a constant. Mirrors the RMSE gate
    routers/fair_value.py applies to heston_calibrations.
    """
    resp = (
        apply_reliability_filter(
            db.table("sabr_calibrations")
            .select("dte,nu")
            .eq("user_id", user_id)
            .eq("ticker", ticker)
            .eq("obs_date", today)
        )
        .execute()
    )
    return resp.data or []


def _n14(v):
    """Return None if v would overflow numeric(14,2) (abs >= 1e12).

    Guards the DOLLAR-DENOMINATED exposure columns (total_gex, delta_gex,
    total_vex/cex/volga, gex_0dte), which are the only ones that can run large
    enough to overflow. Postgres raises on an out-of-range numeric rather than
    truncating, so without this one absurd value — a data glitch, or a chain
    with nonsense open interest — would abort the whole row's insert and lose
    every other analytic for that ticker that hour. Storing NULL loses one
    field instead.
    """
    if v is None:
        return None
    return None if abs(v) >= 1e12 else v


def _upsert_iv_snapshot(db, ticker: str, today: str, iv_result, spot: float, vvol=None) -> None:
    """Write the analytics row. Keyed (ticker, date) — GLOBAL, no user_id.

    Overwritten by each hourly run, so the row holds the latest intraday state
    and the final write of the session becomes the day's record.

    Enum fields are stored as `.value` so the Dart client parses stable wire
    strings. Most are None-guarded; `vanna_regime` notably is not, on the
    assumption the analyser always populates it.
    """
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
        "total_gex":              _n14(iv_result.total_gex),
        "max_gex_strike":         iv_result.max_gex_strike,
        "put_call_ratio":         iv_result.put_call_ratio,
        "underlying_price":       spot,
        "iv_rank":                iv_result.iv_rank,
        "iv_percentile":          iv_result.iv_percentile,
        "iv_rank_4w":             iv_result.iv_rank_4w,
        "iv_percentile_4w":       iv_result.iv_percentile_4w,
        "iv_rank_26w":            iv_result.iv_rank_26w,
        "iv_percentile_26w":      iv_result.iv_percentile_26w,
        "iv_rating":              iv_result.rating.value if iv_result.rating else None,
        "gamma_regime":           iv_result.gamma_regime.value if iv_result.gamma_regime else None,
        "gamma_slope":            iv_result.gamma_slope.value if iv_result.gamma_slope else None,
        "iv_gex_signal":          iv_result.iv_gex_signal.value if iv_result.iv_gex_signal else None,
        "zero_gamma_level":       iv_result.zero_gamma_level,
        "spot_to_zero_gamma_pct": iv_result.spot_to_zero_gamma_pct,
        "delta_gex":              _n14(iv_result.delta_gex),
        "put_wall_density":       iv_result.put_wall_density,
        "vanna_regime":           iv_result.vanna_regime.value,
        # SCALE BREAK: rows written before 2026-06-12 used different units for
        # these three. Across that date only the SIGN is comparable — never
        # chart them as a continuous series through it.
        "total_vex":              _n14(iv_result.total_vex),
        "total_cex":              _n14(iv_result.total_cex),
        "total_volga":            _n14(iv_result.total_volga),
        "max_vex_strike":         iv_result.max_vex_strike,
        "skew_avg_52w":           iv_result.skew_avg_52w,
        "skew_z_score":           iv_result.skew_z_score,
        # `or None` stores SQL NULL rather than an empty array, keeping "no RND
        # could be extracted" distinguishable from "computed as empty".
        "rnd":                    [s.to_dict() for s in iv_result.rnd] or None,
        # Fields read by regime_pull
        "spot_to_vt_pct":         iv_result.spot_to_vt_pct,
        "gex_0dte":               _n14(iv_result.gex_0dte),
        "gex_0dte_pct":           iv_result.gex_0dte_pct,
    }
    # Merged rather than set inline so that a ticker with no usable ν series
    # leaves these columns UNTOUCHED — preserving whatever an earlier run today
    # wrote, instead of overwriting good values with nulls.
    if vvol is not None:
        row.update({
            "vvol_nu":         vvol.nu_current,
            "vvol_rank":       vvol.vvol_rank,
            "vvol_percentile": vvol.vvol_percentile,
            "vvol_rating":     vvol.vvol_rating,
            "vvol_trend":      vvol.nu_trend,
        })
    db.table("iv_snapshots").upsert(row, on_conflict="ticker,date").execute()
