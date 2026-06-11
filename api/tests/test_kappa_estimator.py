from __future__ import annotations

# =============================================================================
# tests/test_kappa_estimator.py
# =============================================================================
# Historical Heston parameter estimation: simulate a Heston path with known
# parameters and check recovery; verify the failure modes raise cleanly.
#
# Tolerances are wide on purpose: kappa is a hard parameter to identify even
# from 10 years of daily data. The point of these tests is to catch
# order-of-magnitude regressions (e.g. the naive-OLS attenuation bias that
# returned kappa ~ 40 for a true kappa of 3), not decimal accuracy.
# =============================================================================

import numpy as np
import pytest

from services.kappa_estimator import (
    EstimationError,
    estimate_from_closes,
)

TRUE_KAPPA = 3.0
TRUE_THETA = 0.04
TRUE_XI = 0.4
TRUE_V0 = 0.04


def _simulate_heston_closes(years: float, seed: int) -> list[float]:
    """Daily closes from a full-truncation Euler Heston simulation."""
    rng = np.random.default_rng(seed)
    n = int(252 * years)
    dt = 1 / 252
    v = TRUE_V0
    closes = [100.0]
    for _ in range(n):
        z1, z2 = rng.standard_normal(2)
        vp = max(v, 0.0)
        closes.append(
            closes[-1] * float(np.exp(-0.5 * vp * dt + np.sqrt(vp * dt) * z1))
        )
        v = v + TRUE_KAPPA * (TRUE_THETA - v) * dt + TRUE_XI * float(np.sqrt(vp * dt)) * z2
    return closes


class TestRecovery:
    def test_recovers_kappa_order_of_magnitude(self):
        est = estimate_from_closes(_simulate_heston_closes(10, seed=0))
        assert 1.0 < est.kappa < 9.0, f"kappa {est.kappa} vs true {TRUE_KAPPA}"

    def test_recovers_theta(self):
        est = estimate_from_closes(_simulate_heston_closes(10, seed=0))
        assert 0.02 < est.theta < 0.06, f"theta {est.theta} vs true {TRUE_THETA}"

    def test_recovers_xi_order_of_magnitude(self):
        est = estimate_from_closes(_simulate_heston_closes(10, seed=0))
        assert 0.1 < est.xi < 1.0, f"xi {est.xi} vs true {TRUE_XI}"

    def test_v0_positive_and_plausible(self):
        est = estimate_from_closes(_simulate_heston_closes(10, seed=0))
        assert 0.001 < est.v0 < 0.5

    def test_half_life_consistent_with_kappa(self):
        est = estimate_from_closes(_simulate_heston_closes(10, seed=0))
        assert abs(est.half_life_days - np.log(2) / est.kappa * 365) < 1e-9

    def test_stable_across_seeds(self):
        """No seed should fail or return a wildly biased kappa on 10y data."""
        for seed in range(5):
            est = estimate_from_closes(_simulate_heston_closes(10, seed=seed))
            assert 0.5 < est.kappa < 15.0, f"seed {seed}: kappa {est.kappa}"


class TestFailureModes:
    def test_too_short_raises(self):
        closes = list(100 + np.cumsum(np.ones(50)))
        with pytest.raises(EstimationError, match="at least"):
            estimate_from_closes(closes)

    def test_flat_prices_raise(self):
        with pytest.raises(EstimationError):
            estimate_from_closes([100.0] * 600)

    def test_constant_vol_gbm_raises(self):
        """GBM has no vol dynamics — there is no mean reversion to estimate."""
        rng = np.random.default_rng(1)
        rets = rng.standard_normal(2520) * 0.01
        closes = list(100 * np.exp(np.cumsum(rets)))
        with pytest.raises(EstimationError):
            estimate_from_closes(closes)

    def test_zero_prices_skipped(self):
        """Zero/negative closes are dropped, not propagated into returns."""
        closes = _simulate_heston_closes(10, seed=0)
        closes[100] = 0.0
        est = estimate_from_closes(closes)
        assert est.kappa > 0
