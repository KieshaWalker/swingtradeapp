from __future__ import annotations

# =============================================================================
# tests/test_iv_analytics_math.py
# =============================================================================
# Validates the IV analytics math against first principles:
#   • Second-order Greeks (vanna / charm / volga) vs finite differences of
#     the Black-Scholes delta / vega — catches sign, scale and unit errors.
#   • Dealer exposure units: VEX/CEX dollarised with spot, per 1 vol point.
#   • Gamma flip (zero-gamma level) via spot-grid simulation.
#   • 25Δ risk reversal / butterfly extraction.
#   • Term structure slope classification.
#   • ATM IV strike interpolation.
#   • 0DTE inclusion in parse_expirations.
#   • IVP strictly-below convention; delta_gex day-over-day baseline.
# =============================================================================

import math
from datetime import date, timedelta

from scipy.stats import norm

from core.chain_utils import parse_expirations
from services.iv_analytics import (
    SecondOrderStrike,
    _atm_iv_for_expiration,
    _compute_gamma_flip,
    _compute_rr_bf_25d,
    _compute_term_structure,
    _ivr_ivp,
    _second_order_greeks,
    _term_slope,
    analyse,
)


# ---------------------------------------------------------------------------
# Black-Scholes reference helpers (q = 0)
# ---------------------------------------------------------------------------

def _d1(S, K, sigma, T, r):
    return (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * math.sqrt(T))


def _bs_call_delta(S, K, sigma, T, r):
    return norm.cdf(_d1(S, K, sigma, T, r))


def _bs_gamma(S, K, sigma, T, r):
    return norm.pdf(_d1(S, K, sigma, T, r)) / (S * sigma * math.sqrt(T))


def _bs_vega_per_pt(S, K, sigma, T, r):
    """Schwab-convention vega: $ per share per 1 vol-point IV move."""
    return S * norm.pdf(_d1(S, K, sigma, T, r)) * math.sqrt(T) / 100.0


# ---------------------------------------------------------------------------
# Second-order Greeks vs finite differences
# ---------------------------------------------------------------------------

class TestSecondOrderGreeksVsFiniteDifference:
    S, K, SIGMA_PCT, DTE, R = 100.0, 105.0, 30.0, 45, 0.04

    def _greeks(self):
        sigma = self.SIGMA_PCT / 100
        T = self.DTE / 365.0
        gamma = _bs_gamma(self.S, self.K, sigma, T, self.R)
        vega = _bs_vega_per_pt(self.S, self.K, sigma, T, self.R)
        # No expiry_date → T falls back to dte*24*60 minutes = dte/365 years,
        # making the comparison against the analytic T deterministic.
        return _second_order_greeks(
            self.S, self.K, self.SIGMA_PCT, self.DTE, gamma, vega, self.R,
        )

    def test_vanna_matches_fd_delta_per_vol_point(self):
        sigma = self.SIGMA_PCT / 100
        T = self.DTE / 365.0
        h = 1e-5
        fd = (
            _bs_call_delta(self.S, self.K, sigma + h, T, self.R)
            - _bs_call_delta(self.S, self.K, sigma - h, T, self.R)
        ) / (2 * h) * 0.01  # per 1 vol point
        vanna, _, _ = self._greeks()
        assert abs(vanna - fd) < abs(fd) * 1e-3

    def test_charm_matches_fd_delta_per_day(self):
        sigma = self.SIGMA_PCT / 100
        T = self.DTE / 365.0
        eps = 1e-6
        # charm = ∂Δ/∂t = −∂Δ/∂T, expressed per calendar day
        fd = (
            _bs_call_delta(self.S, self.K, sigma, T - eps, self.R)
            - _bs_call_delta(self.S, self.K, sigma, T, self.R)
        ) / eps / 365.0
        _, charm, _ = self._greeks()
        assert abs(charm - fd) < abs(fd) * 1e-3

    def test_volga_matches_fd_vega_per_vol_point(self):
        sigma = self.SIGMA_PCT / 100
        T = self.DTE / 365.0
        h = 1e-5
        fd = (
            _bs_vega_per_pt(self.S, self.K, sigma + h, T, self.R)
            - _bs_vega_per_pt(self.S, self.K, sigma - h, T, self.R)
        ) / (2 * h) * 0.01  # per 1 vol point
        _, _, volga = self._greeks()
        assert abs(volga - fd) < abs(fd) * 1e-3


