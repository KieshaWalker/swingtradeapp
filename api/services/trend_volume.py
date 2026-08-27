from __future__ import annotations

# =============================================================================
# services/trend_volume.py
# =============================================================================
# The 50/200-day SMA leg and the volume-surge leg of the swing-setup engine.
# Both read daily bars out of equity_bars; neither fetches anything.
#
# ── WHY sma200 IS NEW ────────────────────────────────────────────────────────
# regime_pull and schwab_pull already compute sma10 and sma50, and have since
# long before this file. Neither computes sma200, and that was never an
# oversight: both call fetch_schwab_closes(..., days=65), so only 65 closes were
# ever in memory and a 200-bar average was arithmetically impossible. equity_bars
# holds ~252 sessions per ticker, which is what makes the 200-day SMA available
# for the first time.
#
# TWO SOURCES OF TRUTH — READ THIS BEFORE COMPARING NUMBERS. regime_snapshots
# .sma50 is computed from a live 65-close Schwab fetch at regime-pull time;
# sma50 here is computed from stored equity_bars. They will USUALLY agree and
# are NOT guaranteed to: different fetch moments, and this one excludes the
# in-progress session while an intraday regime run may include it. Neither is
# wrong. Do not "fix" a small discrepancy by making one read the other without
# deciding which is canonical first.
#
# ── ALL-OR-NOTHING WINDOWS ───────────────────────────────────────────────────
# Below the required bar count the value is None, never an average over a short
# window. Lifted verbatim from regime_pull's convention, and the reasoning is
# its own: "a 3-day SMA10 would instead produce a confident but wrong trend
# read". Three tickers in the current universe (SPCX 52 bars, DRAM 101, CCXI
# 122) genuinely cannot support sma200 and must report None rather than a
# shortened average that silently means something else.
#
# ── VOLUME: 30 AND 50 DAY WINDOWS, MEDIAN BASELINE ───────────────────────────
# The windows are 30 and 50 sessions, replacing the 3/20 pair that regime_pull
# and schwab_pull used. Both readings of "a 30 and a 50 day volume SMA" are
# produced, because they answer different questions and only one of them is a
# surge detector:
#
#   vol_sma30 / vol_sma50   — PARTICIPATION REGIME. Is this name busier over the
#                             last ~6 weeks than the last ~10? The direct
#                             replacement for the old sma3/sma20 ratio.
#   volume / median30       — SURGE. Is TODAY heavy against its own recent norm?
#
# WHY BOTH, MEASURED: a ratio of two long averages cannot see a single day. Over
# this universe a 10x volume day moves sma30/sma50 only to 1.102 — below that
# ratio's own p90 of 1.167, i.e. not even unusual — while it moves the old
# sma3/sma20 to 2.759, past its p99. Dropping the short window therefore removes
# breakout-confirmation entirely unless today is compared to a baseline directly,
# which is what volume/median30 does.
#
# MEDIAN, NOT MEAN, FOR THE SURGE BASELINE. Daily share volume is strongly
# right-skewed — across this universe the mean/median ratio has a median of 1.14
# and a maximum of 77. A mean baseline is dragged up by the very spike days the
# detector is looking for, suppressing the next detection; the median is unmoved.
# It also absorbs half-sessions for free: the day after Thanksgiving, Christmas
# Eve and July 3 close at 13:00 ET on roughly half normal volume, denting a mean
# and leaving a median alone. vol_sma30/vol_sma50 remain true means, because
# those are the SMAs that were asked for.
#
# ── WHERE THE THRESHOLDS CAME FROM ───────────────────────────────────────────
# Measured, not invented, over 9,821 (ticker, bar) observations in equity_bars:
#
#   volume / median30    p50 0.99  p70 1.21  p80 1.40  p90 1.79  p95 2.24  p99 4.26
#   volume / sma30       p50 0.90  p70 1.10  p80 1.26  p90 1.58  p95 1.98  p99 3.33
#   sma30 / sma50        p50 1.007 p75 1.086 p90 1.167 p95 1.212 p99 1.344
#
# _SURGE_RATIO is the p90 of volume/median30, so "surge" means roughly the top
# decile of participation for that name. _PARTICIPATION_HIGH is the p90 of
# sma30/sma50 — note how tight that distribution is; a 17% lift in six-week
# average volume is already a top-decile regime shift.
#
# The old regime_service._append_volume_signal fired whenever vol_sma3 >
# vol_sma20, a ratio > 1.0 cut that these measurements show is true on 41% of
# bars (52% for sma30/sma50). Fine for the CONTEXT signal it was, useless as a
# screen leg. The construction is reused; the cut is derived above.
# =============================================================================

import logging
import math
import statistics
from dataclasses import dataclass
from typing import Optional, Sequence

log = logging.getLogger(__name__)

_SMA_FAST = 50
_SMA_SLOW = 200
# Bars back used to measure whether an SMA is rising or falling. Ten sessions is
# long enough that a single day cannot flip the reading, short enough to still
# describe the current state rather than last quarter's.
_SLOPE_LOOKBACK = 10

# Trailing window for the volume baseline. 20 sessions ~ one calendar month,
# matching the existing vol_sma20 so the two remain comparable.
# Volume windows. 30 and 50 sessions ~ 6 and 10 calendar weeks.
_VOL_FAST = 30
_VOL_SLOW = 50
# p90 of volume/median30 — see the header table.
_SURGE_RATIO = 1.79
# p90 of sma30/sma50. Deliberately close to 1.0: that ratio's whole p10-p90
# range is only 0.84-1.17, so small deviations are large in its own terms.
_PARTICIPATION_HIGH = 1.17
_PARTICIPATION_LOW = 0.84
# Minimum observations before a z-score is meaningful. Below this the standard
# deviation is too unstable to divide by.
_MIN_Z_OBS = 15


