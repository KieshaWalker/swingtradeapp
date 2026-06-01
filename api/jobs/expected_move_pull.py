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

_DTE_TARGETS = {
    "daily":     1,
    "weekly":    7,
    "monthly":  30,
    "quarterly": 90,   # 3-month option comparison
}


_CONCURRENCY = 5


async def run_expected_move_pull() -> dict:
    db     = get_supabase()
    today  = date.today().isoformat()
    rows   = get_tickers(db)
    if not rows:
        log.warning("expected_move_pull: no tickers")
        return {"status": "no_tickers"}

    # Market-wide table — deduplicate to unique tickers
    unique_tickers = list({r["ticker"] for r in rows})
    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    # Prefetch RV history for all tickers before the concurrent HTTP section so
    # synchronous DB reads don't interleave with async HTTP calls.
    rv_history: dict[str, tuple[list[float], list[float]]] = {
        t: _fetch_rv_history(db, t) for t in unique_tickers
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        async def _process(ticker: str) -> tuple[str, str]:
            async with sem:
                try:
                    (chain, (closes, _)) = await asyncio.gather(
                        fetch_schwab_chain(client, ticker),
                        fetch_schwab_closes(client, ticker, days=100),  # ~70 trading days; needs 63 for rv_63d
                    )

                    # Write RV regardless of whether the chain succeeded
                    clean_closes = [c for c in closes if c and 0.01 < c < 1_000_000]
                    if len(clean_closes) >= 2:
                        rv1d  = abs(math.log(clean_closes[-1] / clean_closes[-2])) * math.sqrt(252)
                        rv5d  = compute_rv(clean_closes[-5:]  if len(clean_closes) >= 5  else clean_closes)
                        rv21d = compute_rv(clean_closes[-21:] if len(clean_closes) >= 21 else clean_closes)
                        rv63d = compute_rv(clean_closes[-63:] if len(clean_closes) >= 63 else clean_closes)

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


def _fetch_rv_history(db, ticker: str) -> tuple[list[float], list[float]]:
    """Fetch historical rv_21d and rv_63d for percentile ranking (excludes today)."""
    resp = (
        db.table("realized_vol_snapshots")
        .select("rv_21d,rv_63d")
        .eq("symbol", ticker)
        .order("date", desc=False)
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
