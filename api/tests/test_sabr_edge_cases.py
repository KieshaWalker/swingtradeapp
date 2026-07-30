from __future__ import annotations

# =============================================================================
# tests/test_sabr_edge_cases.py
# =============================================================================
# Guards rho→1 blow-up, chi_z→0, empty-clean-list crash, and that calibrated
# rho tracks the sign of the observed skew.
# =============================================================================

import math

from core.constants import SABR_RHO_BOUNDS, SABR_RELIABLE_RMSE, SABR_RELIABLE_MIN_POINTS
from services.sabr import sabr_iv
from services.sabr_calibrator import (
    calibrate_snapshot, calibrate_slice, SabrSlice, is_reliable_fit,
)


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
# Calibrated rho must track the sign of the observed skew
# ---------------------------------------------------------------------------

def _surface(quotes: list, spot: float = 100.0) -> list:
    return [
        {"strike": k, "dte": dte, ("callIv" if k >= spot else "putIv"): iv}
        for dte in (30, 60)
        for k, iv in quotes
    ]


class TestSabrCalibratorRho:
    """rho is the spot-vol correlation — its sign is an *output* of the fit.

    This previously asserted rho <= -0.01 against the calibrator's own upper
    bound of -0.01, so it could not fail regardless of the data: it tested the
    clamp, not the calibration. Worse, its fixture was a near-symmetric smile
    whose true rho is ~0, so the assertion contradicted the input. Now that the
    bound is the full (-0.999, 0.999), assert the property that actually
    matters — rho recovers the skew direction present in the quotes.
    """

    # Monotone put skew: 42% at -15% vs 23.5% at +15%. The equity leverage
    # effect, and the case the old test meant to protect.
    SKEWED = [(85, 0.42), (90, 0.36), (95, 0.31), (100, 0.28),
              (105, 0.26), (110, 0.245), (115, 0.235)]

    # Near-symmetric smile: 32% at -15% vs 29% at +15%. True rho ~ 0.
    SYMMETRIC = [(85, 0.32), (90, 0.28), (95, 0.25), (100, 0.23),
                 (105, 0.24), (110, 0.26), (115, 0.29)]

    def test_put_skew_gives_negative_rho(self):
        slices = calibrate_snapshot(spot=100.0, points=_surface(self.SKEWED), r=0.05)
        assert slices
        for s in slices:
            assert s.rho < -0.2, (
                f"Slice dte={s.dte}: rho={s.rho:.4f} — a monotone put skew "
                "must calibrate to clearly negative spot-vol correlation"
            )

    def test_symmetric_smile_gives_near_zero_rho(self):
        slices = calibrate_snapshot(spot=100.0, points=_surface(self.SYMMETRIC), r=0.05)
        assert slices
        for s in slices:
            assert abs(s.rho) < 0.2, (
                f"Slice dte={s.dte}: rho={s.rho:.4f} — a near-symmetric smile "
                "carries no directional skew and must not calibrate to a strong rho"
            )

    def test_rho_stays_within_bounds(self):
        for quotes in (self.SKEWED, self.SYMMETRIC):
            for s in calibrate_snapshot(spot=100.0, points=_surface(quotes), r=0.05):
                assert SABR_RHO_BOUNDS[0] <= s.rho <= SABR_RHO_BOUNDS[1]


# ---------------------------------------------------------------------------
# alpha's ceiling must scale with the underlying
# ---------------------------------------------------------------------------

