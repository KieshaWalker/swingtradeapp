from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/position_eod_snapshot.py
# =============================================================================
# Cloud Scheduler job — run at market close (e.g. 21:05 UTC / 4:05 PM ET).
# For every open position leg, fetches the current options chain + fair-value
# Greeks and inserts an 'eod' snapshot into position_leg_snapshots.
#
# Cron: 5 21 * * 1-5  (21:05 UTC Mon–Fri)
# =============================================================================
#
# BUILDS THE PER-LEG TIME SERIES that everything position-related is ranked
# against. Each daily row records what one open option leg was worth, what its
# Greeks were, and what three models thought it SHOULD have been worth.
#
# A MISSED RUN IS A PERMANENT GAP. These rows cannot be reconstructed after the
# fact — Schwab serves the current chain, not a historical one — and
# contract_opportunity scores a leg by percentile-ranking it against exactly
# these rows. Fewer rows means a noisier percentile, and a leg needs
# IV_MIN_HISTORY_IVR days before it can be scored at all.
#
# jobs/watched_contract_pull.py is the pre-entry twin, writing the same shape of
# row for contracts under consideration rather than held. It runs two minutes
# later, at 21:07.
#
# THE THREE MODEL THEOS (bs_theo, sabr_theo, heston_theo, plus model_theo as the
# best available) are the reason this is more than a price log: storing what the
# models said at the time makes it possible to ask later whether a position was
# mispriced when it was opened, and to rank a leg's current edge against its own
# historical edge.

import asyncio
import logging
import uuid
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_chain, _fany, _igt0, _pct_to_dec
from services.fair_value_engine import compute as fv_compute
from services.heston import HestonParams

log = logging.getLogger(__name__)


