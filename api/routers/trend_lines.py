from __future__ import annotations

# =============================================================================
# routers/trend_lines.py  —  mounted at /trend-lines
# =============================================================================
# Two endpoints, both STATELESS from this router's point of view — neither
# reads nor writes the trend_lines table itself. Saving, renaming, listing and
# deleting a line are plain Supabase CRUD against a user-owned, RLS-protected
# table, done directly from Flutter (same pattern as target_levels and
# watched_tickers). This router exists only for the two things that genuinely
# need Python: fitting a line, and testing one against price history.
#
#   POST /trend-lines/suggest    ticker + tolerance overrides -> candidate
#                                 resistance/support lines to choose from
#   POST /trend-lines/accuracy   a saved line's two anchors -> how it has held
#                                 up against every bar printed since
#
# Client counterpart: lib/services/python_api/python_api_client.dart
# Math implementation: services/channel_fit.py (suggest_trendlines,
#                       track_line_accuracy)
#
# WHY CANDIDATES, NOT A CHANNEL. fit_channel() auto-pairs one upper and one
# lower line into a single channel. /suggest deliberately does not — it hands
# back the raw resistance and support shortlists so the caller can offer
# several distinct lines on each side and let the user pick individually,
# matching "multiple lines can be added" rather than one computed structure.
#
# WHY DATES CROSS THE WIRE, NOT BAR INDICES. A bar index is only meaningful
# paired with the exact array it was computed against, which no client outside
# this process has. Every response and request boundary here uses ticker +
# calendar date; bar-index math is entirely internal to this file.
# =============================================================================

from datetime import date, timedelta
from typing import List, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from core.supabase_client import get_supabase
from services.channel_fit import (
    LineAccuracy,
    TrendLine,
    suggest_trendlines,
    track_line_accuracy,
)

router = APIRouter()

# Daily bars fed to the fit. ~6 months — long enough to contain several
# swings, short enough that the structure still describes the current market.
# Matches the window the (now-removed) batch screener used, kept here as the
# one place this constant needs to live.
_LOOKBACK_BARS = 120

# ATR needs a runway of prior bars to mean anything at the START of a tracked
# window; without it the first few accuracy checks would divide by a near-zero
# or undefined ATR. 30 calendar days comfortably covers the 14-bar ATR window
# even across a long weekend or holiday.
_ATR_WARMUP_DAYS = 30


def _fetch_bars(ticker: str, start: Optional[str], limit: int) -> list[dict]:
    """Daily equity_bars for one ticker, OLDEST FIRST, from `start` if given.

    Ordered descending and reversed — the documented way around PostgREST's
    silent 1000-row cap for "the latest N bars", used identically in
    jobs/swing_setups_pull.py before it was removed and jobs/equity_bars_pull.py.
    """
    db = get_supabase()
    q = (
        db.table("equity_bars")
        .select("bar_date,high,low,close")
        .eq("ticker", ticker).eq("timeframe", "daily")
    )
    if start:
        q = q.gte("bar_date", start)
    rows = (
        q.order("bar_date", desc=True).limit(limit).execute()
    ).data or []
    rows.reverse()
    return rows


def _nearest_index(dates: List[str], target: str) -> Optional[int]:
    """Index of the bar on or before `target`, or the earliest bar if none is.

    Exists because a FITTED line's anchor dates are always exact bar dates (they
    came from equity_bars), but a MANUAL line's anchors are whatever date the
    user typed — a weekend, a holiday, or simply a mis-click — and the feature
    should not hard-fail over that. Falling back to the nearest prior session is
    the same convention a chart itself uses when you click between two candles.
    """
    if not dates:
        return None
    idx = None
    for i, d in enumerate(dates):
        if d <= target:
            idx = i
        else:
            break
    return idx if idx is not None else 0


# ── /suggest ──────────────────────────────────────────────────────────────────

class SuggestRequest(BaseModel):
    ticker: str
    strength: int = Field(3, ge=1, le=10)
    touch_atr: float = Field(0.55, gt=0, le=5.0)
    break_atr: float = Field(1.10, gt=0, le=5.0)
    min_touches: int = Field(3, ge=2, le=20)
    min_span_frac: float = Field(0.35, gt=0, le=1.0)


class LineCandidate(BaseModel):
    anchor1_date: str
    anchor1_price: float
    anchor2_date: str
    anchor2_price: float
    touches: int
    span_bars: int
    tightness: float
    score: float


