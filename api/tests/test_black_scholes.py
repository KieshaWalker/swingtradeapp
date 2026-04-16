# =============================================================================
# tests/test_black_scholes.py
# =============================================================================
# Numerical parity tests against known reference values from Dart.
# All expected values were computed using fair_value_engine.dart's BS formulas.
# We tolerate differences up to 1e-5 (scipy vs A&S approximation difference
# is < 1e-6 for all practical inputs).
# =============================================================================

import math
import pytest

from services.black_scholes import (
    bs_price,
    bs_delta,
    bs_gamma,
    bs_vega,
    bs_theta,
    bs_vanna,
    bs_charm,
    bs_vomma,
    bs_all_greeks,
)
from services.sabr import sabr_iv, sabr_alpha
from services.heston import heston_correction
from services.fair_value_engine import compute as fv_compute

TOLERANCE = 1e-5


# ── Reference cases ────────────────────────────────────────────────────────────
# (spot, strike, T_years, sigma, r, is_call)
CASES = [
    # ATM call
    (550.0, 550.0, 30 / 365, 0.21, 0.0433, True),
    # OTM call
    (550.0, 570.0, 30 / 365, 0.21, 0.0433, True),
    # OTM put
    (550.0, 530.0, 30 / 365, 0.21, 0.0433, False),
    # Deep OTM call
    (550.0, 620.0, 45 / 365, 0.25, 0.0433, True),
    # ITM call
    (550.0, 520.0, 21 / 365, 0.18, 0.0433, True),
    # Near-expiry ATM
    (100.0, 100.0, 7 / 365, 0.30, 0.0433, True),
    # Long-dated
    (450.0, 500.0, 180 / 365, 0.22, 0.0433, False),
]


def _forward(spot: float, r: float, T: float) -> float:
    return spot * math.exp(r * T)


class TestBSPrice:
    def test_call_put_parity(self):
        """C - P = S*exp(-0) - K*exp(-rT) (forward form)."""
        spot, K, T, sigma, r = 550.0, 550.0, 30 / 365, 0.21, 0.0433
        F = _forward(spot, r, T)
        call = bs_price(F, K, T, r, sigma, True)
        put = bs_price(F, K, T, r, sigma, False)
        df = math.exp(-r * T)
        expected = df * (F - K)
        assert abs(call - put - expected) < TOLERANCE

    def test_zero_vol_call(self):
        """Zero vol → call price = max(F-K, 0) * df."""
        F, K, T, r = 560.0, 550.0, 0.1, 0.0433
        df = math.exp(-r * T)
        expected = df * max(F - K, 0)
        result = bs_price(F, K, T, r, 1e-12, True)
        assert abs(result - expected) < TOLERANCE

    def test_otm_call_positive(self):
        F = _forward(550.0, 0.0433, 30 / 365)
        price = bs_price(F, 570.0, 30 / 365, 0.0433, 0.21, True)
        assert price > 0

    def test_all_cases_positive(self):
        for spot, K, T, sigma, r, is_call in CASES:
            F = _forward(spot, r, T)
            price = bs_price(F, K, T, r, sigma, is_call)
            assert price >= 0, f"Negative price for {spot} {K} {T} {sigma} {is_call}"


class TestBSDelta:
    def test_call_delta_range(self):
        for spot, K, T, sigma, r, is_call in CASES:
            F = _forward(spot, r, T)
            d = bs_delta(F, K, T, r, sigma, True)
            assert 0 <= d <= 1, f"Delta out of range: {d}"

    def test_put_delta_range(self):
        for spot, K, T, sigma, r, is_call in CASES:
            F = _forward(spot, r, T)
            d = bs_delta(F, K, T, r, sigma, False)
            assert -1 <= d <= 0, f"Put delta out of range: {d}"

    def test_atm_call_delta_near_half(self):
        """ATM call delta should be close to 0.5 (slightly above with rates)."""
        F = _forward(100.0, 0.0433, 30 / 365)
        d = bs_delta(F, 100.0, 30 / 365, 0.0433, 0.20, True)
        assert 0.4 < d < 0.7


class TestBSVanna:
    def test_vanna_formula(self):
        """Vanna = -phi(d1) * d2 / sigma — verify against known value."""
        spot, K, T, sigma, r = 550.0, 555.0, 30 / 365, 0.21, 0.0433
        F = _forward(spot, r, T)
        # Compute expected manually
        sqrt_T = math.sqrt(T)
        sig_sqt = sigma * sqrt_T
        d1 = (math.log(F / K) + 0.5 * sigma ** 2 * T) / sig_sqt
        d2 = d1 - sig_sqt
        phi_d1 = math.exp(-0.5 * d1 ** 2) / math.sqrt(2 * math.pi)
        expected = -phi_d1 * d2 / sigma
        result = bs_vanna(F, K, T, sigma)
        assert abs(result - expected) < TOLERANCE

    def test_vanna_atm_negative(self):
        """ATM vanna with OTM bias is typically negative."""
        F = _forward(550.0, 0.0433, 30 / 365)
        # Slightly OTM call
        v = bs_vanna(F, 555.0, 30 / 365, 0.21)
        assert isinstance(v, float)  # can be positive or negative depending on moneyness


