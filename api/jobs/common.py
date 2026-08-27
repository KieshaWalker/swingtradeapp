from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/common.py
# =============================================================================
# Shared helpers used by every pipeline job.
# =============================================================================
#
# FOUR GROUPS OF HELPER LIVE HERE
#   1. Session guards   — should this run happen at all, and is it the EOD one?
#   2. Ticker discovery — which (ticker, user) pairs the pipeline covers.
#   3. Schwab fetches   — chain and price history, via the Supabase edge proxy.
#   4. Field extractors — safe scalar reads out of raw Schwab contract dicts.
#
# THE GOVERNING PRINCIPLE: NOTHING HERE RAISES.
# Every fetch returns None or an empty result on failure, and every extractor
# returns None on bad input. A pipeline job iterates dozens of tickers, and one
# bad symbol, one malformed contract, or one upstream 500 must not abort the
# whole run and lose every other ticker's snapshot for that cycle. Callers are
# expected to check for None and skip, and jobs report per-ticker failures in
# their result dict rather than by throwing.
#
# The cost of that choice is that a systematic failure looks like quiet
# emptiness. Failures are logged at error/warning level, so the logs — not the
# HTTP status — are where a broken run is diagnosed.
# =============================================================================

import logging
from datetime import datetime, time, timezone

import httpx
import pytz

from core.config import settings

log = logging.getLogger(__name__)

# Everything is reasoned about in EASTERN TIME, not UTC. The crons fire on UTC,
# but the market opens on ET, and the offset between them changes twice a year
# with US daylight saving. Converting here means the schedule never needs
# re-cutting for DST — the cron window is deliberately wider than the session
# and these guards trim the edges.
_ET = pytz.timezone("America/New_York")
_MARKET_OPEN = time(9, 30)
# Allow the 4 PM ET close-capture cycle: the staggered jobs of the cycle that
# starts at 16:00 ET keep firing until ~16:20 ET (heston batch 2).
_MARKET_LAST = time(16, 30)


def is_eod_capture_run() -> bool:
    """True when the current run falls in the 4 PM ET close-capture window —
    the last pipeline cycle of the session that market_session_guard admits.
    Jobs use this to mark their daily upsert as the finalized EOD snapshot.

    The intraday jobs upsert the same (ticker, date) row every hour, so the row
    is repeatedly overwritten through the session. This flag is how a job knows
    the write it is about to make is the CLOSING one — the value that should be
    treated as the day's official record rather than an intraday waypoint.

    Note the asymmetry with _MARKET_LAST: this returns True from 16:00 ET
    onward with no upper bound, while the session guard stops admitting runs at
    16:30. The window where both hold is exactly the close-capture cycle.
    """
    now_et = datetime.now(timezone.utc).astimezone(_ET)
    return now_et.time() >= time(16, 0)


def market_session_guard() -> Optional[str]:
    """Return a skip reason when outside US equity market hours (ET), else None.

    The hourly pipeline crons fire around the clock in UTC. Without this guard
    the jobs pull stale after-hours chains overnight and — between 00:00 and
    ~04:00 UTC — write rows under the *next* UTC date using the prior session's
    data (permanent pollution on market holidays).

    Known limitation: market holidays that fall Mon–Fri still run.

    THE DATE-ROLLOVER BUG IS THE IMPORTANT HALF. After-hours data being stale is
    merely useless; a row written under the wrong DATE is actively corrupting.
    Between 00:00 and ~04:00 UTC the ET date is still the PREVIOUS day, so a job
    keying its upsert on the UTC date files the prior session's chain under
    tomorrow — and since the tables key on (ticker, date), the real row for that
    date is later overwritten or blocked. Skipping is the only clean fix.

    Returning a STRING reason rather than a bool lets each job log and report
    exactly why it no-opped, which is what distinguishes an intentional weekend
    skip from a silent failure in the run history.

    The holiday gap is accepted rather than fixed: a market-calendar dependency
    for a handful of days a year, on jobs that upsert idempotently and would
    simply rewrite the prior close, is not worth the maintenance.
    """
    now_et = datetime.now(timezone.utc).astimezone(_ET)
    if now_et.weekday() >= 5:
        return "weekend"
    t = now_et.time()
    if t < _MARKET_OPEN:
        return "before_open"
    if t > _MARKET_LAST:
        return "after_close"
    return None


