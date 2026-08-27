from __future__ import annotations

# =============================================================================
# jobs/vol_surface_pull.py
# =============================================================================
# Job 1 — Fetch Schwab options chain → upsert vol_surface_snapshots.
# Cron: 0 13-21 * * 1-5  (hourly during US market hours, Mon–Fri)
#
# All downstream jobs (sabr, heston, iv, greek_grid, greek_snapshots, regime)
# depend on data written here — run this first.
# =============================================================================
#
# HEAD OF THE PIPELINE. Its job is narrow but foundational: turn Schwab's
# nested chain into one flat list of per-(strike, DTE) points and store it.
# It computes nothing — no Greeks of its own, no calibration, no analytics.
# That separation is what lets sabr_pull and heston_pull re-fit from stored
# points without re-hitting the Schwab API, which is the expensive, rate-
# limited, failure-prone part.
#
# THE STORED ROW IS THE SYSTEM'S RAW RECORD. `points` is a JSONB array holding
# everything Schwab reported per strike — both sides' IVs, Greeks, quotes,
# sizes, volumes, open interest. Downstream jobs read subsets of it. Because it
# is stored raw, a change in how a downstream model interprets the data can be
# backfilled against history rather than needing a fresh fetch.
#
# THE FLIP SIDE — this is by some distance the largest table in the database.
# `points` is a wide JSONB blob written hourly per ticker per user, which is
# what makes select("*") on this table a genuine disk-IO problem: reading a
# column you do not need still pulls the whole JSONB payload. Always select the
# specific columns, as sabr_pull does with "spot_price,points".
#
# UNITS NOTE: IVs are stored as DECIMALS here (divided by 100 on the way in),
# even though the raw Schwab field is percent. Downstream calibrators expect
# decimals, so this job is the conversion boundary.
# =============================================================================

import asyncio
import logging
from datetime import datetime, timezone
from datetime import date

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import (
    get_tickers, fetch_schwab_chain, market_session_guard,
    _fgt0, _fne0, _fany, _igt0,
)

log = logging.getLogger(__name__)

# Max simultaneous Schwab chain fetches. Tuned against the upstream rate limit
# rather than local CPU — the work here is almost entirely network wait, so a
# higher number would only make Schwab throttle us. The same value is used by
# greek_grid_pull, and the two jobs are staggered 12 minutes apart precisely so
# their concurrency budgets do not overlap.
_CONCURRENCY = 5


