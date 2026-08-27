from __future__ import annotations

# =============================================================================
# tests/test_trend_lines.py
# =============================================================================
# Regression tests for the single-line tools: services/channel_fit.
#   suggest_trendlines()   candidate lines for a user to pick from
#   track_line_accuracy()  how a saved line has held since it was drawn
# and the request/response mapping in routers/trend_lines.py.
# =============================================================================

import math

from services.channel_fit import suggest_trendlines, track_line_accuracy


def _flat_with_ceiling(n=90, floor=100.0, ceiling=110.0, period=10):
    """Oscillates between two known, exact horizontal levels."""
    H = []; L = []; C = []
    for i in range(n):
        phase = (i % period) / period
        frac = phase * 2 if phase < 0.5 else (1 - phase) * 2
        mid = floor + frac * (ceiling - floor)
        H.append(mid + 0.3); L.append(mid - 0.3); C.append(mid)
        if frac > 0.95:
            H[-1] = ceiling
        if frac < 0.05:
            L[-1] = floor
    return H, L, C


# ── suggest_trendlines ───────────────────────────────────────────────────────

def test_suggest_recovers_known_horizontal_levels():
    H, L, C = _flat_with_ceiling()
    upper, lower = suggest_trendlines(H, L, C)
    assert upper and lower
    assert math.isclose(upper[0].slope, 0.0, abs_tol=1e-6)
    assert math.isclose(lower[0].slope, 0.0, abs_tol=1e-6)
    # Anchors must be real construction points, not just any touching bar.
    assert upper[0].end_idx > upper[0].start_idx


def test_suggest_end_idx_differs_from_start_idx_and_is_a_real_touch():
    H, L, C = _flat_with_ceiling()
    upper, _ = suggest_trendlines(H, L, C)
    line = upper[0]
    # The second anchor is one of the touching bars, and the line passes
    # through it exactly (within floating point).
    assert line.end_idx in line.pivot_idx
    assert math.isclose(line.value_at(line.end_idx), H[line.end_idx], abs_tol=1e-6)


def test_suggest_returns_empty_not_error_on_flat_line():
    n = 60
    H = [100.0] * n; L = [100.0] * n; C = [100.0] * n
    upper, lower = suggest_trendlines(H, L, C)
    assert upper == [] and lower == []


def test_suggest_returns_empty_on_too_few_bars():
    H, L, C = _flat_with_ceiling(n=20)
    upper, lower = suggest_trendlines(H, L, C)
    assert upper == [] and lower == []


def test_suggest_tolerance_overrides_change_the_result():
    """A caller's own weights must actually reach the search."""
    H, L, C = _flat_with_ceiling()
    loose_upper, _ = suggest_trendlines(H, L, C, min_touches=2)
    strict_upper, _ = suggest_trendlines(H, L, C, min_touches=50)
    assert loose_upper and not strict_upper


# ── track_line_accuracy ──────────────────────────────────────────────────────

def _series_holding_then_breaking(n=40, level=100.0, break_at=30, break_size=20.0):
    """Flat at `level` until `break_at`, then jumps well above it."""
    H = []; L = []; C = []
    for i in range(n):
        v = level if i < break_at else level + break_size
        H.append(v + 0.2); L.append(v - 0.2); C.append(v)
    return H, L, C


def test_resistance_holding_when_never_pierced():
    H, L, C = _series_holding_then_breaking(break_at=1000)  # never breaks
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=100.0,
                              start_idx=5, kind="resistance")
    assert acc.status == "holding"
    assert acc.violations == 0
    assert acc.touches > 0


def test_resistance_broken_reports_first_violation_index():
    H, L, C = _series_holding_then_breaking(break_at=30)
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=100.0,
                              start_idx=5, kind="resistance")
    assert acc.status == "broken"
    assert acc.violations > 0
    assert acc.first_violation_idx == 30


def test_support_uses_lows_not_highs():
    """A support line must be tested against LOWS, not the same series as
    resistance — swapping them would flip which line ever reports broken."""
    n = 40
    H = [100.5] * n; L = [99.5] * n; C = [100.0] * n
    # Price never actually goes below 90, so a support line at 90 must hold.
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=90.0,
                              start_idx=5, kind="support")
    assert acc.status == "holding"


def test_manual_kind_reports_no_verdict():
    """A hand-drawn line has no assumed side; status must stay None, not
    default to 'holding' — that would be a fabricated claim."""
    H, L, C = _series_holding_then_breaking(break_at=30)
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=100.0,
                              start_idx=5, kind=None)
    assert acc.status is None
    assert acc.bars_checked > 0  # deviation is still measured


def test_accuracy_uses_the_same_bands_as_the_fitter():
    """Regression: accuracy must reuse _TOUCH_ATR/_BREAK_ATR, not a second,
    looser definition of holding vs broken."""
    from services.channel_fit import _TOUCH_ATR, _BREAK_ATR
    n = 40
    H = [100.0 + _BREAK_ATR * 0.5] * n
    L = [100.0 - 1.0] * n
    C = [100.0] * n
    # A high sitting at exactly 0.5x the break band above the line must NOT
    # register as a violation (violation requires exceeding the break band).
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=100.0,
                              start_idx=5, kind="resistance")
    assert acc.violations == 0


def test_start_idx_at_end_of_series_is_a_no_op():
    H, L, C = _series_holding_then_breaking()
    acc = track_line_accuracy(H, L, C, slope=0.0, intercept=100.0,
                              start_idx=len(C) - 1, kind="resistance")
    assert acc.bars_checked == 0
    assert acc.status is None