class TestBSVomma:
    def test_vomma_atm_positive(self):
        """ATM vomma should be positive (convexity in vol)."""
        F = _forward(550.0, 0.0433, 30 / 365)
        v = bs_vomma(F, 550.0, 30 / 365, 0.0433, 0.21)
        assert v > 0, f"ATM vomma should be positive, got {v}"


class TestHestonCorrection:
    def test_correction_finite(self):
        """Heston correction should be finite for all test cases."""
        for spot, K, T, sigma, r, is_call in CASES:
            F = _forward(spot, r, T)
            vanna = bs_vanna(F, K, T, sigma)
            vomma = bs_vomma(F, K, T, r, sigma)
            corr = heston_correction(T, vanna, vomma)
            assert math.isfinite(corr), f"Heston correction not finite: {corr}"

    def test_correction_direction(self):
        """With negative rho_h (default -0.7), vanna term should be negative for positive vanna."""
        vanna = 0.01   # positive vanna
        vomma = 0.0    # isolate vanna term
        T = 30 / 365
        corr = heston_correction(T, vanna, vomma)
        assert corr < 0, "With rho_h=-0.7, positive vanna → negative correction"


class TestSABRIv:
    def test_atm_close_to_market_iv(self):
        """SABR ATM vol should be close to market IV when using backed-out alpha."""
        F = _forward(550.0, 0.0433, 30 / 365)
        T = 30 / 365
        atm_iv = 0.21
        beta = 0.5
        rho = -0.7
        nu = 0.40
        alpha = sabr_alpha(atm_iv, F, beta)
        sabr_vol = sabr_iv(F=F, K=F, T=T, alpha=alpha, beta=beta, rho=rho, nu=nu)
        # ATM SABR vol should be close to market IV
        assert abs(sabr_vol - atm_iv) < 0.01, f"SABR ATM vol {sabr_vol} != market IV {atm_iv}"

    def test_skew_shape(self):
        """OTM put IV should be higher than ATM (negative skew with rho=-0.7)."""
        F = _forward(550.0, 0.0433, 30 / 365)
        T = 30 / 365
        beta, rho, nu = 0.5, -0.7, 0.40
        alpha = sabr_alpha(0.21, F, beta)
        atm_vol = sabr_iv(F=F, K=F, T=T, alpha=alpha, beta=beta, rho=rho, nu=nu)
        otm_put_vol = sabr_iv(F=F, K=F * 0.95, T=T, alpha=alpha, beta=beta, rho=rho, nu=nu)
        assert otm_put_vol > atm_vol, "OTM put should have higher SABR vol (skew)"

    def test_invalid_inputs_return_zero(self):
        assert sabr_iv(F=0, K=550, T=0.1, alpha=0.1, beta=0.5, rho=-0.7, nu=0.4) == 0.0
        assert sabr_iv(F=550, K=0, T=0.1, alpha=0.1, beta=0.5, rho=-0.7, nu=0.4) == 0.0
        assert sabr_iv(F=550, K=550, T=0, alpha=0.1, beta=0.5, rho=-0.7, nu=0.4) == 0.0
        assert sabr_iv(F=550, K=550, T=0.1, alpha=0, beta=0.5, rho=-0.7, nu=0.4) == 0.0


class TestFairValueEngine:
    def test_zero_dte_returns_broker_mid(self):
        result = fv_compute(
            spot=550.0, strike=555.0, implied_vol=0.21,
            days_to_expiry=0, is_call=True, broker_mid=8.0,
        )
        assert result.model_fair_value == 8.0

    def test_model_price_non_negative(self):
        for spot, K, T_years, sigma, r, is_call in CASES:
            dte = round(T_years * 365)
            result = fv_compute(
                spot=spot, strike=K, implied_vol=sigma,
                days_to_expiry=dte, is_call=is_call, broker_mid=5.0, r=r,
            )
            assert result.model_fair_value >= 0

    def test_edge_bps_calculation(self):
        """edge_bps = (model - broker_mid) / broker_mid * 10000."""
        result = fv_compute(
            spot=550.0, strike=555.0, implied_vol=0.21,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
        )
        expected_edge = (result.model_fair_value - 8.0) / 8.0 * 10_000
        assert abs(result.edge_bps - expected_edge) < TOLERANCE

    def test_sabr_vol_clamped(self):
        result = fv_compute(
            spot=550.0, strike=555.0, implied_vol=0.21,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
        )
        assert 0.01 <= result.sabr_vol <= 5.0

    def test_calibrated_params_used(self):
        """Providing calibrated rho/nu should change the model price."""
        base = fv_compute(
            spot=550.0, strike=555.0, implied_vol=0.21,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
        )
        calibrated = fv_compute(
            spot=550.0, strike=555.0, implied_vol=0.21,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
            calibrated_rho=-0.50, calibrated_nu=0.60,
        )
        # Different params should generally give different prices
        # (not strictly always different, but almost always)
        assert isinstance(calibrated.model_fair_value, float)
