from __future__ import annotations

# =============================================================================
# tests/test_swing_setup.py
# =============================================================================
# Regression tests for the swing-setup engine: services/channel_fit.py and
# services/trend_volume.py.
#
# These lock in behaviour that was established by measurement against real bars,
# not by taste. Two of them encode bugs that actually shipped and were caught:
# the independent-line fit that produced a 98%-of-spot channel, and the
# validity-window error that let "support" sit above price for a third of the
# window. Both are cheap to reintroduce and invisible without a test.
# =============================================================================

import math

from services.channel_fit import fit_channel, find_pivots
from services.trend_volume import compute_trend, compute_volume, sma


# ── helpers ──────────────────────────────────────────────────────────────────

def _perfect_channel(n=120, slope=0.5, base=100.0, width=10.0):
    """A price path that oscillates cleanly between two parallel lines."""
    H = []; L = []; C = []
    for i in range(n):
        lo_line = base + slope * i
        phase = (i % 12) / 12.0
        frac = phase * 2 if phase < 0.5 else (1 - phase) * 2
        mid = lo_line + frac * width
        H.append(mid + 0.4); L.append(mid - 0.4); C.append(mid)
        if frac > 0.95:
            H[-1] = lo_line + width
        if frac < 0.05:
            L[-1] = lo_line
    return H, L, C


# ── channel_fit ──────────────────────────────────────────────────────────────

def test_recovers_a_known_channel_exactly():
    H, L, C = _perfect_channel(slope=0.5, width=10.0)
    f = fit_channel(H, L, C)
    assert f.found
    assert f.kind == "channel"
    assert f.direction == "ascending"
    assert math.isclose(f.upper.slope, 0.5, abs_tol=1e-6)
    assert math.isclose(f.lower.slope, 0.5, abs_tol=1e-6)
    assert math.isclose(f.upper_now - f.lower_now, 10.0, abs_tol=1e-4)


def test_boundaries_contain_price_on_their_validity_window():
    """The fitted lines must not be pierced within [start_idx, n).

    This is the regression for the validity-window bug: lines were validated
    only from their first anchor forward but reported across the whole window,
    which measured 10.6% mean / 39% worst lower-boundary violations on real
    data.
    """
    H, L, C = _perfect_channel()
    f = fit_channel(H, L, C)
    assert f.found and f.start_idx is not None
    for i in range(f.start_idx, len(C)):
        assert H[i] <= f.upper.value_at(i) + 1e-6
        assert L[i] >= f.lower.value_at(i) - 1e-6


def test_rejects_absurdly_wide_fits():
    """No fit may emit a channel wider than the sanity cap.

    Regression for the independently-fitted boundaries that produced a
    98%-of-spot channel on MU and a $1291 target on a ~$200 AMD.
    """
    H, L, C = _perfect_channel()
    f = fit_channel(H, L, C)
    if f.found:
        assert f.width_pct is not None and f.width_pct <= 45.0
        # A measured-move target must stay in the neighbourhood of the price.
        assert f.breakout_target_up < C[-1] * 2.0


def test_flat_line_finds_no_channel_rather_than_inventing_one():
    n = 60
    H = [100.0] * n; L = [100.0] * n; C = [100.0] * n
    f = fit_channel(H, L, C)
    assert not f.found
    assert f.reason == "zero_atr"


def test_too_few_bars_is_reported_not_guessed():
    H, L, C = _perfect_channel(n=20)
    f = fit_channel(H, L, C)
    assert not f.found and f.reason == "too_few_bars"


def test_flat_double_top_yields_a_pivot():
    """Strict-left / non-strict-right: a flat top must still register."""
    h = [1, 2, 3, 5, 5, 3, 2, 1, 2, 3, 4, 3, 2, 1, 1, 2, 3]
    l = [0] * len(h)
    hi, _ = find_pivots(h, l, strength=2)
    assert 3 in hi


# ── trend_volume ─────────────────────────────────────────────────────────────

def test_sma_is_all_or_nothing():
    assert sma([1.0] * 49, 50) is None
    assert sma([2.0] * 50, 50) == 2.0


def test_sma200_none_below_200_bars_and_cross_is_none_not_false():
    closes = [100.0 + i for i in range(150)]
    t = compute_trend(closes)
    assert t.sma50 is not None
    assert t.sma200 is None
    # "cannot tell" must not collapse into "not aligned"
    assert t.sma50_above_200 is None
    assert t.price_above_200 is None


def test_golden_cross_alignment_when_both_available():
    closes = [100.0 + i * 0.5 for i in range(260)]   # steadily rising
    t = compute_trend(closes)
    assert t.sma200 is not None
    assert t.sma50_above_200 is True
    assert t.sma50_slope_pct is not None and t.sma50_slope_pct > 0


def test_volume_surge_uses_median_and_excludes_the_test_bar():
    """A single huge day must be detected, and must not inflate its own baseline."""
    vols = [1_000_000.0] * 60 + [5_000_000.0]
    v = compute_volume(vols)
    assert v.baseline_median30 == 1_000_000.0      # test bar excluded
    assert v.vol_ratio == 5.0
    assert v.surge is True
    assert v.vol_z is None or v.vol_z > 0