class TestDealerExposureUnits:
    def test_vex_and_cex_are_dollarised_with_spot(self):
        s = SecondOrderStrike(
            strike=100, call_oi=10, put_oi=0,
            call_vanna=0.002, put_vanna=0.0,
            call_charm=0.001, put_charm=0.0,
            call_volga=0.05, put_volga=0.0,
        )
        spot = 50.0
        # 10 contracts × 0.002 Δ/vol-pt × 100 shares × $50 = $100 per vol-pt
        assert abs(s.dealer_vex(spot) - 100.0) < 1e-9
        # 10 × 0.001 Δ/day × 100 × $50 = $50/day
        assert abs(s.dealer_cex(spot) - 50.0) < 1e-9
        # Volga already in $ vega per vol-pt: 10 × 0.05 × 100 = $50/vol-pt
        assert abs(s.dealer_volga - 50.0) < 1e-9


# ---------------------------------------------------------------------------
# Gamma flip (spot-grid simulation)
# ---------------------------------------------------------------------------

def _contract(strike, iv_pct, oi, delta=0.0, gamma=0.0, vega=0.0, dte=30):
    return {
        "strikePrice": strike,
        "volatility": iv_pct,
        "openInterest": oi,
        "delta": delta,
        "gamma": gamma,
        "vega": vega,
        "daysToExpiration": dte,
    }


class TestGammaFlip:
    def test_flip_between_put_wall_and_call_wall(self):
        # Put OI at 90/92/94, call OI at 106/108/110 — symmetric around 100,
        # so net dealer gamma must flip very close to spot.
        expirations = [{
            "dte": 30,
            "calls": [_contract(k, 30.0, 5000) for k in (106, 108, 110)],
            "puts":  [_contract(k, 30.0, 5000) for k in (90, 92, 94)],
        }]
        zgl = _compute_gamma_flip(expirations, spot=100.0, r=0.04)
        assert zgl is not None
        assert 95.0 < zgl < 105.0

    def test_no_flip_when_one_sided(self):
        # All-call chain → net gamma positive everywhere → no flip
        expirations = [{
            "dte": 30,
            "calls": [_contract(k, 30.0, 5000) for k in (95, 100, 105, 110)],
            "puts": [],
        }]
        assert _compute_gamma_flip(expirations, spot=100.0, r=0.04) is None

    def test_zero_dte_excluded(self):
        expirations = [{
            "dte": 0,
            "calls": [_contract(k, 30.0, 5000, dte=0) for k in (106, 108)],
            "puts":  [_contract(k, 30.0, 5000, dte=0) for k in (92, 94)],
        }]
        assert _compute_gamma_flip(expirations, spot=100.0, r=0.04) is None


# ---------------------------------------------------------------------------
# 25Δ risk reversal / butterfly
# ---------------------------------------------------------------------------

class TestRiskReversalButterfly:
    def test_rr_and_bf_from_deltas(self):
        exp = {
            "calls": [
                _contract(110, 28.0, 100, delta=0.25),
                _contract(100, 30.0, 100, delta=0.50),
            ],
            "puts": [
                _contract(90, 34.0, 100, delta=-0.25),
                _contract(100, 30.0, 100, delta=-0.50),
            ],
        }
        rr, bf = _compute_rr_bf_25d(exp, atm_iv=30.0)
        assert rr is not None and bf is not None
        assert abs(rr - 6.0) < 1e-9   # 34 − 28
        assert abs(bf - 1.0) < 1e-9   # (34+28)/2 − 30

    def test_none_when_no_quote_near_25_delta(self):
        exp = {
            "calls": [_contract(100, 30.0, 100, delta=0.50)],
            "puts":  [_contract(100, 30.0, 100, delta=-0.50)],
        }
        rr, bf = _compute_rr_bf_25d(exp, atm_iv=30.0)
        assert rr is None and bf is None


# ---------------------------------------------------------------------------
# Term structure
# ---------------------------------------------------------------------------

