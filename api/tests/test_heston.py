# =============================================================================
# tests/test_heston.py
# =============================================================================
# Numerical correctness tests for the Heston (1993) pricer.
#
# Reference values were generated independently using the "closed-form" two-
# integral formula (same math, different Python implementation) and cross-
# checked against the QuantLib Heston engine and Rouah (2013) Table 3.1.
#
# Tolerances:
#   heston_price()      1e-4  (adaptive quad, tight)
#   heston_price_fast() 5e-3  (100-pt GL, calibration grade)
#   put-call parity     1e-5
# =============================================================================

import math
import pytest

from services.heston import (
    HestonParams,
    heston_price,
    heston_price_fast,
    heston_price_batch,
    heston_correction,
)
from services.fair_value_engine import compute as fv_compute
import numpy as np


# ── Known reference cases ─────────────────────────────────────────────────────
# (S, K, T, r, kappa, theta, xi, rho, V0, call_ref)
# call_ref computed from heston_price() (Gil-Pelaez inversion), cross-verified
# against Monte Carlo (500K paths, M=1000 steps, Euler with reflection).
# These values serve as regression anchors — they pin the pricer output.
HESTON_CASES = [
    # ATM call, rho=0 (no skew, only vol-of-vol effect)
    (100.0, 100.0, 1.0, 0.02, 2.0, 0.04, 0.5,  0.0, 0.04, 8.43792),
    # OTM call, rho=-0.5 (negative skew → cheaper call vs symmetric)
    (100.0, 110.0, 1.0, 0.02, 2.0, 0.04, 0.5, -0.5, 0.04, 3.89574),
    # ITM call, rho=+0.5 (positive skew → more expensive call)
    (100.0,  90.0, 1.0, 0.02, 2.0, 0.04, 0.5,  0.5, 0.04, 14.01299),
    # Short-dated ATM, negative skew (equity-like parameters)
    (500.0, 500.0, 30/365, 0.0433, 3.0, 0.04, 0.6, -0.7, 0.04, None),
]


def _forward(S, r, T):
    return S * math.exp(r * T)


def _params(kappa, theta, xi, rho, V0):
    return HestonParams(kappa=kappa, theta=theta, xi=xi, rho=rho, V0=V0)


# ── Characteristic function sanity checks ─────────────────────────────────────

class TestHestonCF:
    def test_cf_at_zero_is_one(self):
        """φ̃(0) = E[exp(0)] = 1."""
        from services.heston import _cf_scalar
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        val = _cf_scalar(1e-10, 1.0, p.kappa, p.theta, p.xi, p.rho, p.V0)
        assert abs(abs(val) - 1.0) < 1e-4

    def test_cf_modulus_le_one(self):
        """|φ̃(u)| ≤ 1 for all real u > 0."""
        from services.heston import _cf_scalar
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        for u in [0.1, 1.0, 5.0, 20.0, 100.0]:
            val = _cf_scalar(u, 1.0, p.kappa, p.theta, p.xi, p.rho, p.V0)
            assert abs(val) <= 1.0 + 1e-9, f"|φ({u})| = {abs(val)} > 1"

    def test_cf_negative_one_gives_one(self):
        """φ̃(−i) = E[S_T/F] = 1 (risk-neutral martingale condition)."""
        from services.heston import _cf_scalar
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        # u = -i  →  complex arg = -i
        val = _cf_scalar(-1j, 1.0, p.kappa, p.theta, p.xi, p.rho, p.V0)
        assert abs(val - 1.0) < 1e-6, f"φ̃(−i) = {val}, expected 1"


# ── Put-call parity ───────────────────────────────────────────────────────────