async def run_position_eod_snapshot() -> dict:
    """Snapshot every open option leg's Greeks and model values at the close."""
    now = datetime.now(timezone.utc)
    # Safety guard — only run near market close (20:00–22:00 UTC)
    #
    # A UTC-hour window rather than market_session_guard(), which would reject
    # this job outright (it refuses anything after 16:30 ET). The purpose is the
    # opposite of the intraday guard: this must run ONLY at the close, so an
    # accidental manual trigger at midday cannot overwrite the day's row with
    # mid-session values under snapshot_type "eod".
    #
    # Note the window is in UTC, so it drifts by an hour against ET across
    # daylight saving — 20:00-22:00 UTC is 4-6pm ET in winter and 3-5pm in
    # summer. Wide enough that the close is inside it either way.
    if not (20 <= now.hour < 22):
        log.info("position_eod_snapshot: skipped (not near market close)")
        return {"status": "skipped_time"}

    db = get_supabase()
    today = date.today().isoformat()

    # Fetch all open legs with their parent position for user_id
    # The `positions(user_id)` term is a PostgREST embedded join, pulling the
    # parent row's user_id in one round trip instead of a second query.
    # `.neq("type", "underlying")` filters out stock legs of a combined
    # position — they have no strike, expiry or Greeks to snapshot.
    legs_resp = (
        db.table("position_legs")
        .select("id, type, ticker, strike, expiry, quantity, position_id, positions(user_id)")
        .eq("status", "open")
        .neq("type", "underlying")
        .execute()
    )
    legs = legs_resp.data or []

    if not legs:
        log.info("position_eod_snapshot: no open option legs")
        return {"status": "no_legs"}

    # Group legs by ticker so we fetch each chain once
    # A multi-leg spread has every leg on the same underlying, so this collapses
    # a whole position into a single chain fetch — the dominant cost here.
    by_ticker: dict[str, list[dict]] = {}
    for leg in legs:
        by_ticker.setdefault(leg["ticker"], []).append(leg)

    results: dict[str, str] = {}
    snapshots: list[dict] = []

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process_ticker(ticker: str, ticker_legs: list[dict]) -> None:
            chain = await fetch_schwab_chain(client, ticker)
            if chain is None:
                for leg in ticker_legs:
                    results[leg["id"]] = "chain_error"
                return

            spot = float(chain.get("underlyingPrice", 0) or 0)

            # Build a flat lookup: (expiry_date, strike, type) → contract dict
            # Flattens Schwab's nested maps into one keyed dict so each leg is
            # an O(1) lookup rather than a scan. Parsed directly here rather
            # than via chain_utils because the key needs the expiry DATE (to
            # match the leg's stored expiry) while parse_expirations keys on DTE.
            # `contracts[0]` takes the first contract at a strike; the list has
            # more than one only in unusual adjusted-option cases.
            contract_map: dict[tuple, dict] = {}
            for exp_key, strikes in chain.get("callExpDateMap", {}).items():
                exp_date = exp_key.split(":")[0]
                for strike_str, contracts in strikes.items():
                    c = contracts[0] if contracts else {}
                    contract_map[(exp_date, float(strike_str), "call")] = c
            for exp_key, strikes in chain.get("putExpDateMap", {}).items():
                exp_date = exp_key.split(":")[0]
                for strike_str, contracts in strikes.items():
                    c = contracts[0] if contracts else {}
                    contract_map[(exp_date, float(strike_str), "put")] = c

            # Fetch Heston params once per ticker — shared across all legs.
            # Same reliability gate as routers/fair_value.py: rmse_iv < 0.02
            # (2 vol points) across at least 8 quotes. Below either bar the
            # parameters describe a surface that was never really matched, and a
            # Heston price from them would be worse than the SABR price it would
            # replace — so heston_params stays None and fv_compute falls back.
            #
            # NOTE this takes the most recent calibration WITHOUT checking its
            # obs_date, so a ticker whose calibration last succeeded days ago
            # will be priced off stale parameters. The timeout sentinel rows
            # written by heston_pull are what stop that from being worse: a
            # failed calibration writes a NULL-rmse row for today, which fails
            # the gate above.
            #
            # Wrapped in try/except so a Heston lookup failure degrades pricing
            # rather than skipping the ticker's snapshots entirely.
            heston_params:Optional[HestonParams] = None
            try:
                h_rows = (
                    db.table("heston_calibrations")
                    .select("kappa,theta,xi,rho,v0,rmse_iv,n_points")
                    .eq("ticker", ticker)
                    .order("obs_date", desc=True)
                    .limit(1)
                    .execute()
                ).data or []
                if h_rows:
                    h = h_rows[0]
                    if (
                        h.get("rmse_iv") is not None
                        and h["rmse_iv"] < 0.02
                        and (h.get("n_points") or 0) >= 8
                    ):
                        heston_params = HestonParams(
                            kappa=h["kappa"],
                            theta=h["theta"],
                            xi=h["xi"],
                            rho=h["rho"],
                            V0=h["v0"],
                        )
            except Exception as he:
                log.warning("heston_fetch_error ticker=%s error=%r", ticker, he)

            for leg in ticker_legs:
                try:
                    expiry:Optional[str] = leg.get("expiry")
                    strike:Optional[float] = leg.get("strike")
                    leg_type: str = leg["type"]  # 'call' or 'put'

                    if expiry is None or strike is None:
                        results[leg["id"]] = "missing_expiry_or_strike"
                        continue

                    # Exact match first: the leg's stored expiry string must
                    # equal Schwab's expiry date exactly for this to hit.
                    contract = contract_map.get((expiry, float(strike), leg_type))
                    if contract is None:
                        # Fuzzy match — nearest strike, but only within 2% of
                        # the leg strike so a sparse chain can't silently
                        # snapshot a far-away contract's Greeks.
                        candidates = [
                            (k, v) for k, v in contract_map.items()
                            if k[0] == expiry and k[2] == leg_type
                        ]
                        if candidates:
                            best_k, best_v = min(
                                candidates,
                                key=lambda kv: abs(kv[0][1] - float(strike)),
                            )
                            # max($0.50, 2% of strike) — the floor matters for
                            # low-priced names, where 2% is narrower than one
                            # strike increment and every fuzzy match would be
                            # rejected. Beyond the tolerance the nearest contract
                            # is a genuinely different instrument, and snapshotting
                            # its Greeks against this leg would quietly corrupt the
                            # series the leg is later ranked against — better to
                            # record nothing.
                            tolerance = max(0.5, 0.02 * float(strike))
                            if abs(best_k[1] - float(strike)) <= tolerance:
                                contract = best_v
                            else:
                                log.warning(
                                    "position_eod: nearest strike %.2f too far from leg strike %.2f (leg=%s ticker=%s)",
                                    best_k[1], float(strike), leg["id"], ticker,
                                )

                    if not contract:
                        results[leg["id"]] = "contract_not_found"
                        continue

                    # Schwab percent -> decimal, matching what fv_compute expects.
                    # _fany (not _fgt0/_fne0) for the Greeks: a genuine zero is a
                    # real reading for a deep-OTM leg and must be preserved, since
                    # this row is a record of what the broker reported.
                    iv = _pct_to_dec(contract.get("volatility"))
                    dte = int(contract.get("daysToExpiration") or 0)
                    mark = _fany(contract, "mark")
                    delta = _fany(contract, "delta")
                    gamma = _fany(contract, "gamma")
                    theta = _fany(contract, "theta")
                    vega = _fany(contract, "vega")
                    rho = _fany(contract, "rho")

                    # Compute fair-value model prices via direct function call.
                    # Direct call, not an HTTP round trip to /fair-value/compute
                    # — same process, so the network hop would be pure overhead.
                    #
                    # All four preconditions are required: without an IV there is
                    # no vol to price at, without a positive DTE the formula
                    # degenerates, without a mark there is nothing to compare
                    # against, and without spot the forward is undefined. When
                    # any is missing the snapshot is still written, just without
                    # the *_theo columns.
                    fv_result = None
                    if dte <= 0:
                        log.warning("position_eod: missing daysToExpiration for leg=%s ticker=%s; skipping fv_compute", leg.get("id"), ticker)
                    if iv and dte > 0 and mark is not None and spot > 0:
                        try:
                            fv_result = fv_compute(
                                spot=spot,
                                strike=float(strike),
                                implied_vol=iv,
                                days_to_expiry=dte,
                                is_call=(leg_type == "call"),
                                broker_mid=mark,
                                heston_params=heston_params,
                            )
                        except Exception as fv_exc:
                            log.warning("fv_error leg=%s error=%r", leg["id"], fv_exc)

                    snapshot = {
                        "id": str(uuid.uuid4()),
                        "leg_id": leg["id"],
                        "snapshot_date": today,
                        "snapshot_type": "eod",
                        "underlying_price": spot if spot > 0 else None,
                        "market_price": mark,
                        "implied_vol": iv,
                        "delta": delta,
                        "gamma": gamma,
                        "theta": theta,
                        "vega": vega,
                        "rho": rho,
                        "open_interest": _igt0(contract, "openInterest"),
                        "total_volume": _igt0(contract, "totalVolume"),
                    }
                    if fv_result:
                        # Stored separately so the model ladder is visible in
                        # hindsight: model_theo is whichever was best available
                        # (Heston if a reliable calibration existed, else SABR),
                        # and keeping all three shows which one that was.
                        snapshot["bs_theo"]     = fv_result.bs_fair_value
                        snapshot["sabr_theo"]   = fv_result.sabr_fair_value
                        snapshot["heston_theo"] = fv_result.heston_fair_value
                        snapshot["model_theo"]  = fv_result.model_fair_value

                    snapshots.append(snapshot)
                    results[leg["id"]] = "ok"

                except Exception as exc:
                    log.error("leg_snapshot_error leg=%s error=%r", leg["id"], exc, exc_info=True)
                    results[leg["id"]] = f"error:{exc!r}"

        await asyncio.gather(*[
            _process_ticker(ticker, ticker_legs)
            for ticker, ticker_legs in by_ticker.items()
        ])

    # ONE batched write for every leg across every ticker, rather than a write
    # per leg. Keyed (leg_id, snapshot_date, snapshot_type), so re-running the
    # job on the same day overwrites rather than duplicating — and the
    # snapshot_type discriminator leaves room for non-EOD captures alongside.
    if snapshots:
        db.table("position_leg_snapshots").upsert(
            snapshots,
            on_conflict="leg_id,snapshot_date,snapshot_type",
        ).execute()
        log.info("position_eod_snapshot: inserted %d snapshots", len(snapshots))

    # `details` maps every leg_id to its outcome — "ok", or a named reason
    # ("chain_error", "contract_not_found", "missing_expiry_or_strike"). A
    # "done" status means the job ran, not that every leg was captured; the gap
    # between `legs` and `snapshots` is what to watch.
    ok_count = sum(1 for v in results.values() if v == "ok")
    return {"status": "done", "legs": len(legs), "snapshots": ok_count, "details": results}
