from __future__ import annotations

# =============================================================================
# services/realized_vol.py
# =============================================================================
# Realized volatility computation.
# Exact port of RealizedVolService from realized_vol_service.dart.
#
# Formula: RV_n = √(Σ(ln(P_i / P_{i-1}))² / (n-1)) × √252
#   where (n-1) is the Bessel correction for sample variance.
# =============================================================================

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum

from core.constants import (
    RV_WINDOW_20D,
    RV_WINDOW_60D,
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
    rv20d_percentile: float | None
    rv60d_percentile: float | None
    rating: RealizedVolRating
    rv20d_history: list[float] = field(default_factory=list)
    rv60d_history: list[float] = field(default_factory=list)
    computed_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


def compute_rv(prices: list[float]) -> float:
    """Compute annualized realized vol from a list of daily closes (oldest first).

    Uses Bessel correction (divide by n-1) for sample variance.
    Annualizes with 252 trading days per year.

    Matches RealizedVolService._computeRv() exactly.
    """
    if len(prices) < 2:
        return 0.0
    sum_sq = 0.0
    for i in range(1, len(prices)):
        if prices[i - 1] <= 0:
            continue
        log_ret = math.log(prices[i] / prices[i - 1])
        sum_sq += log_ret * log_ret
    variance = sum_sq / (len(prices) - 1)
    return math.sqrt(variance * RV_TRADING_DAYS_YEAR)


def compute_percentile(current: float, history: list[float]) -> float:
    """Percentile rank: what % of historical values are <= current.

    Matches RealizedVolService._computePercentile() exactly.
    """
    if not history:
        return 50.0
    count_below = sum(1 for v in history if v <= current)
    return (count_below / len(history)) * 100.0


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
    history_rv20d: list[float] | None = None,
    history_rv60d: list[float] | None = None,
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

    rv20d = compute_rv(closes[-RV_WINDOW_20D:] if len(closes) >= RV_WINDOW_20D else closes)
    rv60d = compute_rv(closes[-RV_WINDOW_60D:] if len(closes) >= RV_WINDOW_60D else closes)

    hist20 = history_rv20d or []
    hist60 = history_rv60d or []

    rv20d_pct = compute_percentile(rv20d, hist20) if len(hist20) >= RV_MIN_HISTORY_PCT else None
    rv60d_pct = compute_percentile(rv60d, hist60) if len(hist60) >= RV_MIN_HISTORY_PCT else None

    rating = _rate_rv(rv20d_pct if rv20d_pct is not None else 50.0)

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