@dataclass
class TrendState:
    sma50:            Optional[float] = None
    sma200:           Optional[float] = None
    pct_to_sma50:     Optional[float] = None   # +ve = price above the average
    pct_to_sma200:    Optional[float] = None
    price_above_50:   Optional[bool] = None
    price_above_200:  Optional[bool] = None
    # True when sma50 > sma200 — the "golden cross" alignment. None when either
    # average is unavailable, which is NOT the same as False.
    sma50_above_200:  Optional[bool] = None
    sma50_slope_pct:  Optional[float] = None   # % change over _SLOPE_LOOKBACK
    sma200_slope_pct: Optional[float] = None
    bars_available:   int = 0


@dataclass
class VolumeState:
    volume:            Optional[float] = None
    # The two SMAs themselves — true means, the overlay lines on a volume panel.
    vol_sma30:         Optional[float] = None
    vol_sma50:         Optional[float] = None
    # Surge leg: today against its own 30-session median.
    baseline_median30: Optional[float] = None
    vol_ratio:         Optional[float] = None
    vol_z:             Optional[float] = None
    surge:             Optional[bool] = None
    # Participation-regime leg: the two SMAs against each other.
    sma30_over_sma50:  Optional[float] = None
    participation:     Optional[str] = None   # elevated | normal | light
    bars_available:    int = 0


def sma(values: Sequence[float], n: int) -> Optional[float]:
    """Simple moving average of the last n values, or None if short.

    All-or-nothing by design — see the header. Returning a shortened average
    here would be worse than returning nothing, because callers cannot tell the
    difference from the value alone.
    """
    if len(values) < n:
        return None
    window = values[-n:]
    return sum(window) / n


def compute_trend(closes: Sequence[float]) -> TrendState:
    """SMA state from a daily close series. Bars must be OLDEST FIRST."""
    n = len(closes)
    st = TrendState(bars_available=n)
    if n == 0:
        return st

    spot = closes[-1]
    st.sma50 = sma(closes, _SMA_FAST)
    st.sma200 = sma(closes, _SMA_SLOW)

    if st.sma50 and st.sma50 > 0:
        st.pct_to_sma50 = round((spot / st.sma50 - 1.0) * 100.0, 4)
        st.price_above_50 = spot > st.sma50
    if st.sma200 and st.sma200 > 0:
        st.pct_to_sma200 = round((spot / st.sma200 - 1.0) * 100.0, 4)
        st.price_above_200 = spot > st.sma200

    # None, not False, when either side is missing: "we cannot tell whether the
    # averages are aligned" and "they are not aligned" are different claims, and
    # a screen that treats the first as the second silently drops every young
    # listing into the bearish bucket.
    if st.sma50 is not None and st.sma200 is not None:
        st.sma50_above_200 = st.sma50 > st.sma200

    # Slope needs the average as it stood _SLOPE_LOOKBACK bars ago, so the
    # series must be long enough for BOTH windows.
    for attr, period in (("sma50_slope_pct", _SMA_FAST),
                         ("sma200_slope_pct", _SMA_SLOW)):
        if n >= period + _SLOPE_LOOKBACK:
            now = sma(closes, period)
            then = sma(closes[:-_SLOPE_LOOKBACK], period)
            if now and then and then > 0:
                setattr(st, attr, round((now / then - 1.0) * 100.0, 4))
    return st


def compute_volume(volumes: Sequence[float]) -> VolumeState:
    """Volume state from a daily volume series. OLDEST FIRST.

    The last element is the bar under test; everything before it forms the
    baselines. The current bar is EXCLUDED from its own baseline — including it
    would let a large day inflate the very median it is measured against,
    damping exactly the signal being looked for.
    """
    n = len(volumes)
    st = VolumeState(bars_available=n)
    if n == 0:
        return st

    st.volume = volumes[-1]
    prior = [v for v in volumes[:-1] if v and v > 0]

    # The two SMAs, all-or-nothing like every other window in this module.
    st.vol_sma30 = sma(prior, _VOL_FAST)
    st.vol_sma50 = sma(prior, _VOL_SLOW)

    if st.vol_sma30 and st.vol_sma50 and st.vol_sma50 > 0:
        st.sma30_over_sma50 = round(st.vol_sma30 / st.vol_sma50, 4)
        if st.sma30_over_sma50 >= _PARTICIPATION_HIGH:
            st.participation = "elevated"
        elif st.sma30_over_sma50 <= _PARTICIPATION_LOW:
            st.participation = "light"
        else:
            st.participation = "normal"

    if len(prior) < _VOL_FAST:
        return st

    window = prior[-_VOL_FAST:]
    med = statistics.median(window)
    st.baseline_median30 = med
    if med > 0 and st.volume:
        st.vol_ratio = round(st.volume / med, 4)
        st.surge = st.vol_ratio >= _SURGE_RATIO

    # Volume is closer to log-normal than normal, so the z-score is taken in log
    # space. On raw volume the statistic is dominated by the right tail and a
    # "2 sigma" day is not comparable between a thin name and a heavy one.
    logs = [math.log(v) for v in window if v > 0]
    if len(logs) >= _MIN_Z_OBS and st.volume and st.volume > 0:
        mu = statistics.mean(logs)
        sd = statistics.pstdev(logs)
        if sd > 0:
            st.vol_z = round((math.log(st.volume) - mu) / sd, 4)
    return st
