from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/watched_contract_pull.py
# =============================================================================
# Cloud Scheduler job — run at market close (e.g. 21:07 UTC / 4:07 PM ET, two
# minutes after position-eod-snapshot so the two don't contend on the same
# ticker's chain fetch at the same instant).
#
# Pre-entry twin of position_eod_snapshot.py: for every row in
# watched_contracts with status='watching', fetches the current options
# chain + fair-value Greeks and upserts one row into
# watched_contract_snapshots for today. Structurally this is the same walk
# as position_eod_snapshot.py (group by ticker, fetch each chain once,
# locate the contract, run fv_compute) with two differences: there's no
# entry/eod/exit snapshot_type (nothing has been entered yet -- every row is
# just "what this contract looked like today"), and expired watches are
# skipped before hitting the chain rather than surfacing as a lookup miss.
#
# Cron: 7 21 * * 1-5  (21:07 UTC Mon-Fri)
# =============================================================================
#
# WHY PRE-ENTRY HISTORY MATTERS. /watched-contracts/evaluate scores a contract
# against ITS OWN past — is this contract's IV low FOR THIS CONTRACT, and is it
# more underpriced than it usually is? That needs a stored time series, and the
# series has to exist BEFORE the decision to enter, which is exactly what this
# job accumulates. A newly-added watch therefore returns insufficient_history
# until enough daily rows have built up (IV_MIN_HISTORY_IVR days).
#
# The two-minute offset from position_eod_snapshot is not just politeness about
# chain fetches — it also keeps the two jobs' Schwab concurrency budgets from
# overlapping at the busiest moment of the day.
#
# DUPLICATED RATHER THAN SHARED. The contract-map build, the Heston gate and the
# fuzzy-strike match are near-copies of position_eod_snapshot.py. The two walks
# differ in their source table, their key, their expiry pre-filter and their
# snapshot shape, so a shared helper would need enough parameters to be worse
# than the duplication. IF YOU FIX A BUG IN ONE, FIX IT IN BOTH — particularly
# the 2% strike tolerance and the rmse_iv < 0.02 Heston gate.

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


