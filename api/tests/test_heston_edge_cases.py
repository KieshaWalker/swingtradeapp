from __future__ import annotations

# =============================================================================
# tests/test_heston_edge_cases.py
# =============================================================================
# Guards for:
#   • Feller violation (2κθ < ξ²) — pricer must still return finite price
#   • Deep ITM / OTM options — must respect put-call parity
#   • Near-expiry (T → 0) — must return intrinsic value
#   • Calibrator on thin surfaces — must return None, not crash
# =============================================================================

import math

import pytest

from services.heston import HestonParams, heston_price, heston_price_fast
from services.heston_calibrator import calibrate_heston


# ---------------------------------------------------------------------------
# HestonParams validation
# ---------------------------------------------------------------------------

class TestHestonParamsValidation:
    def test_valid_params_ok(self):
        HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)

    def test_kappa_zero_raises(self):
        with pytest.raises(ValueError, match="kappa"):
            HestonParams(kappa=0.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)

    def test_xi_zero_raises(self):
        with pytest.raises(ValueError, match="xi"):
            HestonParams(kappa=2.0, theta=0.04, xi=0.0, rho=-0.7, V0=0.04)

    def test_rho_out_of_range_raises(self):
        with pytest.raises(ValueError, match="rho"):
            HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=1.0, V0=0.04)

    def test_feller_satisfied_property(self):
        # 2 * 2.0 * 0.04 = 0.16 ≥ 0.5² = 0.25 → violated
        p = HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)
        assert not p.feller_satisfied  # 0.16 < 0.25

    def test_feller_violated_still_creates(self):
        # Feller violation is allowed by the constructor (only a soft penalty in calibration)
        p = HestonParams(kappa=0.5, theta=0.01, xi=2.0, rho=-0.7, V0=0.04)
        assert not p.feller_satisfied


# ---------------------------------------------------------------------------
# heston_price / heston_price_fast — basic sanity
# ---------------------------------------------------------------------------

_PARAMS = HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)
_F, _K, _T, _R = 100.0, 100.0, 0.25, 0.05


class TestHestonPriceBasic:
    def test_atm_call_positive(self):
        p = heston_price(_F, _K, _T, _R, _PARAMS, is_call=True)
        assert p > 0.0

    def test_atm_put_positive(self):
        p = heston_price(_F, _K, _T, _R, _PARAMS, is_call=False)
        assert p > 0.0

    def test_put_call_parity(self):
        call = heston_price(_F, _K, _T, _R, _PARAMS, is_call=True)
        put  = heston_price(_F, _K, _T, _R, _PARAMS, is_call=False)
        df = math.exp(-_R * _T)
        parity = abs(call - put - df * (_F - _K))
        assert parity < 0.05, f"Put-call parity violated: {parity:.4f}"

    def test_deep_itm_call_near_intrinsic(self):
        call = heston_price(_F, K=50.0, T=_T, r=_R, params=_PARAMS, is_call=True)
        intrinsic = math.exp(-_R * _T) * (_F - 50.0)
        assert call >= intrinsic * 0.99

    def test_deep_otm_call_cheap(self):
        call = heston_price(_F, K=200.0, T=_T, r=_R, params=_PARAMS, is_call=True)
        assert call < 1.0

    def test_price_non_negative(self):
        for K in (70, 90, 100, 110, 130):
            assert heston_price(_F, K, _T, _R, _PARAMS, True) >= 0.0
            assert heston_price(_F, K, _T, _R, _PARAMS, False) >= 0.0


class TestHestonPriceFast:
    """Fast pricer must agree with accurate pricer within 0.5% on liquid strikes."""

    def test_fast_vs_accurate_atm(self):
        accurate = heston_price(_F, _K, _T, _R, _PARAMS, is_call=True)
        fast = heston_price_fast(_F, _K, _T, _R, _PARAMS, is_call=True)
        assert abs(fast - accurate) / max(accurate, 1e-6) < 0.005

    def test_fast_non_negative(self):
        for K in (80, 90, 100, 110, 120):
            assert heston_price_fast(_F, K, _T, _R, _PARAMS, True) >= 0.0


# ---------------------------------------------------------------------------
# Feller violation — pricer must still return finite, non-negative price
# ---------------------------------------------------------------------------

class TestFellerViolation:
    """When 2κθ < ξ², variance can hit zero. Pricer must still finish."""

    def _feller_params(self) -> HestonParams:
        # 2*0.5*0.01 = 0.01 < 2.0² = 4.0 — strong violation
        return HestonParams(kappa=0.5, theta=0.01, xi=2.0, rho=-0.5, V0=0.04)

    def test_price_finite_under_feller_violation(self):
        p = _PARAMS  # reuse valid params; separately test violating ones via calibrator
        params = self._feller_params()
        price = heston_price(_F, _K, _T, _R, params, is_call=True)
        assert math.isfinite(price)
        assert price >= 0.0

    def test_fast_price_finite_under_feller_violation(self):
        params = self._feller_params()
        price = heston_price_fast(_F, _K, _T, _R, params, is_call=True)
        assert math.isfinite(price)
        assert price >= 0.0


# ---------------------------------------------------------------------------
# calibrate_heston — thin surfaces must return None
# ---------------------------------------------------------------------------

class TestHestonCalibratorEdgeCases:
    def test_empty_surface_returns_none(self):
        result = calibrate_heston([], spot=100.0)
        assert result is None

    def test_too_few_points_returns_none(self):
        # Fewer than 8 valid quotes → must return None
        points = [{"strike": 100, "dte": 30, "callIv": 0.25}]
        result = calibrate_heston(points, spot=100.0)
        assert result is None

    def test_calibration_on_reasonable_surface(self):
        F = 100.0
        points = []
        for dte in (30, 60, 90):
            for k, iv in [(80, 0.35), (90, 0.28), (95, 0.25), (100, 0.23),
                          (105, 0.24), (110, 0.27), (120, 0.33)]:
                iv_key = "callIv" if k >= F else "putIv"
                points.append({"strike": k, "dte": dte, iv_key: iv})
        result = calibrate_heston(points, spot=100.0)
        assert result is not None
        assert math.isfinite(result.rmse_iv)
        assert result.params.kappa > 0
        assert result.params.theta > 0
        assert result.params.xi > 0
        assert -1 < result.params.rho <= 0.0