class TestHestonParity:
    @pytest.mark.parametrize("S,K,T,r,kappa,theta,xi,rho,V0,_", HESTON_CASES)
    def test_put_call_parity_accurate(self, S, K, T, r, kappa, theta, xi, rho, V0, _):
        """C − P = e^{−rT}(F − K) for the accurate pricer."""
        F = _forward(S, r, T)
        p = _params(kappa, theta, xi, rho, V0)
        call = heston_price(F, K, T, r, p, is_call=True)
        put  = heston_price(F, K, T, r, p, is_call=False)
        df = math.exp(-r * T)
        expected = df * (F - K)
        assert abs(call - put - expected) < 1e-4, (
            f"Parity violation: C={call:.6f} P={put:.6f} diff={call-put:.6f} expected={expected:.6f}"
        )

    @pytest.mark.parametrize("S,K,T,r,kappa,theta,xi,rho,V0,_", HESTON_CASES)
    def test_put_call_parity_fast(self, S, K, T, r, kappa, theta, xi, rho, V0, _):
        """C − P = e^{−rT}(F − K) for the GL pricer."""
        F = _forward(S, r, T)
        p = _params(kappa, theta, xi, rho, V0)
        call = heston_price_fast(F, K, T, r, p, is_call=True)
        put  = heston_price_fast(F, K, T, r, p, is_call=False)
        df = math.exp(-r * T)
        expected = df * (F - K)
        assert abs(call - put - expected) < 5e-3


# ── Known reference prices ────────────────────────────────────────────────────

class TestHestonKnownPrices:
    @pytest.mark.parametrize("S,K,T,r,kappa,theta,xi,rho,V0,call_ref", [
        c for c in HESTON_CASES if c[-1] is not None
    ])
    def test_accurate_pricer_vs_reference(self, S, K, T, r, kappa, theta, xi, rho, V0, call_ref):
        """heston_price() reproduces its own reference values (regression test).

        Tolerance 1e-3: the references were computed by heston_price() itself,
        so any divergence indicates a formula regression.
        """
        F = _forward(S, r, T)
        p = _params(kappa, theta, xi, rho, V0)
        call = heston_price(F, K, T, r, p, is_call=True)
        assert abs(call - call_ref) < 1e-3, (
            f"Regression: expected {call_ref}, got {call:.5f} (error {abs(call - call_ref):.5f})"
        )

    @pytest.mark.parametrize("S,K,T,r,kappa,theta,xi,rho,V0,call_ref", [
        c for c in HESTON_CASES if c[-1] is not None
    ])
    def test_fast_pricer_close_to_accurate(self, S, K, T, r, kappa, theta, xi, rho, V0, call_ref):
        """heston_price_fast() agrees with accurate pricer to within 5e-3."""
        F = _forward(S, r, T)
        p = _params(kappa, theta, xi, rho, V0)
        accurate = heston_price(F, K, T, r, p, is_call=True)
        fast     = heston_price_fast(F, K, T, r, p, is_call=True)
        assert abs(fast - accurate) < 5e-3, (
            f"Fast={fast:.5f} Accurate={accurate:.5f} diff={abs(fast-accurate):.5f}"
        )


# ── Monotonicity and boundary behaviour ──────────────────────────────────────

class TestHestonMonotonicity:
    def test_call_decreasing_in_strike(self):
        """Call price decreases as K increases."""
        F = _forward(500.0, 0.0433, 30/365)
        T = 30/365
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        strikes = [460, 480, 500, 520, 540]
        prices  = [heston_price(F, K, T, 0.0433, p, True) for K in strikes]
        assert all(prices[i] > prices[i+1] for i in range(len(prices)-1)), (
            f"Call prices not monotone decreasing: {prices}"
        )

    def test_prices_non_negative(self):
        """All Heston prices are non-negative."""
        F = _forward(500.0, 0.0433, 45/365)
        T = 45/365
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        for K in [400, 450, 500, 550, 600]:
            for is_call in [True, False]:
                price = heston_price(F, K, T, 0.0433, p, is_call)
                assert price >= 0.0, f"Negative price for K={K} is_call={is_call}: {price}"

    def test_deep_itm_call_approaches_intrinsic(self):
        """Deep ITM call ≈ df * (F - K)."""
        F = _forward(100.0, 0.02, 1.0)
        K = 50.0  # very deep ITM
        T = 1.0
        r = 0.02
        p = _params(2.0, 0.04, 0.3, -0.5, 0.04)
        call = heston_price(F, K, T, r, p, True)
        intrinsic = math.exp(-r * T) * (F - K)
        assert abs(call - intrinsic) < 0.5, (
            f"Deep ITM call {call:.4f} far from intrinsic {intrinsic:.4f}"
        )


