from __future__ import annotations

# =============================================================================
# tests/test_sabr_edge_cases.py
# =============================================================================
# Guards rho→1 blow-up, chi_z→0, empty-clean-list crash, and the physical
# rho bound (positive rho is unphysical for equity; calibrator upper = -0.01).
# =============================================================================

import math

from services.sabr import sabr_iv
from services.sabr_calibrator import calibrate_snapshot, calibrate_slice, SabrSlice


# ---------------------------------------------------------------------------
# sabr_iv — rho near +1: z/chi_z must not explode
# ---------------------------------------------------------------------------

class TestSabrIvRhoNearOne:
    """chi_z → 0 as rho → 1 (and z > 0); result must be clamped, not infinity."""

    def test_high_positive_rho_finite(self):
        iv = sabr_iv(F=100.0, K=105.0, T=0.25, alpha=0.20, beta=0.5, rho=0.98, nu=0.5)
        assert math.isfinite(iv), f"Expected finite IV, got {iv}"

    def test_high_positive_rho_bounded(self):
        iv = sabr_iv(F=100.0, K=105.0, T=0.25, alpha=0.20, beta=0.5, rho=0.9999, nu=0.5)
        assert iv <= 100.0, f"IV should be bounded, got {iv}"

    def test_high_negative_rho_finite(self):
        iv = sabr_iv(F=100.0, K=95.0, T=0.25, alpha=0.20, beta=0.5, rho=-0.98, nu=0.5)
        assert math.isfinite(iv), f"Expected finite IV, got {iv}"

    def test_atm_always_finite(self):
        for rho in (-0.99, -0.5, 0.0, 0.5, 0.99):
            iv = sabr_iv(F=100.0, K=100.0, T=0.25, alpha=0.20, beta=0.5, rho=rho, nu=0.5)
            assert math.isfinite(iv), f"ATM IV not finite at rho={rho}: {iv}"


# ---------------------------------------------------------------------------
# sabr_iv — guard clauses for invalid inputs
# ---------------------------------------------------------------------------

class TestSabrIvInvalidInputs:
    def test_zero_alpha_returns_zero(self):
        assert sabr_iv(100, 100, 0.25, alpha=0.0, beta=0.5, rho=-0.5, nu=0.5) == 0.0

    def test_negative_T_returns_zero(self):
        assert sabr_iv(100, 100, -1.0, alpha=0.2, beta=0.5, rho=-0.5, nu=0.5) == 0.0

    def test_zero_F_returns_zero(self):
        assert sabr_iv(0.0, 100, 0.25, alpha=0.2, beta=0.5, rho=-0.5, nu=0.5) == 0.0

    def test_zero_K_returns_zero(self):
        assert sabr_iv(100.0, 0.0, 0.25, alpha=0.2, beta=0.5, rho=-0.5, nu=0.5) == 0.0


# ---------------------------------------------------------------------------
# calibrate_slice — empty / degenerate inputs
# ---------------------------------------------------------------------------

class TestCalibrateSliceEdgeCases:
    """Guard: empty or all-invalid quotes must not ZeroDivisionError."""

    def test_empty_quotes_returns_none(self):
        result = calibrate_slice([], F=100.0, T=0.25)
        assert result is None

    def test_single_quote_returns_none(self):
        # 1 < SABR_MIN_POINTS so calibrate_slice must return None, not raise
        result = calibrate_slice([(100.0, 0.25)], F=100.0, T=0.25)
        assert result is None


# ---------------------------------------------------------------------------
# calibrate_snapshot — empty surface
# ---------------------------------------------------------------------------

class TestCalibrateSnapshotEdgeCases:
    def test_empty_points_returns_empty_list(self):
        result = calibrate_snapshot(spot=100.0, points=[])
        assert result == []

    def test_all_zero_iv_returns_empty_list(self):
        points = [{"strike": k, "dte": 30, "callIv": 0.0} for k in range(80, 121, 5)]
        result = calibrate_snapshot(spot=100.0, points=points)
        assert result == []

    def test_normal_surface_produces_slices(self):
        F = 100.0
        points = []
        for dte in (30, 60):
            for k, iv in [(85, 0.32), (90, 0.28), (95, 0.25), (100, 0.23),
                          (105, 0.24), (110, 0.26), (115, 0.29)]:
                iv_key = "callIv" if k >= F else "putIv"
                points.append({"strike": k, "dte": dte, iv_key: iv})
        slices = calibrate_snapshot(spot=100.0, points=points, r=0.05)
        assert len(slices) > 0
        for s in slices:
            assert math.isfinite(s.rmse)


# ---------------------------------------------------------------------------
# Calibrated rho must be non-positive (equity convention)
# ---------------------------------------------------------------------------

class TestSabrCalibratorRhoBound:
    """Calibrated rho <= -0.01; positive rho is unphysical for equity skew."""

    def test_calibrated_rho_non_positive(self):
        F = 100.0
        points = []
        for dte in (30, 60):
            for k, iv in [(85, 0.32), (90, 0.28), (95, 0.25), (100, 0.23),
                          (105, 0.24), (110, 0.26), (115, 0.29)]:
                iv_key = "callIv" if k >= F else "putIv"
                points.append({"strike": k, "dte": dte, iv_key: iv})
        slices = calibrate_snapshot(spot=100.0, points=points, r=0.05)
        for s in slices:
            assert s.rho <= -0.01, (
                f"Slice dte={s.dte}: calibrated rho={s.rho:.4f} is positive "
                "(unphysical for equity)"
            )