def _headers() -> dict:
    """Auth headers for the Supabase edge functions.

    The service key, not a Schwab token — this process holds no broker
    credentials. The edge function owns the Schwab OAuth flow and proxies on
    our behalf.
    """
    return {
        "Authorization": f"Bearer {settings.supabase_service_key}",
        "Content-Type": "application/json",
    }


def get_tickers(db) -> list[dict]:
    """Return unique (ticker, user_id) rows from watched_tickers + open trades.

    THE UNIVERSE DEFINITION for the whole pipeline: everything explicitly
    watched, plus anything currently held even if it was never added to a
    watchlist. The second half matters — an open position must keep receiving
    snapshots regardless of watchlist hygiene, or its history develops a gap
    exactly while it is at risk.

    Deduplicated on the (ticker, user_id) PAIR, not on ticker alone, because
    the pipeline is multi-tenant in shape: two users watching the same symbol
    are two rows, and downstream jobs stamp user_id onto what they write.

    NOTE both reads are plain .execute() calls, so each is subject to
    PostgREST's silent 1000-row cap. Not a problem at current scale, but a
    watchlist that ever exceeds 1000 rows would be truncated with no error —
    core.supabase_client.fetch_all() is the fix if that day comes.
    """
    rows = (db.table("watched_tickers").select("ticker,user_id").execute()).data or []
    trades = (
        db.table("trades").select("ticker,user_id").eq("status", "open").execute()
    ).data or []
    seen = {(r["ticker"], r["user_id"]) for r in rows}
    # Appending to `rows` while iterating `trades` (a different list) is safe.
    for r in trades:
        key = (r["ticker"], r["user_id"])
        if key not in seen:
            rows.append(r)
            seen.add(key)
    return rows


async def fetch_schwab_chain(
    client: httpx.AsyncClient,
    ticker: str,
    strike_count: int = 40,
    expiration_date: Optional[str] = None,
) -> Optional[dict]:
    """Fetch options chain via the Supabase edge function. Returns None on failure.

    Pass expiration_date ("YYYY-MM-DD") to fetch a single expiry with a higher
    strike_count without blowing the Apigee payload limit.

    THE PAYLOAD LIMIT IS THE REASON FOR THE SPLIT FETCH. Schwab's gateway caps
    response size, and strike_count applies PER EXPIRATION — so an all-expiry
    request at a high strike count on a liquid name is rejected outright.
    Narrowing to one expiration is what buys the wider strike range, which is
    why routers/fetch_dtes.py takes a list of specific dates rather than just a
    count.

    The default of 40 strikes is tuned for the whole-watchlist scheduled runs:
    wide enough for GEX and skew to be meaningful, narrow enough that the full
    universe fits in the cycle's time budget.

    60s timeout — the longest in the codebase. A full chain on a liquid name is
    a large response and the edge function may itself be cold-starting.

    Returns None on BOTH a non-200 and an exception, logged at error level.
    Callers must treat None as "skip this ticker this cycle".
    """
    body: dict = {"symbol": ticker, "contractType": "ALL", "strikeCount": strike_count}
    if expiration_date:
        body["expirationDate"] = expiration_date
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-chains",
            json=body,
            headers=_headers(),
            timeout=60.0,
        )
        if resp.status_code != 200:
            log.error("chain_fetch_failed ticker=%s status=%s", ticker, resp.status_code)
            return None
        return resp.json()
    except Exception as exc:
        log.error("chain_fetch_error ticker=%s error=%r", ticker, exc)
        return None


async def fetch_schwab_closes(
    client: httpx.AsyncClient, ticker: str, days: int = 65
) -> tuple[list[float], list[float]]:
    """Return (closes, volumes) oldest→newest via the pricehistory edge function.

    OLDEST FIRST is the convention every consumer assumes — realized vol walks
    forward taking ln(P[i]/P[i-1]), and moving averages slice the tail with
    [-n:]. A reversed series yields plausible but wrong numbers rather than an
    error, so do not re-sort.

    The 65-day default covers the longest trailing window the intraday jobs
    need (the 63-close quarterly RV) with a couple of sessions of slack for
    holidays.

    Returns ([], []) rather than None on failure — logged at WARNING, one level
    below the chain fetch, because price history is supplementary for most
    callers while a missing chain means there is nothing to compute at all.
    """
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={"symbol": ticker, "days": days},
            headers=_headers(),
            timeout=30.0,
        )
        if resp.status_code != 200:
            log.warning("pricehistory_failed ticker=%s status=%s", ticker, resp.status_code)
            return [], []
        data = resp.json()
        return data.get("closes", []), data.get("volumes", [])
    except Exception as exc:
        log.warning("pricehistory_error ticker=%s error=%r", ticker, exc)
        return [], []


