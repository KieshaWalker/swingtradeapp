from __future__ import annotations

# =============================================================================
# jobs/ticker_dtes_pull.py
# =============================================================================
# On-demand single-ticker pipeline: fetch selected expiration dates at high
# strikeCount, merge into one chain, run all ingesters, write to all tables.
#
# Called from routers/fetch_dtes.py (POST /fetch/ticker-dtes).
#
# Writes to:
#   vol_surface_snapshots   (upsert — enriches with deeper strike coverage)
#   greek_grid_snapshots    (upsert)
#   greek_snapshots         (upsert)
#   expected_move_snapshots (upsert — only for expirations present in merged chain)
#   iv_snapshots            (upsert — independent full-chain fetch, all expirations)
# =============================================================================
#
# THE USER-TRIGGERED PATH. Everything else in jobs/ is fired by Cloud Scheduler
# across the whole watchlist; this runs one ticker on demand, and trades breadth
# for DEPTH — strike_count defaults to 100 here against 40 for the scheduled
# jobs. The wings are where a thin chain hurts most (SABR and Heston fits, RND
# extraction, GEX totals all degrade when the surface is truncated near the
# money), so this is the way to get a properly-resolved surface for one name.
#
# WHY MULTIPLE FETCHES THEN A MERGE: Schwab's gateway caps response size, and
# strike_count applies PER EXPIRATION — an all-expiry request at 100 strikes is
# rejected outright on a liquid name. Fetching each expiry separately and
# stitching them together is what buys the wider strike range.
#
# NO market_session_guard() CALL, unlike every scheduled job. Deliberate: a
# human asking for a fresh pull after hours wants the data they asked for. The
# date-rollover hazard the guard protects against is a property of unattended
# 24/7 crons, not of an interactive request.
#
# EVERY STAGE IS INDEPENDENTLY TRY/EXCEPTED. Stages 3-7 each catch their own
# failures and record a per-stage status, so a broken greek grid still lets the
# vol surface and expected-move rows land. The returned `results` dict reports
# each stage separately — a "complete" status means the JOB finished, not that
# every stage succeeded.

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import fetch_schwab_chain
from jobs.vol_surface_pull import _chain_to_vol_points, _upsert_vol_surface
from jobs.greek_grid_pull import _upsert_greek_grid
from jobs.greek_snapshots_pull import _upsert_greek_snapshots
from jobs.iv_pull import _fetch_iv_history, _fetch_today_sabr, _upsert_iv_snapshot
from jobs.sabr_pull import fetch_nu_history
from jobs.expected_move_pull import _upsert as _upsert_em
from services.greek_grid_ingester import ingest as grid_ingest
from services.expected_move import compute as em_compute, atm_iv_from_chain
from services.iv_analytics import analyse as iv_analyse
from services.vvol_analytics import compute as vvol_compute

log = logging.getLogger(__name__)

# Expected-move period buckets and the DTE each one anchors to. The NEAREST
# available expiry to each target is used, and the actual DTE found is what gets
# priced — so these are anchors, not requirements. Buckets with no expiry
# anywhere near them are simply skipped.
_DTE_TARGETS = {
    "daily":     1,
    "weekly":    7,
    "monthly":  30,
    "quarterly": 90,
}


