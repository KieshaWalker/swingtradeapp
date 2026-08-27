from __future__ import annotations

# =============================================================================
# jobs/expected_move_pull.py
# =============================================================================
# Job 9 — EOD chain → expected_move_snapshots (daily / weekly / monthly bands).
# Cron: 0 21 * * 1-5   (weekdays 9 PM UTC — after US market close at ~8 PM UTC)
#
# Runs ONCE per day at close, NOT hourly.  The intraday 4 PM UTC guard used
# by jobs 1-7 does NOT apply here — this job IS the end-of-day capture.
#
# For each ticker, fetches the EOD chain and computes expected-move bands at
# three DTE targets:
#   daily   → DTE ≈ 1   (tomorrow's expiry)
#   weekly  → DTE ≈ 7   (next-Friday expiry)
#   monthly → DTE ≈ 30  (front-month expiry)
#
# All three are upserted as separate rows in expected_move_snapshots.
# =============================================================================
#
# EXPECTED MOVE is the market's own forecast of how far a stock travels by a
# given expiry, read straight out of ATM implied vol:
#
#     EM = spot x IV x sqrt(DTE / 365)
#
# i.e. one standard deviation of the lognormal distribution the options are
# priced under. The ±1σ / ±2σ / ±3σ bands are what the app draws as expected-move
# cones, and they are the reference every directional thesis gets checked
# against — a price target inside the 1σ band is what the market already expects,
# not an edge.
#
# THIS JOB ALSO WRITES REALIZED VOL, which the header does not mention and the
# name does not suggest. realized_vol_snapshots is populated here (rv_1d, rv_5d,
# rv_21d, rv_63d plus percentile ranks), sharing this job's daily close-time
# slot and its price-history fetch. Together the two tables give the IV/RV
# comparison: EM is what the market EXPECTS, RV is what actually HAPPENED.
#
# RV must be computed here in the Python backend and read from the DB by the
# app — never recomputed in Flutter. jobs/backfill_rv.py is the historical
# counterpart writing the same table.
#
# NO market_session_guard() CALL — deliberate, and noted in the header above.
# That guard rejects anything after 16:30 ET, which is exactly when this job
# runs. Its 21:00 UTC slot is already after the close, so the hazard the guard
# defends against does not apply.
#
# The header says three DTE targets; _DTE_TARGETS actually has four (quarterly
# was added later). Trust the code.

import asyncio
import logging
import math
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from core.chain_utils import parse_expirations
from jobs.common import get_tickers, fetch_schwab_chain, fetch_schwab_closes
from services.expected_move import compute as em_compute, atm_iv_from_chain
from core.constants import RV_MIN_HISTORY_PCT
from services.realized_vol import compute_rv, compute_percentile

log = logging.getLogger(__name__)

# Period buckets and their DTE anchors. atm_iv_from_chain picks the NEAREST
# available expiry to each target and reports the DTE it actually found, which
# is what gets priced — so these are anchors, not requirements. The stored `dte`
# column records the real value; do not assume it equals the target.
#
# The four map onto the same buckets routers/fair_value.py uses for its
# term-matched IV/RV comparison, which is what makes those two comparable.
_DTE_TARGETS = {
    "daily":     1,
    "weekly":    7,
    "monthly":  30,
    "quarterly": 90,   # 3-month option comparison
}


_CONCURRENCY = 5