class TestSabrAlphaScaling:
    """alpha ~ sigma * F^(1-beta), so a fixed ceiling caps the representable
    vol at ceiling/sqrt(F) — a bound that silently tightens as price rises.

    A flat cap of 5.0 limited a $1,230 underlying to 14% vol and pinned every
    fit on the boundary (SNDK, 2026-07: alpha=5.000, nu=5.000, rmse=118 vol
    points). These fixtures reproduce the two regimes that broke.
    """

    @staticmethod
    def _flat_surface(spot: float, vol: float) -> list:
        """Flat smile at `vol` — recoverable exactly, so any material RMSE
        means a parameter hit a bound rather than the fit being hard."""
        return [
            {"strike": round(spot * m, 2), "dte": dte,
             ("callIv" if m >= 1.0 else "putIv"): vol}
            for dte in (22, 45)
            for m in (0.80, 0.85, 0.90, 0.95, 1.0, 1.05, 1.10, 1.15, 1.20)
        ]

    def test_high_priced_underlying_calibrates(self):
        # F ~ 1230 at 140% vol needs alpha ~ 49 — 10x the old cap.
        slices = calibrate_snapshot(
            spot=1230.0, points=self._flat_surface(1230.0, 1.40), r=0.04
        )
        assert slices
        for s in slices:
            assert s.rmse < 0.015, (
                f"Slice dte={s.dte}: rmse={s.rmse * 100:.1f} vol pts on a flat "
                f"surface — alpha={s.alpha:.2f} is likely bound-pinned"
            )
            assert s.alpha > 5.0, (
                f"Slice dte={s.dte}: alpha={s.alpha:.3f} did not exceed the old "
                "fixed ceiling; the scaled bound is not taking effect"
            )

    def test_low_priced_underlying_still_calibrates(self):
        # The scaled ceiling must not regress small underlyings, where the
        # static floor (5.0) is the binding value.
        slices = calibrate_snapshot(
            spot=12.0, points=self._flat_surface(12.0, 0.45), r=0.04
        )
        assert slices
        for s in slices:
            assert s.rmse < 0.015, (
                f"Slice dte={s.dte}: rmse={s.rmse * 100:.1f} vol pts on a flat surface"
            )

    def test_alpha_recovers_atm_vol(self):
        """alpha / F^(1-beta) should return the ATM vol it was fit to."""
        spot, vol = 1230.0, 1.40
        for s in calibrate_snapshot(
            spot=spot, points=self._flat_surface(spot, vol), r=0.04
        ):
            F = spot * math.exp(0.04 * s.dte / 365.0)
            implied_atm = s.alpha / (F ** (1 - s.beta))
            assert abs(implied_atm - vol) < 0.05, (
                f"Slice dte={s.dte}: alpha implies {implied_atm:.1%} ATM vol, "
                f"fit to {vol:.1%}"
            )


# ---------------------------------------------------------------------------
# rmse and n_points must describe the same set of quotes
# ---------------------------------------------------------------------------

class TestSabrRmseNPointsConsistency:
    """rmse is computed only over strikes the model could price, so n_points
    must report that same count.

    Previously n_points returned len(clean) — every quote fed in — while rmse
    was averaged over just the ones SABR priced successfully. The pair is what
    every read gate filters on (see jobs/sabr_pull.apply_reliability_filter),
    so an inflated n_points beside a partial rmse can carry a bad slice through
    the gate.
    """

    def test_n_points_matches_rmse_denominator(self):
        quotes = [(85, 0.42), (90, 0.36), (95, 0.31), (100, 0.28),
                  (105, 0.26), (110, 0.245), (115, 0.235)]
        s = calibrate_slice(quotes, F=100.0, T=0.25)
        assert s is not None
        n_priced = sum(
            1 for K, _ in quotes
            if (lambda m: m > 0 and not math.isnan(m))(
                sabr_iv(F=100.0, K=K, T=0.25, alpha=s.alpha,
                        beta=s.beta, rho=s.rho, nu=s.nu)
            )
        )
        assert s.n_points == n_priced, (
            f"n_points={s.n_points} but the model priced {n_priced} strikes; "
            "rmse was averaged over the latter"
        )

    def test_n_points_never_exceeds_quotes_supplied(self):
        quotes = [(85, 0.42), (90, 0.36), (95, 0.31), (100, 0.28), (105, 0.26)]
        s = calibrate_slice(quotes, F=100.0, T=0.25)
        assert s is not None
        assert s.n_points <= len(quotes)

    def test_rmse_is_finite_when_slice_returned(self):
        quotes = [(85, 0.42), (90, 0.36), (95, 0.31), (100, 0.28), (105, 0.26)]
        s = calibrate_slice(quotes, F=100.0, T=0.25)
        assert s is not None
        assert math.isfinite(s.rmse), "a returned slice must carry a usable rmse"


# ---------------------------------------------------------------------------
# One definition of "reliable"
# ---------------------------------------------------------------------------

class TestReliabilityPredicate:
    """SabrSlice.is_reliable must delegate to is_reliable_fit, so the in-memory
    check and the DB filter cannot drift apart."""

    def test_slice_property_matches_predicate(self):
        for rmse, n in [(0.001, 40), (0.02, 40), (0.001, 2), (0.015, 5)]:
            s = SabrSlice(dte=30, alpha=2.0, beta=0.5, rho=-0.3, nu=0.4,
                          rmse=rmse, n_points=n)
            assert s.is_reliable == is_reliable_fit(rmse, n)

    def test_none_inputs_are_not_reliable(self):
        assert is_reliable_fit(None, 40) is False
        assert is_reliable_fit(0.001, None) is False

    def test_threshold_boundaries(self):
        assert is_reliable_fit(SABR_RELIABLE_RMSE - 1e-9, SABR_RELIABLE_MIN_POINTS)
        assert not is_reliable_fit(SABR_RELIABLE_RMSE, SABR_RELIABLE_MIN_POINTS)
        assert not is_reliable_fit(0.001, SABR_RELIABLE_MIN_POINTS - 1)