async def run_ticker_dtes_pull(
    ticker: str,
    user_id: str,
    expiration_dates: list[str],
    strike_count: int = 100,
) -> dict:
    """Fetch the requested expiries deep, then run every ingester over them.

    The 120s client timeout is the longest in the codebase — this fans out one
    request per requested expiration, each returning a much larger payload than
    a scheduled pull.
    """
    today = date.today().isoformat()
    db    = get_supabase()
    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=120.0) as client:
        # ── 1. Fetch each selected expiry concurrently at high strikeCount ──
        raw_chains = await asyncio.gather(*[
            fetch_schwab_chain(client, ticker, strike_count=strike_count, expiration_date=exp)
            for exp in expiration_dates
        ])
        # PARTIAL SUCCESS IS ACCEPTED: failed expiries drop out and the rest
        # proceed. Only a total failure aborts. The caller cannot tell which
        # expiries made it from the response — compare the point and cell counts
        # in the returned results against what was requested.
        valid = [c for c in raw_chains if c is not None]
        if not valid:
            return {"status": "chain_error", "ticker": ticker, "date": today}

        # ── 2. Merge per-expiry chains into one dict ──────────────────────
        merged = _merge_chains(valid)
        spot   = float(merged.get("underlyingPrice", 0))
        if spot <= 0:
            return {"status": "zero_spot", "ticker": ticker, "date": today}

        # ── 3. Vol surface ────────────────────────────────────────────────
        try:
            points = _chain_to_vol_points(merged, spot)
            if points:
                _upsert_vol_surface(db, ticker, today, spot, points, user_id)
                results["vol_surface"] = f"ok:{len(points)}_points"
            else:
                results["vol_surface"] = "no_points"
        except Exception as exc:
            log.error("dtes_vol_surface_failed ticker=%s error=%r", ticker, exc)
            results["vol_surface"] = f"error:{exc!r}"

        # ── 4. Greek grid ─────────────────────────────────────────────────
        try:
            cells = grid_ingest(merged, datetime.now(timezone.utc))
            if cells:
                _upsert_greek_grid(db, ticker, today, cells, spot, user_id)
                results["greek_grid"] = f"ok:{len(cells)}_cells"
            else:
                results["greek_grid"] = "no_cells"
        except Exception as exc:
            log.error("dtes_greek_grid_failed ticker=%s error=%r", ticker, exc)
            results["greek_grid"] = f"error:{exc!r}"

        # ── 5. Greek snapshots ────────────────────────────────────────────
        try:
            _upsert_greek_snapshots(db, ticker, today, spot, merged, user_id)
            results["greek_snapshots"] = "ok"
        except Exception as exc:
            log.error("dtes_greek_snapshots_failed ticker=%s error=%r", ticker, exc)
            results["greek_snapshots"] = f"error:{exc!r}"

        # ── 6. Expected move ──────────────────────────────────────────────
        try:
            expirations = parse_expirations(merged)
            slices = 0
            for period_type, target_dte in _DTE_TARGETS.items():
                iv, actual_dte = atm_iv_from_chain(expirations, spot, target_dte)
                if iv and iv > 0 and actual_dte:
                    em_result = em_compute(spot=spot, iv=iv, dte=actual_dte)
                    _upsert_em(db, ticker, today, spot, period_type, em_result)
                    slices += 1
            results["expected_move"] = f"ok:{slices}_periods"
        except Exception as exc:
            log.error("dtes_expected_move_failed ticker=%s error=%r", ticker, exc)
            results["expected_move"] = f"error:{exc!r}"

        # ── 7. IV — independent full-chain fetch (strikeCount=40, all exps) ──
        # Keeps iv_snapshots consistent with cross-expiry metrics (IVR, GEX, skew).
        # Does not use the merged chain so iv data is never partial.
        #
        # THE SECOND FETCH IS THE POINT, and it is worth the extra API call.
        # IV analytics are CROSS-EXPIRY by nature: term structure compares near
        # against far, total GEX sums every expiration, and IV rank compares
        # against history built from full chains. Feeding it the merged chain —
        # which holds only the handful of expiries the user selected — would
        # write an iv_snapshots row whose GEX and term structure silently
        # describe a fraction of the surface, corrupting the same history that
        # tomorrow's IV rank is computed against.
        #
        # So this deliberately re-fetches at the DEFAULT breadth (all expiries,
        # 40 strikes), keeping the row directly comparable to what iv_pull
        # writes hourly.
        try:
            iv_chain = await fetch_schwab_chain(client, ticker)
            if iv_chain:
                # Falls back to the merged chain's spot if this fetch omits it;
                # the two are seconds apart so either is fine.
                iv_spot   = float(iv_chain.get("underlyingPrice", spot))
                history   = _fetch_iv_history(db, ticker, today)
                iv_result = iv_analyse(iv_chain, history)

                vvol = None
                sabr_slices = _fetch_today_sabr(db, ticker, user_id, today)
                if sabr_slices:
                    nu_history = fetch_nu_history(db, ticker, user_id)
                    if nu_history:
                        atm_slice = min(sabr_slices, key=lambda s: abs(s["dte"] - 30))
                        if atm_slice.get("nu") is not None:
                            vvol = vvol_compute(float(atm_slice["nu"]), nu_history)

                _upsert_iv_snapshot(db, ticker, today, iv_result, iv_spot, vvol)
                results["iv_snapshots"] = "ok"
            else:
                results["iv_snapshots"] = "chain_error"
        except Exception as exc:
            log.error("dtes_iv_failed ticker=%s error=%r", ticker, exc)
            results["iv_snapshots"] = f"error:{exc!r}"

    return {"status": "complete", "ticker": ticker, "date": today, "results": results}


def _merge_chains(chains: list[dict]) -> dict:
    """Merge multiple single-expiry chain dicts into one combined chain dict.

    callExpDateMap / putExpDateMap are merged by key (each key is a unique
    "YYYY-MM-DD:DTE" string, so there are no collisions across expirations).
    Top-level scalars (underlyingPrice, volatility, etc.) come from the first chain.
    Any cached "expirations" key is dropped so normalize_chain re-parses cleanly.

    Taking scalars from the first chain is safe because the fetches happen
    concurrently, seconds apart — spot may differ by a tick between them, and
    one consistent value is better than a mixture.

    Merging by KEY works without collisions because each key embeds both the
    date and the DTE ("2026-01-17:150"), so two different expiries can never
    map to the same key.

    The final pop() is load-bearing. normalize_chain is IDEMPOTENT: it returns
    early if "expirations" is already present, so a stale cached list from the
    first chain would survive the merge and every downstream ingester would see
    only that chain's single expiry. Dropping the key forces a clean re-parse
    over the merged maps.
    """
    base     = {**chains[0]}
    call_map = dict(base.get("callExpDateMap") or {})
    put_map  = dict(base.get("putExpDateMap")  or {})
    for chain in chains[1:]:
        call_map.update(chain.get("callExpDateMap") or {})
        put_map.update(chain.get("putExpDateMap")   or {})
    base["callExpDateMap"] = call_map
    base["putExpDateMap"]  = put_map
    base.pop("expirations", None)
    return base