async def fetch_schwab_ohlc(
    client: httpx.AsyncClient,
    ticker: str,
    days: int = 400,
    frequency_type: str = "daily",
    frequency: int = 1,
) -> list[dict]:
    """Return full OHLCV bars oldest→newest via the pricehistory edge function.

    The sibling of fetch_schwab_closes, and deliberately NOT a replacement for
    it. That function returns two flat lists and is consumed by realized vol,
    the crisis checklist and the moving averages in schwab_pull; rewriting those
    call sites to unpack dicts would be churn with no benefit. This one exists
    because CHANNEL FITTING NEEDS HIGHS AND LOWS — a trendline connects swing
    pivots, and a pivot is a high or a low, so a close-only series cannot
    express one at all.

    Returns a list of dicts rather than six parallel lists because six lists
    that must stay index-aligned is a bug waiting to happen; the alignment is
    the whole meaning of the data.

        [{"date": "2026-08-26", "open": ..., "high": ..., "low": ...,
          "close": ..., "volume": ..., "ts": 1756...}, ...]

    OLDEST FIRST, matching fetch_schwab_closes — every consumer slices the tail
    with [-n:] to get the most recent window. A reversed series yields plausible
    but wrong numbers rather than an error.

    `days` is a candle count, not a calendar span: the edge function trims to
    the last N candles. The 400 default asks for more than the ~252 sessions a
    year returns, which is intentional — it means the caller always receives the
    full year rather than a silently short series, and 252 comfortably covers
    the 200 bars a 200-day SMA needs.

    INTRADAY IS CAPPED BY THE VENDOR. frequency_type="minute" (frequency one of
    1/5/10/15/30) reaches back only ~48 days no matter what `days` asks for, and
    Schwab has no native 4-hour bar — 4h must be aggregated from 30-minute
    candles downstream. Bars that age past that window cannot be re-fetched,
    which is why equity_bars is exempt from retention purges.

    Returns [] rather than None on failure, following the module rule that
    nothing here raises. Malformed bars (a null OHLC field) are dropped
    individually so one bad candle costs one bar, not the ticker.
    """
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-schwab-pricehistory",
            json={
                "symbol":        ticker,
                "days":          days,
                "frequencyType": frequency_type,
                "frequency":     frequency,
            },
            headers=_headers(),
            timeout=45.0,
        )
        if resp.status_code != 200:
            log.warning(
                "ohlc_failed ticker=%s freq=%s status=%s",
                ticker, frequency_type, resp.status_code,
            )
            return []
        data = resp.json()
    except Exception as exc:
        log.warning("ohlc_error ticker=%s error=%r", ticker, exc)
        return []

    dates   = data.get("dates")   or []
    opens   = data.get("opens")   or []
    highs   = data.get("highs")   or []
    lows    = data.get("lows")    or []
    closes  = data.get("closes")  or []
    volumes = data.get("volumes") or []
    stamps  = data.get("timestamps") or []

    # An older deployment of the edge function returned closes/volumes/dates
    # only. Detect that explicitly instead of emitting bars with null OHLC,
    # which would trip the equity_bars sanity constraint on insert and look
    # like a data problem rather than a stale deploy.
    if closes and not (opens and highs and lows):
        log.error(
            "ohlc_missing_fields ticker=%s — get-schwab-pricehistory appears to "
            "predate the OHLC change; redeploy the edge function", ticker,
        )
        return []

    n = min(len(dates), len(opens), len(highs), len(lows), len(closes))
    bars: list[dict] = []
    for i in range(n):
        o, h, l, c = opens[i], highs[i], lows[i], closes[i]
        if None in (o, h, l, c):
            continue
        # Guard the vendor invariant before it reaches the DB constraint. A bar
        # violating it is a glitch, and one bad bar silently skewing a channel
        # fit is worse than a bar that is simply absent.
        if not (l <= o <= h and l <= c <= h):
            log.warning("ohlc_insane ticker=%s date=%s o=%s h=%s l=%s c=%s",
                        ticker, dates[i], o, h, l, c)
            continue
        bars.append({
            "date":   dates[i],
            "open":   o,
            "high":   h,
            "low":    l,
            "close":  c,
            "volume": volumes[i] if i < len(volumes) else None,
            "ts":     stamps[i]  if i < len(stamps)  else None,
        })
    return bars

