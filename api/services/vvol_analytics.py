from __future__ import annotations

# =============================================================================
# services/vvol_analytics.py
# =============================================================================
# Vol-of-vol ranking from the calibrated SABR ν series.
#
# ν is SABR's vol-of-vol parameter — it sets the CURVATURE of the smile, i.e.
# how much the market thinks implied vol itself will move. This module ranks
# today's ν against its own trailing history, exactly as IV rank ranks today's
# IV against its own.
#
# WHY IT IS WORTH TRACKING SEPARATELY FROM IV:
#   IV rank   answers "is premium expensive?"
#   vvol rank answers "is that premium likely to STAY where it is?"
#
# High vvol means IV is a fast-moving target: a short-premium position carries
# more mark-to-market risk than its vega alone suggests, and an IV rank reading
# decays in usefulness quickly. Low vvol means a stable surface where an IV rank
# signal has time to play out. The pair is far more informative than either
# alone — cheap IV with low vvol is a very different setup from cheap IV with
# high vvol.
#
# THE INPUT COMES FROM THE PIPELINE, not from a fresh calculation: jobs/sabr_pull
# fits ν daily, fetch_nu_history assembles the series (gated on fit reliability
# and anchored to a ~30 DTE slice so the tenor is constant), and jobs/iv_pull
# calls compute() here. That gating matters — a boundary-pinned SABR fit reports
# the same ν every session, which would collapse the rank window to a constant.
# =============================================================================

from dataclasses import dataclass
from typing import Optional

# Below this many prior observations, no ranking is attempted — a percentile
# against four points is noise. Deliberately low so a newly-tracked ticker
# starts producing readings within a week.
_MIN_HISTORY = 5
_TREND_WINDOW = 10  # days per half when computing rising/falling


@dataclass
class VvolResult:
    """Ranked vol-of-vol reading. Field names say 52w but see history_days.

    The "52w" high/low labels describe the INTENT of the window (fetch_nu_history
    requests a year) rather than a guarantee: they are simply the max and min of
    whatever history was supplied. Read history_days before treating them as a
    full year.
    """
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
    # Returns None rather than a partial result — the caller (jobs/iv_pull)
    # then omits the vvol columns entirely from its upsert, leaving any earlier
    # value for the day intact instead of overwriting it with nulls.
    if not nu_history or len(nu_history) < _MIN_HISTORY:
        return None

    nu_52w_high = max(nu_history)
    nu_52w_low  = min(nu_history)

    # RANK = where the current value sits between the historical min and max.
    # Same formula as IV rank, deliberately, so the two are read the same way.
    #
    # A flat history (every ν identical) has no range to place the value in, so
    # 50.0 — the neutral midpoint — is returned rather than dividing by zero.
    # That is the signature of a pinned SABR fit reaching this function despite
    # the reliability gate upstream.
    if nu_52w_high == nu_52w_low:
        vvol_rank = 50.0
    else:
        vvol_rank = (nu_current - nu_52w_low) / (nu_52w_high - nu_52w_low) * 100.0
        # Clamped because nu_current is TODAY's value and is not part of the
        # history (fetch_nu_history excludes today), so it can legitimately sit
        # outside the historical range — a genuinely new extreme reads as 0 or
        # 100 rather than overflowing.
        vvol_rank = max(0.0, min(100.0, vvol_rank))

    # PERCENTILE = share of history at or below today. Distribution-based, where
    # rank is range-based, so the two diverge when the history is skewed: one
    # extreme spike compresses the rank of everything else while barely moving
    # the percentile. Both are exposed for that reason.
    #
    # Note `<=` (inclusive) here, versus the strict `<` used in
    # contract_opportunity._rank_percentile — a minor inconsistency between the
    # two ranking helpers, immaterial on continuous float data where exact ties
    # are vanishingly rare.
    vvol_percentile = sum(1 for n in nu_history if n <= nu_current) / len(nu_history) * 100.0

    # Bands are cut on RANK, not percentile, so the rating reflects position
    # within the observed range. Note the asymmetry: "cheap" spans 0-25 and
    # "fair" only 25-50, so the neutral 50.0 returned for a flat history rates
    # as "elevated" rather than "fair" — worth knowing when a rating looks
    # surprising on a thin series.
    if vvol_rank >= 80:
        rating = "extreme"
    elif vvol_rank >= 50:
        rating = "elevated"
    elif vvol_rank >= 25:
        rating = "fair"
    else:
        rating = "cheap"

    # Trailing average, over whatever history exists when short of 30. Purely
    # descriptive — nothing gates on it.
    recent     = nu_history[-30:] if len(nu_history) >= 30 else nu_history
    nu_30d_avg = sum(recent) / len(recent)

    # TREND: compare the mean of the last 10 observations against the 10 before
    # them. Two non-overlapping halves rather than a regression slope — cruder,
    # but robust to a single outlier day and adequate for a three-way label.
    #
    # The ±5% RELATIVE threshold (not absolute) keeps the classification scale-
    # free, so it behaves the same for a ν of 0.3 as for a ν of 3.0.
    #
    # Falls back to "flat" when there is too little history, which is
    # indistinguishable in the output from a genuinely flat trend — check
    # history_days to tell them apart.
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

    # Rounded at the boundary: 4 dp for ν values (which run ~0.1-3.0) and 1 dp
    # for the 0-100 scores. Precision beyond that is noise from the calibration.
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
