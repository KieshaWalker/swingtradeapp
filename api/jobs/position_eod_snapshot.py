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

import asyncio
import logging
import uuid
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_chain, _fany, _pct_to_dec
from services.fair_value_engine import compute as fv_compute
from services.heston import HestonParams

log = logging.getLogger(__name__)


async def run_position_eod_snapshot() -> dict:
    now = datetime.now(timezone.utc)
    # Safety guard — only run near market close (20:00–22:00 UTC)
    if not (20 <= now.hour < 22):
        log.info("position_eod_snapshot: skipped (not near market close)")
        return {"status": "skipped_time"}

    db = get_supabase()
    today = date.today().isoformat()

    # Fetch all open legs with their parent position for user_id
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

                    contract = contract_map.get((expiry, float(strike), leg_type))
                    if contract is None:
                        # Fuzzy match — find nearest strike
                        candidates = [
                            (k, v) for k, v in contract_map.items()
                            if k[0] == expiry and k[2] == leg_type
                        ]
                        if candidates:
                            contract = min(
                                candidates,
                                key=lambda kv: abs(kv[0][1] - float(strike)),
                            )[1]

                    if not contract:
                        results[leg["id"]] = "contract_not_found"
                        continue

                    iv = _pct_to_dec(contract.get("volatility"))
                    dte = int(contract.get("daysToExpiration") or 0)
                    mark = _fany(contract, "mark")
                    delta = _fany(contract, "delta")
                    gamma = _fany(contract, "gamma")
                    theta = _fany(contract, "theta")
                    vega = _fany(contract, "vega")
                    rho = _fany(contract, "rho")

                    # Compute fair-value model prices via direct function call.
                    fv_result = None
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
                    }
                    if fv_result:
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

    if snapshots:
        db.table("position_leg_snapshots").upsert(
            snapshots,
            on_conflict="leg_id,snapshot_date,snapshot_type",
        ).execute()
        log.info("position_eod_snapshot: inserted %d snapshots", len(snapshots))

    ok_count = sum(1 for v in results.values() if v == "ok")
    return {"status": "done", "legs": len(legs), "snapshots": ok_count, "details": results}