async def run_expected_move_pull() -> dict:
    """Capture closing expected-move bands and realized vol for every ticker."""
    db     = get_supabase()
    today  = date.today().isoformat()
    rows   = get_tickers(db)
    if not rows:
        log.warning("expected_move_pull: no tickers")
        return {"status": "no_tickers"}

    # Market-wide table — deduplicate to unique tickers
    # Both tables this job writes (expected_move_snapshots keyed
    # (ticker, date, period_type) and realized_vol_snapshots keyed
    # (symbol, date)) are GLOBAL, with no user_id: expected move and realized
    # vol are properties of the underlying, not of who watches it.
    unique_tickers = list({r["ticker"] for r in rows})
    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    # Prefetch RV history for all tickers before the concurrent HTTP section so
    # synchronous DB reads don't interleave with async HTTP calls.
    # The supabase-py client is synchronous: a .execute() inside _process would
    # stall the whole event loop, including every other ticker's in-flight HTTP
    # request. Same hoisting pattern as iv_pull.
    rv_history: dict[str, tuple[list[float], list[float]]] = {
        t: _fetch_rv_history(db, t, today) for t in unique_tickers
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(ticker: str) -> tuple[str, str]:
            async with sem:
                try:
                    # Both fetches issued concurrently — they are independent,
                    # and the chain is the slower of the two.
                    # 100 CALENDAR days is ~70 trading days, which covers the
                    # 63 closes rv_63d needs with room for holidays.
                    (chain, (closes, _)) = await asyncio.gather(
                        fetch_schwab_chain(client, ticker),
                        fetch_schwab_closes(client, ticker, days=100),  # ~70 trading days; needs 63 for rv_63d
                    )

                    # Write RV regardless of whether the chain succeeded
                    # The two outputs are INDEPENDENT: realized vol needs only
                    # price history, so a failed chain fetch must not also cost
                    # the RV row. This block therefore runs before the
                    # chain-is-None check below, and has its own try/except so
                    # an RV write failure does not abort the expected-move work
                    # either.
                    # Sanity band, not just a null filter: prices outside
                    # $0.01-$1M are data glitches, and one bad tick inside a log
                    # return produces an enormous spurious vol that would then
                    # poison every percentile ranked against this row.
                    clean_closes = [c for c in closes if c and 0.01 < c < 1_000_000]
                    if len(clean_closes) >= 2:
                        # rv_1d is a single-return estimator — |ln(P/P₋₁)| x
                        # sqrt(252) — not a sample standard deviation. Very
                        # noisy by construction; a "how big was today" marker
                        # rather than a vol estimate. The windowed values below
                        # use the proper Bessel-corrected formula.
                        rv1d  = abs(math.log(clean_closes[-1] / clean_closes[-2])) * math.sqrt(252)
                        rv5d  = compute_rv(clean_closes[-5:]  if len(clean_closes) >= 5  else clean_closes)
                        rv21d = compute_rv(clean_closes[-21:] if len(clean_closes) >= 21 else clean_closes)
                        rv63d = compute_rv(clean_closes[-63:] if len(clean_closes) >= 63 else clean_closes)

                        # Percentiles are computed only with enough history to
                        # mean something; below RV_MIN_HISTORY_PCT observations
                        # the value is left NULL rather than being ranked
                        # against a handful of points.
                        hist21, hist63 = rv_history.get(ticker, ([], []))
                        rv21d_pct = compute_percentile(rv21d, hist21) if len(hist21) >= RV_MIN_HISTORY_PCT else None
                        rv63d_pct = compute_percentile(rv63d, hist63) if len(hist63) >= RV_MIN_HISTORY_PCT else None

                        try:
                            _upsert_rv(db, ticker, today, rv1d, rv5d, rv21d, rv63d, rv21d_pct, rv63d_pct)
                            log.info("rv_ok ticker=%s rv1d=%.3f rv5d=%.3f rv21d=%.3f rv63d=%.3f rv21d_pct=%s rv63d_pct=%s",
                                     ticker, rv1d, rv5d, rv21d, rv63d,
                                     f"{rv21d_pct:.1f}" if rv21d_pct is not None else "n/a",
                                     f"{rv63d_pct:.1f}" if rv63d_pct is not None else "n/a")
                        except Exception as exc:
                            log.error("rv_upsert_failed ticker=%s error=%r", ticker, exc)
                    else:
                        log.warning("rv_skip ticker=%s closes=%d", ticker, len(clean_closes))

                    # From here on it is expected-move work; RV has already been
                    # written above if it could be.
                    if chain is None:
                        return ticker, "chain_error"

                    spot = float(chain.get("underlyingPrice", 0))
                    if spot <= 0:
                        return ticker, "zero_spot"

                    expirations = parse_expirations(chain)
                    if not expirations:
                        return ticker, "no_expirations"

                    slices_written = 0
                    for period_type, target_dte in _DTE_TARGETS.items():
                        # Returns the ATM IV of the nearest expiry to the
                        # target AND that expiry's real DTE — the band must be
                        # scaled by the tenor actually priced, not the one asked
                        # for, or a "weekly" band built off a 10-day expiry
                        # would be understated by ~20%.
                        iv, actual_dte = atm_iv_from_chain(expirations, spot, target_dte)
                        if iv is None or iv <= 0 or actual_dte is None:
                            log.warning(
                                "expected_move_no_iv ticker=%s period=%s target_dte=%d",
                                ticker, period_type, target_dte,
                            )
                            continue

                        result = em_compute(spot=spot, iv=iv, dte=actual_dte)
                        _upsert(db, ticker, today, spot, period_type, result)
                        slices_written += 1
                        log.info(
                            "em_ok ticker=%s period=%s dte=%d iv=%.3f em=$%.2f (%.2f%%)",
                            ticker, period_type, actual_dte, iv,
                            result.em_dollars, result.em_pct,
                        )

                    return ticker, f"ok:{slices_written}"
                except Exception as exc:
                    log.error("expected_move_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                    return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(t) for t in unique_tickers]))

    return {"status": "complete", "tickers": results, "date": today}


def _fetch_rv_history(db, ticker: str, before_date: str) -> tuple[list[float], list[float]]:
    """Fetch the most recent 252 prior days of rv_21d / rv_63d for percentile
    ranking (excludes before_date / today).

    Order desc: ascending order with a limit returns the *oldest* 252 rows once
    the table outgrows the limit — with multi-year backfilled history that
    ranked today's RV against data from years ago.

    252 rows is one trading year — the standard ranking window, matching the
    52-week convention used for IV rank.

    `.lt(before_date)` excludes today so the current value is not ranked against
    a window that already contains it, which would bias every percentile toward
    the middle. The two series are filtered independently, so a row missing
    rv_63d still contributes its rv_21d.
    """
    resp = (
        db.table("realized_vol_snapshots")
        .select("rv_21d,rv_63d")
        .eq("symbol", ticker)
        .lt("date", before_date)
        .order("date", desc=True)
        .limit(252)
        .execute()
    )
    rows = resp.data or []
    hist21 = [float(r["rv_21d"]) for r in rows if r.get("rv_21d") is not None]
    hist63 = [float(r["rv_63d"]) for r in rows if r.get("rv_63d") is not None]
    return hist21, hist63


def _upsert_rv(
    db,
    ticker: str,
    today: str,
    rv1d: float,
    rv5d: float,
    rv21d: float,
    rv63d: float,
    rv21d_pct: float | None,
    rv63d_pct: float | None,
) -> None:
    db.table("realized_vol_snapshots").upsert(
        {
            "symbol":       ticker,
            "date":         today,
            "rv_1d":        rv1d,
            "rv_5d":        rv5d,
            "rv_21d":       rv21d,
            "rv_63d":       rv63d,
            "rv_21d_pct":   rv21d_pct,
            "rv_63d_pct":   rv63d_pct,
            "persisted_at": datetime.now(timezone.utc).isoformat(),
        },
        on_conflict="symbol,date",
    ).execute()


def _upsert(db, ticker: str, today: str, spot: float, period_type: str, result) -> None:
    """Write one period band. Also reused by jobs/ticker_dtes_pull.py.

    Keyed (ticker, date, period_type), so the four periods are four separate
    rows for the same day rather than four columns.

    Wrapped in its own try/except — unlike most upserts here — because this is
    called in a loop over periods and one bad band must not cost the others.
    The failure is logged and the loop continues, so `slices_written` under-
    reports rather than the job erroring.

    `spot` and `iv` are stored alongside the bands so a historical row can be
    re-derived and audited without needing the original chain.
    """
    try:
        db.table("expected_move_snapshots").upsert(
            {
                "ticker":      ticker,
                "date":        today,
                "period_type": period_type,
                "spot":        spot,
                "iv":          result.iv,
                "dte":         result.dte,
                "em_dollars":  result.em_dollars,
                "em_pct":      result.em_pct,
                "upper_1s":    result.upper_1s,
                "lower_1s":    result.lower_1s,
                "upper_2s":    result.upper_2s,
                "lower_2s":    result.lower_2s,
                "upper_3s":    result.upper_3s,
                "lower_3s":    result.lower_3s,
                "computed_at": datetime.now(timezone.utc).isoformat(),
            },
            on_conflict="ticker,date,period_type",
        ).execute()
    except Exception as exc:
        log.error("expected_move_upsert_failed ticker=%s period=%s error=%r", ticker, period_type, exc)
