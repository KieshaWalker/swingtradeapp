from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

_MIN_HISTORY = 5
_TREND_WINDOW = 10  # days per half when computing rising/falling


@dataclass
class VvolResult:
    nu_current: float
    nu_52w_high: float
    nu_52w_low: float
    vvol_rank: float        # 0–100, mirrors IV rank formula
    vvol_percentile: float  # 0–100
    vvol_rating: str        # cheap / fair / elevated / extreme
    nu_30d_avg: float
    nu_trend: str           # rising / falling / flat
    history_days: int


def compute(nu_current: float, nu_history: list[float]) -> Optional[VvolResult]:
    """Compute vol-of-vol rank from historical SABR ν series.

    nu_current: today's calibrated ν for the ~30 DTE slice
    nu_history: prior observations oldest-first (today excluded)
    """
    if not nu_history or len(nu_history) < _MIN_HISTORY:
        return None

    nu_52w_high = max(nu_history)
    nu_52w_low  = min(nu_history)

    if nu_52w_high == nu_52w_low:
        vvol_rank = 50.0
    else:
        vvol_rank = (nu_current - nu_52w_low) / (nu_52w_high - nu_52w_low) * 100.0
        vvol_rank = max(0.0, min(100.0, vvol_rank))

    vvol_percentile = sum(1 for n in nu_history if n < nu_current) / len(nu_history) * 100.0

    if vvol_rank >= 80:
        rating = "extreme"
    elif vvol_rank >= 50:
        rating = "elevated"
    elif vvol_rank >= 25:
        rating = "fair"
    else:
        rating = "cheap"

    recent     = nu_history[-30:] if len(nu_history) >= 30 else nu_history
    nu_30d_avg = sum(recent) / len(recent)

    if len(nu_history) >= _TREND_WINDOW * 2:
        last  = sum(nu_history[-_TREND_WINDOW:]) / _TREND_WINDOW
        prior = sum(nu_history[-_TREND_WINDOW * 2 : -_TREND_WINDOW]) / _TREND_WINDOW
        diff  = (last - prior) / prior if prior > 0 else 0.0
        if diff > 0.05:
            trend = "rising"
        elif diff < -0.05:
            trend = "falling"
        else:
            trend = "flat"
    else:
        trend = "flat"

    return VvolResult(
        nu_current=round(nu_current, 4),
        nu_52w_high=round(nu_52w_high, 4),
        nu_52w_low=round(nu_52w_low, 4),
        vvol_rank=round(vvol_rank, 1),
        vvol_percentile=round(vvol_percentile, 1),
        vvol_rating=rating,
        nu_30d_avg=round(nu_30d_avg, 4),
        nu_trend=trend,
        history_days=len(nu_history),
    )
