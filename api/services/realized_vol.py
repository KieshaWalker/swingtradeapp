from __future__ import annotations
from typing import Optional

# =============================================================================
# services/realized_vol.py
# =============================================================================
# Realized volatility computation.
# Exact port of RealizedVolService from realized_vol_service.dart.
#
# Formula: RV_n = √(Σ(ln(P_i / P_{i-1}))² / (n-1)) × √252
#   where (n-1) is the Bessel correction for sample variance.
# =============================================================================
#
# REALIZED VOL IS THE DENOMINATOR OF THE MOST USEFUL RATIO IN THE APP. Implied
# vol says what the market EXPECTS; realized says what actually HAPPENED. IV
# persistently above RV is the variance risk premium — the reason systematic
# premium selling works — and a collapse in that spread is usually the signal.
#
# THIS MUST NOT BE REIMPLEMENTED IN FLUTTER. The app reads RV from the database,
# written by jobs/expected_move_pull.py (daily) and jobs/backfill_rv.py
# (historical). A second implementation on the client would inevitably drift
# from this one, and every richness judgement downstream rests on the two
# agreeing.
#
# TWO CONVENTIONS THAT MUST NOT BE SWAPPED:
#   * ZERO-MEAN. The variance is the mean SQUARED return, not the variance about
#     the sample mean — Σr²/(n−1), with no subtraction of r̄. Standard for
#     realized vol: over short windows the drift estimate is pure noise, and
#     subtracting it would remove real volatility.
#   * 252 TRADING DAYS, not 365. RV is built from daily RETURNS, which only occur
#     on trading days. Expected move and Black-Scholes use ACT/365 because they
#     price over calendar time. Mixing the two rescales vol by ~1.2x.

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum

from core.constants import (
    RV_PRICES_20D,
    RV_PRICES_60D,
    RV_MIN_HISTORY_PCT,
    RV_TRADING_DAYS_YEAR,
)


class RealizedVolRating(str, Enum):
    extreme = "extreme"
    elevated = "elevated"
    normal = "normal"
    suppressed = "suppressed"
    extreme_low = "extreme_low"
    no_data = "no_data"


@dataclass
class RealizedVolResult:
    rv20d: float
    rv60d: float
    rv20d_percentile:Optional[float]
    rv60d_percentile:Optional[float]
    rating: RealizedVolRating
    rv20d_history: list[float] = field(default_factory=list)
    rv60d_history: list[float] = field(default_factory=list)
    computed_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


# ── Core estimator ────────────────────────────────────────────────────────────

def compute_rv(prices: list[float]) -> float:
    """Compute annualized realized vol from a list of daily closes (oldest first).

    Uses Bessel correction (divide by n-1) for sample variance.
    Annualizes with 252 trading days per year.

    Matches RealizedVolService._computeRv() exactly.
    """
    # Returns 0.0 (not None) when uncomputable — a legacy of the Dart port.
    # jobs/backfill_rv.py wraps this specifically to convert 0.0 back to None
    # before storing, because a stored zero would be read as "the stock did not
    # move" rather than "not computable".
    if len(prices) < 2:
        return 0.0
    sum_sq = 0.0
    n_valid = 0
    for i in range(1, len(prices)):
        # Non-positive prices are skipped rather than aborting. Note this
        # SPLICES the series — the return across a gap is dropped entirely, not
        # computed across it — so a bad tick costs one observation instead of
        # injecting a huge spurious return.
        if prices[i - 1] <= 0 or prices[i] <= 0:
            continue
        # LOG returns, not simple returns: they are additive across periods and
        # symmetric (a fall and its reversing rise cancel exactly), which is what
        # the log-normal model the option pricers assume actually requires.
        log_ret = math.log(prices[i] / prices[i - 1])
        sum_sq += log_ret * log_ret
        n_valid += 1
    if n_valid < 2:
        return 0.0
    # Bessel correction (n−1). Note there is NO mean subtraction — see the
    # zero-mean note in the header.
    variance = sum_sq / (n_valid - 1)
    # Annualize by scaling VARIANCE by 252, then take the root — equivalent to
    # multiplying the daily vol by √252, and the reason vol scales with √time.
    return math.sqrt(variance * RV_TRADING_DAYS_YEAR)