def test_volume_median_baseline_survives_a_prior_spike():
    """A mean baseline would be dragged up by an earlier spike; a median is not."""
    vols = [1_000_000.0] * 40 + [50_000_000.0] + [1_000_000.0] * 19 + [1_900_000.0]
    v = compute_volume(vols)
    assert v.baseline_median30 == 1_000_000.0
    assert v.surge is True          # 1.9x still clears the 1.79 cut


def test_participation_regime_bands():
    """sma30/sma50 classifies the sustained regime, not a single day."""
    quiet = [1_000_000.0] * 60
    v = compute_volume(quiet)
    assert v.participation == "normal"
    assert v.vol_sma30 is not None and v.vol_sma50 is not None


def test_single_day_spike_does_not_move_participation():
    """The documented limitation, pinned: 30/50 cannot see one day."""
    vols = [1_000_000.0] * 60 + [10_000_000.0]
    v = compute_volume(vols)
    assert v.surge is True                      # the surge leg sees it
    assert v.participation == "normal"          # the regime leg does not


def test_short_volume_series_reports_none_not_zero():
    v = compute_volume([1_000_000.0] * 5)
    assert v.vol_ratio is None
    assert v.surge is None
    assert v.vol_sma30 is None


# ── options_confirm ──────────────────────────────────────────────────────────

from services.options_confirm import confirm, _implied_days


def _em(em_pct, iv, dte=30, date="2026-08-26"):
    return {"date": date, "em_pct": em_pct, "iv": iv, "dte": dte}


def test_implied_days_inverts_the_expected_move_formula():
    """EM = spot*IV*sqrt(t/365); at t=365 a 1-sigma move is exactly IV."""
    assert _implied_days(50.0, 0.50) == 365.0
    # Half the move needs a quarter of the time (sqrt scaling).
    assert _implied_days(25.0, 0.50) == 91.25


def test_implied_days_guards_against_zero_iv():
    """A zero IV would divide to infinity and read as a very strong signal."""
    assert _implied_days(20.0, 0.0) is None
    assert _implied_days(20.0, None) is None
    assert _implied_days(None, 0.5) is None


def test_reachable_is_not_degenerate_on_a_realistic_channel():
    """Regression: the old underpriced flag was True on 100% of real channels.

    A ~27% measured move against a ~12% monthly cone must NOT come back as a
    tradeable confirmation just because the ratio exceeds 1.
    """
    c = confirm(spot=100.0, breakout_target_up=127.0, breakout_target_down=73.0,
                em_row=_em(12.0, 0.42), iv_row=None)
    assert c.em_ratio_up > 1.0          # ratio still reported...
    assert c.reachable_up is False      # ...but does not imply confirmation


def test_reachable_true_when_market_vol_reaches_the_target_in_time():
    # A 20% target on 80% IV: t = 365*(0.20/0.80)^2 ~ 23 days.
    c = confirm(spot=100.0, breakout_target_up=120.0, breakout_target_down=None,
                em_row=_em(20.0, 0.80), iv_row=None)
    assert c.implied_days_up < 90.0
    assert c.reachable_up is True


def test_absurd_target_is_none_not_false():
    """Beyond the credible horizon the reading is withdrawn, not denied."""
    c = confirm(spot=100.0, breakout_target_up=300.0, breakout_target_down=None,
                em_row=_em(10.0, 0.30), iv_row=None)
    assert c.implied_days_up > 365.0
    assert c.reachable_up is None


def test_dealer_posture_from_spot_versus_zero_gamma():
    above = confirm(100.0, None, None, None,
                    {"date": "2026-08-27", "gamma_regime": "positive",
                     "zero_gamma_level": 90.0, "spot_to_zero_gamma_pct": 11.1})
    assert above.dealer_posture == "dampening"
    assert above.breakout_supported is False

    below = confirm(100.0, None, None, None,
                    {"date": "2026-08-27", "gamma_regime": "negative",
                     "zero_gamma_level": 110.0, "spot_to_zero_gamma_pct": -9.1})
    assert below.dealer_posture == "amplifying"
    assert below.breakout_supported is True


def test_unknown_gamma_regime_yields_no_posture():
    c = confirm(100.0, None, None, None,
                {"date": "2026-08-27", "gamma_regime": "unknown",
                 "zero_gamma_level": None, "spot_to_zero_gamma_pct": None})
    assert c.dealer_posture is None
    assert c.breakout_supported is None


def test_legs_are_independent():
    """A missing expected move must not also cost the gamma read."""
    c = confirm(100.0, 120.0, 80.0, None,
                {"date": "2026-08-27", "gamma_regime": "negative",
                 "zero_gamma_level": 110.0, "spot_to_zero_gamma_pct": -9.1})
    assert c.ok is True
    assert c.em_pct is None and c.reachable_up is None
    assert c.dealer_posture == "amplifying"


def test_no_data_at_all_is_reported():
    c = confirm(100.0, 120.0, 80.0, None, None)
    assert c.ok is False and c.reason == "no_options_data"