class SuggestResponse(BaseModel):
    ticker: str
    bars_used: int
    resistance: List[LineCandidate]
    support: List[LineCandidate]


def _to_candidates(lines: List[TrendLine], prices: List[float],
                    dates: List[str]) -> List[LineCandidate]:
    """Map a TrendLine's bar-index anchors to real (date, price) pairs.

    Anchor prices come from the ACTUAL series the line was fit against (the
    exact high or low it passes through), not line.value_at(idx) — those are
    equal by construction, but reading the real value keeps this immune to any
    future floating-point-only change in the fit.
    """
    return [
        LineCandidate(
            anchor1_date=dates[t.start_idx], anchor1_price=prices[t.start_idx],
            anchor2_date=dates[t.end_idx], anchor2_price=prices[t.end_idx],
            touches=t.touches, span_bars=t.span_bars,
            tightness=round(t.tightness, 4), score=round(t.score, 4),
        )
        for t in lines
    ]


@router.post("/suggest", response_model=SuggestResponse)
async def suggest(req: SuggestRequest):
    """Candidate resistance/support lines for a ticker, at the caller's own
    tolerance settings — the backend for the "algorithmic add" flow.
    """
    bars = _fetch_bars(req.ticker, None, _LOOKBACK_BARS)
    if len(bars) < 30:
        raise HTTPException(422, f"insufficient bar history for {req.ticker} "
                                  f"({len(bars)} bars, need at least 30)")

    highs = [float(b["high"]) for b in bars]
    lows = [float(b["low"]) for b in bars]
    closes = [float(b["close"]) for b in bars]
    dates = [b["bar_date"] for b in bars]

    upper, lower = suggest_trendlines(
        highs, lows, closes,
        strength=req.strength, touch_atr=req.touch_atr, break_atr=req.break_atr,
        min_touches=req.min_touches, min_span_frac=req.min_span_frac,
    )
    return SuggestResponse(
        ticker=req.ticker,
        bars_used=len(bars),
        resistance=_to_candidates(upper, highs, dates),
        support=_to_candidates(lower, lows, dates),
    )


# ── /accuracy ─────────────────────────────────────────────────────────────────

class AccuracyRequest(BaseModel):
    ticker: str
    anchor1_date: str
    anchor1_price: float
    anchor2_date: str
    anchor2_price: float
    # None for a manual line with no assumed side — see track_line_accuracy.
    kind: Optional[str] = Field(None, pattern="^(support|resistance)$")


class AccuracyResponse(BaseModel):
    bars_checked: int
    touches: int
    violations: int
    first_violation_date: Optional[str] = None
    max_deviation_atr: Optional[float] = None
    status: Optional[str] = None  # holding | broken | None (manual, no verdict)


@router.post("/accuracy", response_model=AccuracyResponse)
async def accuracy(req: AccuracyRequest):
    """How a saved line has held up against every bar printed since it was
    drawn — recomputed fresh on every call, nothing is cached or stored.
    """
    warmup_start = (
        date.fromisoformat(req.anchor1_date) - timedelta(days=_ATR_WARMUP_DAYS)
    ).isoformat()
    bars = _fetch_bars(req.ticker, warmup_start, 1000)
    if len(bars) < 15:
        raise HTTPException(422, f"insufficient bar history for {req.ticker} "
                                  f"to evaluate this line ({len(bars)} bars)")

    highs = [float(b["high"]) for b in bars]
    lows = [float(b["low"]) for b in bars]
    closes = [float(b["close"]) for b in bars]
    dates = [b["bar_date"] for b in bars]

    idx1 = _nearest_index(dates, req.anchor1_date)
    idx2 = _nearest_index(dates, req.anchor2_date)
    if idx1 is None or idx2 is None or idx2 <= idx1:
        raise HTTPException(422, "anchor2_date must fall after anchor1_date "
                                  "within the available bar history")

    slope = (req.anchor2_price - req.anchor1_price) / (idx2 - idx1)
    intercept = req.anchor1_price - slope * idx1

    acc: LineAccuracy = track_line_accuracy(
        highs, lows, closes, slope, intercept, start_idx=idx2,
        kind=req.kind,
    )
    return AccuracyResponse(
        bars_checked=acc.bars_checked,
        touches=acc.touches,
        violations=acc.violations,
        first_violation_date=(
            dates[acc.first_violation_idx]
            if acc.first_violation_idx is not None else None
        ),
        max_deviation_atr=acc.max_deviation_atr,
        status=acc.status,
    )