# ── Scalar field extractors ───────────────────────────────────────────────────
#
# Four near-identical functions that differ ONLY in which values they treat as
# missing. That distinction is the entire point, and picking the wrong one is a
# silent data bug — Schwab uses 0 (and occasionally the string "NaN") as a
# stand-in for "no data" on some fields, while 0 is a perfectly real value on
# others.
#
#   _fgt0   float, must be > 0     — PRICES, IV, STRIKES, GAMMA, VEGA.
#                                    A zero bid means no market, not a $0 option.
#   _fne0   float, must be != 0    — DELTA, THETA, RHO. Legitimately NEGATIVE,
#                                    so a > 0 test would discard every put's
#                                    delta; but zero still means "not supplied".
#   _fany   float, anything        — values where 0 is genuinely meaningful and
#                                    must be preserved.
#   _igt0   int, must be > 0       — OPEN INTEREST, VOLUME. Zero is real
#                                    (nothing traded) but is treated as absent
#                                    here, since a zero-OI strike contributes
#                                    nothing to any exposure sum anyway.
#
# All four take Optional[dict] and return None for a missing contract, so a
# caller can chain them off a lookup that may have failed without a null check.
# All four swallow TypeError/ValueError, so a Schwab string like "NaN" or None
# becomes None rather than propagating.

def _fgt0(contract:Optional[dict], key: str) ->Optional[float]:
    """Float, but only if strictly positive. For prices, IVs, strikes, gamma."""
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f > 0 else None
    except (TypeError, ValueError):
        return None


def _fne0(contract:Optional[dict], key: str) ->Optional[float]:
    """Float, but only if non-zero. For delta/theta/rho, which go negative."""
    if contract is None:
        return None
    v = contract.get(key)
    try:
        f = float(v)
        return f if f != 0 else None
    except (TypeError, ValueError):
        return None


def _fany(contract:Optional[dict], key: str) ->Optional[float]:
    """Float, zero included. For fields where 0 is a real reading."""
    if contract is None:
        return None
    v = contract.get(key)
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _igt0(contract:Optional[dict], key: str) ->Optional[int]:
    """Int, but only if strictly positive. For open interest and volume."""
    if contract is None:
        return None
    v = contract.get(key)
    try:
        i = int(v)
        return i if i > 0 else None
    except (TypeError, ValueError):
        return None


def _pct_to_dec(value) ->Optional[float]:
    """Convert a Schwab percent IV (21.0) to the decimal form (0.21).

    The boundary between the two IV conventions in this codebase. Raw chain
    fields are percent; the pricing and calibration services take decimals.
    Takes a bare value rather than (contract, key) because callers usually
    already extracted it via one of the functions above.
    """
    if value is None:
        return None
    try:
        return float(value) / 100.0
    except (TypeError, ValueError):
        return None


def _atm_contract(contracts: list[dict]) ->Optional[dict]:
    """Pick the at-the-money contract: the one nearest |delta| = 0.50.

    DELTA, NOT STRIKE DISTANCE, defines ATM here. Delta already accounts for
    time to expiry and vol, so 50-delta is the true at-the-money in the sense
    that matters for reading an ATM vol — whereas the nearest strike to spot
    drifts away from it as expiry lengthens.

    Contracts with a missing or zero delta are excluded first (the `c["delta"]
    and` guard also filters None), so this returns None when the chain has no
    usable deltas at all rather than picking an arbitrary contract.

    Works for calls and puts alike because of the inner abs(): a put's -0.50
    is just as at-the-money as a call's +0.50.
    """
    if not contracts:
        return None
    with_delta = [c for c in contracts if c.get("delta") and c["delta"] != 0]
    if not with_delta:
        return None
    return min(with_delta, key=lambda c: abs(abs(c["delta"]) - 0.50))