def compute_percentile(current: float, history: list[float]) -> float:
    """Percentile rank: what % of historical values are <= current.

    Matches RealizedVolService._computePercentile() exactly.
    """
    # An empty history yields the neutral midpoint rather than None, so callers
    # that skip the length check still get a usable number. compute() below
    # applies its own RV_MIN_HISTORY_PCT gate and returns None instead, which is
    # the more honest path — prefer that.
    if not history:
        return 50.0
    # `<=` is inclusive, so a value equal to every historical observation ranks
    # at 100 rather than 0.
    count_below = sum(1 for v in history if v <= current)
    return (count_below / len(history)) * 100.0


# Bands are deliberately asymmetric: 'normal' spans 40-60 while 'suppressed'
# spans 15-40. Suppressed vol persists for long stretches, so a wider band
# there avoids labelling ordinary quiet markets as extreme.
def _rate_rv(percentile: float) -> RealizedVolRating:
    """Matches RealizedVolService._rateRealizedVol()."""
    if percentile > 80:
        return RealizedVolRating.extreme
    if percentile > 60:
        return RealizedVolRating.elevated
    if percentile > 40:
        return RealizedVolRating.normal
    if percentile > 15:
        return RealizedVolRating.suppressed
    return RealizedVolRating.extreme_low


def compute(
    closes: list[float],
    history_rv20d:Optional[list[float]] = None,
    history_rv60d:Optional[list[float]] = None,
) -> RealizedVolResult:
    """Compute RV and rank it against historical values.

    Args:
        closes: Daily close prices, oldest first. Must have >= 2 elements.
        history_rv20d: Historical 20-day RV values for percentile ranking.
        history_rv60d: Historical 60-day RV values for percentile ranking.

    Returns:
        RealizedVolResult with rv20d, rv60d, percentiles, and rating.
    """
    if len(closes) < 2:
        return RealizedVolResult(
            rv20d=0.0, rv60d=0.0,
            rv20d_percentile=None, rv60d_percentile=None,
            rating=RealizedVolRating.no_data,
        )

    # TWO HORIZONS, answering different questions: rv20d is the current state
    # (what vol IS), rv60d the baseline (what vol HAS BEEN). rv20d well above
    # rv60d means volatility is expanding.
    #
    # Short series are NOT rejected — the estimate falls back to whatever closes
    # exist, so a 10-day series still returns a value labelled rv20d. Noisier,
    # but present. The constants are CLOSE counts, one more than the return
    # counts their names imply (21 closes -> 20 returns).
    rv20d = compute_rv(closes[-RV_PRICES_20D:] if len(closes) >= RV_PRICES_20D else closes)
    rv60d = compute_rv(closes[-RV_PRICES_60D:] if len(closes) >= RV_PRICES_60D else closes)

    hist20 = history_rv20d or []
    hist60 = history_rv60d or []

    rv20d_pct = compute_percentile(rv20d, hist20) if len(hist20) >= RV_MIN_HISTORY_PCT else None
    rv60d_pct = compute_percentile(rv60d, hist60) if len(hist60) >= RV_MIN_HISTORY_PCT else None

    # Rating is derived from the 20-DAY percentile only — the current-state
    # measure — defaulting to the neutral 50.0 when unavailable. Consequence: an
    # unrankable series always rates 'normal', which is indistinguishable in the
    # output from a genuinely mid-range reading. Check rv20d_percentile for None
    # to tell them apart.
    rating = _rate_rv(rv20d_pct if rv20d_pct is not None else 50.0)

    # Trailing history echoed back for charting. When none was supplied, a
    # single-element list holding the value just computed is substituted, so the
    # field is never empty and the client always has something to plot.
    rv20d_hist = hist20[-20:] if hist20 else [rv20d]
    rv60d_hist = hist60[-60:] if hist60 else [rv60d]

    return RealizedVolResult(
        rv20d=rv20d,
        rv60d=rv60d,
        rv20d_percentile=rv20d_pct,
        rv60d_percentile=rv60d_pct,
        rating=rating,
        rv20d_history=rv20d_hist,
        rv60d_history=rv60d_hist,
    )