async def run_watched_contract_pull() -> dict:
    """Snapshot every actively-watched contract at the close."""
    now = datetime.now(timezone.utc)
    # Safety guard — only run near market close (20:00-22:00 UTC), matching
    # position_eod_snapshot.py so both jobs capture the same close.
    if not (20 <= now.hour < 22):
        log.info("watched_contract_pull: skipped (not near market close)")
        return {"status": "skipped_time"}

    db = get_supabase()
    today = date.today()
    today_iso = today.isoformat()

    watches_resp = (
        db.table("watched_contracts")
        .select("id, ticker, strike, expiry, type")
        .eq("status", "watching")
        .execute()
    )
    watches = watches_resp.data or []

    # Drop watches whose expiry has already passed — the chain won't return
    # them, so there's no point spending a lookup on it.
    #
    # This is the one structural difference from position_eod_snapshot, which
    # has no equivalent pre-filter: an expired watch there surfaces as a
    # "contract_not_found" lookup miss. Filtering here keeps expired watches out
    # of the results map entirely, so the reported miss count means something.
    #
    # String comparison works because both sides are zero-padded ISO dates.
    # `>=` keeps expiry day itself, which is still tradeable.
    watches = [w for w in watches if w["expiry"] >= today_iso]

    if not watches:
        log.info("watched_contract_pull: no active watches")
        return {"status": "no_watches"}

    by_ticker: dict[str, list[dict]] = {}
    for w in watches:
        by_ticker.setdefault(w["ticker"], []).append(w)

    results: dict[str, str] = {}
    snapshots: list[dict] = []

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process_ticker(ticker: str, ticker_watches: list[dict]) -> None:
            chain = await fetch_schwab_chain(client, ticker)
            if chain is None:
                for w in ticker_watches:
                    results[w["id"]] = "chain_error"
                return

            spot = float(chain.get("underlyingPrice", 0) or 0)

            # Flat (expiry_date, strike, type) -> contract lookup. Built from
            # the raw Schwab maps rather than via chain_utils because the key
            # needs the expiry DATE to match the watch's stored expiry, while
            # parse_expirations keys on DTE.
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

            # Same reliability gate as routers/fair_value.py and
            # position_eod_snapshot: rmse_iv < 0.02 across >= 8 quotes. Fetched
            # once per ticker and shared by every watch on it. Failure leaves
            # heston_params None and fv_compute falls back to SABR.
            heston_params: Optional[HestonParams] = None
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

            for w in ticker_watches:
                try:
                    expiry: str = w["expiry"]
                    strike: float = float(w["strike"])
                    watch_type: str = w["type"]  # 'call' or 'put'

                    # Exact match first; fuzzy fallback below.
                    contract = contract_map.get((expiry, strike, watch_type))
                    if contract is None:
                        # Fuzzy match — nearest strike within 2%, same
                        # tolerance rule as position_eod_snapshot.py, so a
                        # sparse chain can't silently snapshot a far strike.
                        candidates = [
                            (k, v) for k, v in contract_map.items()
                            if k[0] == expiry and k[2] == watch_type
                        ]
                        if candidates:
                            best_k, best_v = min(
                                candidates,
                                key=lambda kv: abs(kv[0][1] - strike),
                            )
                            # max($0.50, 2% of strike). The floor matters on
                            # low-priced names where 2% is narrower than one
                            # strike increment. Beyond it the nearest contract is
                            # a different instrument, and snapshotting it would
                            # corrupt the very series this watch is ranked
                            # against — better to record nothing.
                            tolerance = max(0.5, 0.02 * strike)
                            if abs(best_k[1] - strike) <= tolerance:
                                contract = best_v
                            else:
                                log.warning(
                                    "watched_contract_pull: nearest strike %.2f too far from watch strike %.2f (watch=%s ticker=%s)",
                                    best_k[1], strike, w["id"], ticker,
                                )

                    if not contract:
                        results[w["id"]] = "contract_not_found"
                        continue

                    iv = _pct_to_dec(contract.get("volatility"))
                    dte = int(contract.get("daysToExpiration") or 0)
                    mark = _fany(contract, "mark")
                    delta = _fany(contract, "delta")
                    gamma = _fany(contract, "gamma")
                    theta = _fany(contract, "theta")
                    vega = _fany(contract, "vega")
                    rho = _fany(contract, "rho")

                    fv_result = None
                    if iv and dte > 0 and mark is not None and spot > 0:
                        try:
                            fv_result = fv_compute(
                                spot=spot,
                                strike=strike,
                                implied_vol=iv,
                                days_to_expiry=dte,
                                is_call=(watch_type == "call"),
                                broker_mid=mark,
                                heston_params=heston_params,
                            )
                        except Exception as fv_exc:
                            log.warning("fv_error watch=%s error=%r", w["id"], fv_exc)

                    # Note there is no snapshot_type column here, unlike
                    # position_leg_snapshots: nothing has been entered, so every
                    # row is simply "what this contract looked like today".
                    # `dte` IS stored (position snapshots omit it), because a
                    # watch's attractiveness is inseparable from how much time
                    # is left on it.
                    snapshot = {
                        "id": str(uuid.uuid4()),
                        "watch_id": w["id"],
                        "snapshot_date": today_iso,
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
                        "dte": dte if dte > 0 else None,
                    }
                    # model_theo is the field contract_opportunity turns into
                    # edge_bps: (model_theo - market_price)/market_price x 10,000.
                    # Both must be present on a row for that leg of the score to
                    # work, which is why a missing fv_result shows up later as
                    # "Edge percentile unavailable".
                    if fv_result:
                        snapshot["bs_theo"]     = fv_result.bs_fair_value
                        snapshot["sabr_theo"]   = fv_result.sabr_fair_value
                        snapshot["heston_theo"] = fv_result.heston_fair_value
                        snapshot["model_theo"]  = fv_result.model_fair_value

                    snapshots.append(snapshot)
                    results[w["id"]] = "ok"

                except Exception as exc:
                    log.error("watch_snapshot_error watch=%s error=%r", w["id"], exc, exc_info=True)
                    results[w["id"]] = f"error:{exc!r}"

        await asyncio.gather(*[
            _process_ticker(ticker, ticker_watches)
            for ticker, ticker_watches in by_ticker.items()
        ])

    # One batched write across every ticker. Keyed (watch_id, snapshot_date) —
    # one row per watch per day, so a re-run overwrites rather than duplicating.
    if snapshots:
        db.table("watched_contract_snapshots").upsert(
            snapshots,
            on_conflict="watch_id,snapshot_date",
        ).execute()
        log.info("watched_contract_pull: inserted %d snapshots", len(snapshots))

    ok_count = sum(1 for v in results.values() if v == "ok")
    return {"status": "done", "watches": len(watches), "snapshots": ok_count, "details": results}