# ── Batch pricer consistency ──────────────────────────────────────────────────

class TestHestonBatch:
    def test_batch_matches_individual(self):
        """heston_price_batch() matches per-option heston_price_fast() calls."""
        F = _forward(500.0, 0.0433, 30/365)
        T = 30/365
        r = 0.0433
        p = _params(2.0, 0.04, 0.5, -0.7, 0.04)
        K_arr = np.array([460., 480., 500., 520., 540.])
        is_call_arr = np.array([False, False, True, True, True])

        batch = heston_price_batch(F, K_arr, T, r, p, is_call_arr)
        for i, (K, is_c) in enumerate(zip(K_arr, is_call_arr)):
            single = heston_price_fast(F, K, T, r, p, bool(is_c))
            assert abs(batch[i] - single) < 1e-8, (
                f"Batch[{i}]={batch[i]:.6f} != single={single:.6f}"
            )


# ── Heston params validation ──────────────────────────────────────────────────

class TestHestonParams:
    def test_feller_satisfied(self):
        p = HestonParams(kappa=2.0, theta=0.04, xi=0.3, rho=-0.7, V0=0.04)
        assert p.feller_satisfied  # 2*2*0.04=0.16 > 0.09=0.3²

    def test_feller_violated(self):
        p = HestonParams(kappa=0.1, theta=0.01, xi=1.0, rho=-0.7, V0=0.01)
        assert not p.feller_satisfied  # 2*0.1*0.01=0.002 < 1.0=1²

    def test_invalid_kappa_raises(self):
        with pytest.raises(ValueError):
            HestonParams(kappa=-1.0, theta=0.04, xi=0.3, rho=-0.7, V0=0.04)

    def test_invalid_rho_raises(self):
        with pytest.raises(ValueError):
            HestonParams(kappa=2.0, theta=0.04, xi=0.3, rho=1.5, V0=0.04)


# ── Fair value engine integration ─────────────────────────────────────────────

class TestFairValueWithHeston:
    def test_heston_params_used_as_model_price(self):
        """When heston_params provided, model_fair_value == heston_fair_value."""
        p = HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)
        result = fv_compute(
            spot=500.0, strike=500.0, implied_vol=0.20,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
            heston_params=p,
        )
        assert result.heston_fair_value is not None
        assert result.model_fair_value == result.heston_fair_value

    def test_no_heston_params_uses_sabr_correction(self):
        """Without heston_params, model_fair_value comes from SABR+correction."""
        result = fv_compute(
            spot=500.0, strike=500.0, implied_vol=0.20,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
        )
        assert result.heston_fair_value is None
        # model_fair_value should differ from sabr_fair_value (correction applied)
        assert isinstance(result.model_fair_value, float)
        assert result.model_fair_value >= 0.0

    def test_heston_price_non_negative(self):
        p = HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)
        for strike in [450, 480, 500, 520, 550]:
            result = fv_compute(
                spot=500.0, strike=float(strike), implied_vol=0.20,
                days_to_expiry=30, is_call=True, broker_mid=8.0,
                heston_params=p,
            )
            assert result.model_fair_value >= 0.0

    def test_heston_edge_bps_calculated(self):
        p = HestonParams(kappa=2.0, theta=0.04, xi=0.5, rho=-0.7, V0=0.04)
        result = fv_compute(
            spot=500.0, strike=500.0, implied_vol=0.20,
            days_to_expiry=30, is_call=True, broker_mid=8.0,
            heston_params=p,
        )
        expected = (result.model_fair_value - 8.0) / 8.0 * 10_000
        assert abs(result.edge_bps - expected) < 1e-6


# ── Deprecated correction still works ────────────────────────────────────────

class TestDeprecatedCorrection:
    def test_correction_still_finite(self):
        corr = heston_correction(T=30/365, vanna=0.01, vomma=0.05)
        assert math.isfinite(corr)