async def run_vol_surface_pull() -> dict:
    """Fetch and store the vol surface for every tracked (ticker, user) pair.

    Structure shared by every fetch-based job in this package:
      1. Session guard — bail outside market hours (see jobs/common.py for why
         the date-rollover hazard makes this non-optional).
      2. Resolve the ticker universe.
      3. Fan out with a semaphore-bounded gather.
      4. Return a per-ticker status map rather than raising.

    The result dict's `tickers` map is the run's real output: each value is
    "ok", a named skip reason ("chain_error", "zero_spot", "no_points"), or an
    "error:<repr>" string. A 200 from the scheduler means the JOB ran, not that
    every ticker succeeded — read the map.
    """
    skip = market_session_guard()
    if skip:
        log.info("vol_surface_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    # Local date, matching the ET session the guard just admitted. Stored into a
    # DATE column, so it is never timezone-shifted on read.
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("vol_surface_pull: no tickers")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(row: dict) -> tuple[str, str]:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                # The semaphore wraps ONLY the network call, not the parsing or
                # the DB write. That is deliberate: holding a slot through the
                # CPU-bound parse would idle the Schwab connection budget.
                async with sem:
                    chain = await fetch_schwab_chain(client, ticker)
                if chain is None:
                    return ticker, "chain_error"
                spot = float(chain.get("underlyingPrice", 0))
                # A zero spot poisons everything downstream — moneyness, the
                # forward, every exposure in dollars. Caught here rather than
                # allowed to produce a plausible-looking row of zeros.
                if spot <= 0:
                    log.warning("zero_spot ticker=%s", ticker)
                    return ticker, "zero_spot"
                points = _chain_to_vol_points(chain, spot)
                if not points:
                    return ticker, "no_points"
                _upsert_vol_surface(db, ticker, today, spot, points, user_id)
                log.info("vol_surface_ok ticker=%s points=%d", ticker, len(points))
                return ticker, "ok"
            except Exception as exc:
                # Per-ticker containment: one bad symbol costs its own row, not
                # the run. gather() below has no return_exceptions=True, so this
                # handler is what actually guarantees that.
                log.error("vol_surface_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


def _chain_to_vol_points(chain: dict, spot: float) -> list[dict]:
    """Convert Schwab callExpDateMap/putExpDateMap to vol surface points.
    Matches VolSurfaceParser.fromChain() field set exactly.

    Produces ONE row per (strike, DTE) carrying BOTH sides, rather than one row
    per contract. That shape is what every downstream consumer wants: the OTM
    convention (call IV above the forward, put IV below) needs both sides
    available at the same strike to choose between them.

    parse_expirations defaults to include_zero_dte=False, so same-day expiries
    are excluded from the surface entirely — they carry enormous gamma and
    almost no time value, which distorts a calibration.
    """
    expirations = parse_expirations(chain)
    points = []
    for exp in expirations:
        dte = exp["dte"]
        call_by_strike: dict[float, dict] = {}
        put_by_strike:  dict[float, dict] = {}

        # IV > 0 is the admission test for the surface. A contract Schwab
        # reports with zero IV has no usable vol reading — it is a strike with
        # no market — and including it would drag any fit toward zero.
        for c in exp["calls"]:
            iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
            if iv > 0:
                call_by_strike[float(c["strikePrice"])] = c

        for p in exp["puts"]:
            iv = float(p.get("volatility") or p.get("impliedVolatility") or 0)
            if iv > 0:
                put_by_strike[float(p["strikePrice"])] = p

        # UNION of strikes, so a strike quoted on only one side still yields a
        # point with the other side's fields absent.
        for strike in sorted(set(call_by_strike) | set(put_by_strike)):
            c = call_by_strike.get(strike)
            p = put_by_strike.get(strike)

            call_iv_pct = float(c.get("volatility") or c.get("impliedVolatility") or 0) if c else 0.0
            put_iv_pct  = float(p.get("volatility") or p.get("impliedVolatility") or 0) if p else 0.0

            # _fany, not _fne0 — a genuine zero delta (deep OTM) is real
            # information and must survive, and the prob_itm derivation below
            # depends on distinguishing 0 from missing.
            call_delta = _fany(c, "delta")
            put_delta  = _fany(p, "delta")

            # |delta| ≈ risk-neutral probability of finishing ITM. Approximate
            # (it is really N(d2), and delta is N(d1)), but close enough to be
            # the standard trader's shorthand.
            #
            # The SIGN CHECKS are a data-sanity filter, not just a conversion: a
            # call's delta must be positive and a put's negative, so a
            # sign-flipped field from Schwab yields None rather than a nonsense
            # probability. Clamping to [0,1] guards the same thing at the ends.
            call_prob_itm = max(0.0, min(1.0, call_delta)) if call_delta is not None and call_delta > 0 else None
            put_prob_itm  = max(0.0, min(1.0, abs(put_delta))) if put_delta is not None and put_delta < 0 else None

            # Extractor choice per field family — see jobs/common.py:
            #   _igt0  volumes, open interest, quote sizes (positive ints)
            #   _fne0  gamma/theta/vega/rho — can be negative; 0 means missing
            #   _fgt0  every price field — 0 means no market, not a $0 price
            row: dict = {
                "strike": strike,
                "dte":    dte,
                # PERCENT -> DECIMAL conversion boundary. None (not 0.0) when
                # the side is absent, so a missing quote is distinguishable
                # from a real zero downstream.
                "call_iv": call_iv_pct / 100 if call_iv_pct > 0 else None,
                "put_iv":  put_iv_pct  / 100 if put_iv_pct  > 0 else None,
                "call_vol": _igt0(c, "totalVolume"),
                "put_vol":  _igt0(p, "totalVolume"),
                "call_oi":  _igt0(c, "openInterest"),
                "put_oi":   _igt0(p, "openInterest"),
                "call_delta": call_delta,
                "put_delta":  put_delta,
                "call_gamma": _fne0(c, "gamma"),
                "put_gamma":  _fne0(p, "gamma"),
                "call_theta": _fne0(c, "theta"),
                "put_theta":  _fne0(p, "theta"),
                "call_vega":  _fne0(c, "vega"),
                "put_vega":   _fne0(p, "vega"),
                "call_rho":   _fne0(c, "rho"),
                "put_rho":    _fne0(p, "rho"),
                "call_bid":       _fgt0(c, "bid"),
                "call_ask":       _fgt0(c, "ask"),
                "call_mark":      _fgt0(c, "mark"),
                "call_last":      _fgt0(c, "last"),
                # Schwab's own model value — the basis for the pricing_edge
                # figure in routers/decision.py.
                "call_theo":      _fgt0(c, "theoreticalOptionValue"),
                "call_intrinsic": _fgt0(c, "intrinsicValue"),
                # Schwab calls extrinsic value "timeValue".
                "call_extrinsic": _fgt0(c, "timeValue"),
                "call_high":      _fgt0(c, "highPrice"),
                "call_low":       _fgt0(c, "lowPrice"),
                "put_bid":        _fgt0(p, "bid"),
                "put_ask":        _fgt0(p, "ask"),
                "put_mark":       _fgt0(p, "mark"),
                "put_last":       _fgt0(p, "last"),
                "put_theo":       _fgt0(p, "theoreticalOptionValue"),
                "put_intrinsic":  _fgt0(p, "intrinsicValue"),
                "put_extrinsic":  _fgt0(p, "timeValue"),
                "put_high":       _fgt0(p, "highPrice"),
                "put_low":        _fgt0(p, "lowPrice"),
                # Quote sizes: depth behind the bid/ask, i.e. how real the quote is.
                "call_bid_size": _igt0(c, "bidSize"),
                "call_ask_size": _igt0(c, "askSize"),
                "put_bid_size":  _igt0(p, "bidSize"),
                "put_ask_size":  _igt0(p, "askSize"),
                "call_prob_itm": call_prob_itm,
                "call_prob_otm": 1.0 - call_prob_itm if call_prob_itm is not None else None,
                "put_prob_itm":  put_prob_itm,
                "put_prob_otm":  1.0 - put_prob_itm  if put_prob_itm  is not None else None,
            }
            # STRIP NULLS before storing. This is a real size optimization, not
            # tidiness: most strikes have no quote on one side, and on a wide
            # chain that is thousands of null keys per snapshot in a JSONB
            # column written hourly. Consumers must therefore use .get() and
            # treat an absent key exactly as they would a null.
            points.append({k: v for k, v in row.items() if v is not None})

    return points


def _upsert_vol_surface(
    db, ticker: str, today: str, spot: float, points: list[dict], user_id: str
) -> None:
    """Write the snapshot, overwriting any earlier row for the same day.

    One row per (user, ticker, day). The hourly runs each replace the previous
    one, so the table holds the LATEST intraday surface per day, not a
    within-day series — the final write of the session becomes the day's
    permanent record.

    `parsed_at` is a full UTC timestamp and is the only way to tell how fresh
    the stored surface is; `obs_date` alone cannot distinguish a 9:30 pull from
    a 16:00 one.
    """
    db.table("vol_surface_snapshots").upsert(
        {
            "user_id":    user_id,
            "ticker":     ticker,
            "obs_date":   today,
            "spot_price": spot,
            "points":     points,
            "parsed_at":  datetime.now(timezone.utc).isoformat(),
        },
        on_conflict="user_id,ticker,obs_date",
    ).execute()