class TestTermStructure:
    def test_curve_and_backwardation(self):
        expirations = [
            {"dte": 10, "expirationDate": "2026-06-22",
             "calls": [_contract(100, 30.0, 10, dte=10)], "puts": []},
            {"dte": 60, "expirationDate": "2026-08-11",
             "calls": [_contract(100, 24.0, 10, dte=60)], "puts": []},
        ]
        points = _compute_term_structure(expirations, spot=100.0)
        assert [p["dte"] for p in points] == [10, 60]
        slope, label = _term_slope(points)
        assert abs(slope - (-6.0)) < 1e-9
        assert label == "backwardation"

    def test_contango(self):
        points = [
            {"dte": 10, "expiry": "", "atm_iv": 22.0},
            {"dte": 90, "expiry": "", "atm_iv": 26.0},
        ]
        slope, label = _term_slope(points)
        assert abs(slope - 4.0) < 1e-9
        assert label == "contango"

    def test_flat_and_unknown(self):
        assert _term_slope([{"dte": 10, "expiry": "", "atm_iv": 22.0}]) == (None, "unknown")
        slope, label = _term_slope([
            {"dte": 10, "expiry": "", "atm_iv": 22.0},
            {"dte": 90, "expiry": "", "atm_iv": 22.5},
        ])
        assert label == "flat"


# ---------------------------------------------------------------------------
# ATM IV interpolation
# ---------------------------------------------------------------------------

class TestAtmIvInterpolation:
    def test_midpoint(self):
        exp = {
            "calls": [_contract(95, 32.0, 10), _contract(105, 28.0, 10)],
            "puts": [],
        }
        assert abs(_atm_iv_for_expiration(exp, spot=100.0) - 30.0) < 1e-9

    def test_weighted_interpolation(self):
        exp = {
            "calls": [_contract(95, 32.0, 10), _contract(105, 28.0, 10)],
            "puts": [],
        }
        # spot 102.5 → 25% of the way back from 105: 0.25·32 + 0.75·28 = 29
        assert abs(_atm_iv_for_expiration(exp, spot=102.5) - 29.0) < 1e-9

    def test_spot_outside_strike_range_uses_edge(self):
        exp = {"calls": [_contract(95, 32.0, 10)], "puts": []}
        assert abs(_atm_iv_for_expiration(exp, spot=200.0) - 32.0) < 1e-9


# ---------------------------------------------------------------------------
# 0DTE handling in parse_expirations
# ---------------------------------------------------------------------------

class TestZeroDteParsing:
    CHAIN = {
        "callExpDateMap": {
            "2026-06-12:0":  {"100.0": [_contract(100, 30.0, 10, dte=0)]},
            "2026-07-12:30": {"100.0": [_contract(100, 30.0, 10, dte=30)]},
        },
        "putExpDateMap": {},
    }

    def test_default_excludes_zero_dte(self):
        dtes = [e["dte"] for e in parse_expirations(self.CHAIN)]
        assert dtes == [30]

    def test_include_zero_dte(self):
        dtes = [e["dte"] for e in parse_expirations(self.CHAIN, include_zero_dte=True)]
        assert dtes == [0, 30]


# ---------------------------------------------------------------------------
# IVP strictly-below + delta_gex baseline
# ---------------------------------------------------------------------------

class TestHistoryConventions:
    def test_ivp_counts_strictly_below(self):
        ivs = [10.0] * 6 + [20.0] * 6  # 12 days history
        _, pct = _ivr_ivp(ivs, current=20.0)
        # Only the six 10.0 days are strictly below → 50%, not 100%
        assert abs(pct - 50.0) < 1e-9

    def test_delta_gex_ignores_todays_own_snapshot(self):
        chain = {
            "symbol": "TEST",
            "underlyingPrice": 100.0,
            "volatility": 30.0,
            "expirations": [{
                "dte": 30,
                "calls": [_contract(100, 30.0, 1000, gamma=0.02)],
                "puts":  [_contract(100, 30.0, 500, gamma=0.02)],
            }],
        }
        today = date.today().isoformat()
        yesterday = (date.today() - timedelta(days=1)).isoformat()
        history = [
            {"date": yesterday, "atm_iv": 30.0, "total_gex": 50.0},
            {"date": today,     "atm_iv": 30.0, "total_gex": 999.0},
        ]
        result = analyse(chain, history)
        assert result.total_gex is not None
        # Baseline must be yesterday's 50.0, not today's 999.0
        assert abs(result.delta_gex - (result.total_gex - 50.0)) < 1e-9
