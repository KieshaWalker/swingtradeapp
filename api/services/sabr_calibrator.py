from __future__ import annotations

# =============================================================================
# services/sabr_calibrator.py
# =============================================================================
# Surface-level SABR calibration using scipy Nelder-Mead optimizer.
# Exact port of SabrCalibrator._calibrateSync() from sabr_calibrator.dart.
#
# What this does:
#   Fits (α, ρ, ν) jointly to all (strike, IV) pairs in a DTE slice,
#   minimising sum of squared IV errors:
#       min Σᵢ [σ_market(Kᵢ) − σ_SABR(Kᵢ; α, ρ, ν)]²
#
# β is fixed at 0.5 (square-root CEV — standard for equity vol surfaces).
# =============================================================================

import math
from dataclasses import dataclass
from scipy.optimize import minimize
import numpy as np

from core.constants import (
    DEFAULT_R,
    SABR_BETA,
    SABR_MIN_POINTS,
    SABR_MAX_IV_FILTER,
    SABR_INITIAL_RHO0,
    SABR_INITIAL_NU0,
    SABR_RELIABLE_RMSE,
    SABR_RELIABLE_MIN_POINTS,
    NM_MAX_ITER,
    NM_FATOL,
    NM_XATOL,
)
from services.sabr import sabr_iv, sabr_alpha


@dataclass
class SabrSlice:
    dte: int
    alpha: float
    beta: float
    rho: float
    nu: float
    rmse: float
    n_points: int

    @property
    def is_reliable(self) -> bool:
        return self.n_points >= SABR_RELIABLE_MIN_POINTS and self.rmse < SABR_RELIABLE_RMSE

    def to_dict(self) -> dict:
        return {
            "dte": self.dte,
            "alpha": self.alpha,
            "beta": self.beta,
            "rho": self.rho,
            "nu": self.nu,
            "rmse": self.rmse,
            "n_points": self.n_points,
            "is_reliable": self.is_reliable,
        }


def calibrate_slice(
    quotes: list[tuple[float, float]],  # (strike, market_iv) pairs
    F: float,
    T: float,
    beta: float = SABR_BETA,
) -> SabrSlice | None:
    """Fit SABR (alpha, rho, nu) to market (strike, IV) quotes for one DTE slice.

    Matches SabrCalibrator._calibrateSync() objective and NelderMead settings.

    Args:
        quotes: List of (strike, market_iv_decimal) pairs.
        F: Forward price for this DTE (spot * exp(r*T)).
        T: Time to expiry in years.
        beta: CEV exponent (default 0.5, fixed).

    Returns:
        SabrSlice or None if fewer than SABR_MIN_POINTS quotes.
    """
    if len(quotes) < SABR_MIN_POINTS:
        return None

    # Filter extreme IVs (data errors)
    clean = [(K, iv) for K, iv in quotes if 0 < iv <= SABR_MAX_IV_FILTER]
    if len(clean) < SABR_MIN_POINTS:
        return None

    # ATM IV: pick quote closest to forward
    atm_quote = min(clean, key=lambda q: abs(q[0] - F))
    atm_iv = atm_quote[1]

    # Initial guess — matches sabr_calibrator.dart exactly
    alpha0 = sabr_alpha(atm_iv, F, beta)
    rho0 = SABR_INITIAL_RHO0
    nu0 = SABR_INITIAL_NU0

    def objective(params: np.ndarray) -> float:
        a, rh, nv = params
        sse = 0.0
        for K, iv_mkt in clean:
            iv_model = sabr_iv(F=F, K=K, T=T, alpha=a, beta=beta, rho=rh, nu=nv)
            # Use a severe penalty for domain failures, not just 1.0
            if iv_model <= 0 or math.isnan(iv_model):
                sse += 1e4 
                continue
            
            diff = iv_model - iv_mkt
            sse += diff * diff
        return sse
    
    bounds = [(1e-6, 5.0), (-0.999, 0.999), (1e-6, 5.0)]

    result = minimize(
        objective,
        x0=[alpha0, rho0, nu0],
        method="Nelder-Mead",
        bounds=bounds,
        options={
            "maxiter": NM_MAX_ITER,
            "fatol": NM_FATOL,
            "xatol": NM_XATOL,
        },
    )

    best_alpha, best_rho, best_nu = result.x

    # Compute RMSE
    sse = 0.0
    for K, iv_mkt in clean:
        iv_model = sabr_iv(F=F, K=K, T=T, alpha=best_alpha, beta=beta, rho=best_rho, nu=best_nu)
        diff = (iv_model - iv_mkt) if iv_model > 0 else iv_mkt
        sse += diff * diff
    rmse = math.sqrt(sse / len(clean))

    dte = round(T * 365)
    return SabrSlice(
        dte=dte,
        alpha=best_alpha,
        beta=beta,
        rho=best_rho,
        nu=best_nu,
        rmse=rmse,
        n_points=len(clean),
    )


def calibrate_snapshot(
    spot: float,
    points: list[dict],  # [{strike, dte, callIv?, putIv?}]
    r: float = DEFAULT_R,
    beta: float = SABR_BETA,
) -> list[SabrSlice]:
    """Calibrate SABR for every DTE slice in a vol surface snapshot.

    Args:
        spot: Underlying price.
        points: List of vol surface points (same shape as Supabase vol_surface_snapshots.points).
        r: Risk-free rate.
        beta: CEV exponent (fixed 0.5).

    Returns:
        List of SabrSlice sorted by DTE ascending.
    """
    # Group by DTE
    by_dte: dict[int, list[tuple[float, float]]] = {}
    for p in points:
        dte = int(p.get("dte", 0))
        strike = float(p.get("strike", 0))
        if dte <= 0 or strike <= 0:
            continue
        iv = _select_iv(p, spot)
        if iv is None or iv <= 0 or iv > SABR_MAX_IV_FILTER:
            continue
        by_dte.setdefault(dte, []).append((strike, iv))

    slices = []
    for dte, quotes in by_dte.items():
        T = dte / 365.0
        F = spot * math.exp(r * T)
        s = calibrate_slice(quotes, F=F, T=T, beta=beta)
        if s is not None:
            slices.append(s)

    slices.sort(key=lambda s: s.dte)
    return slices


def slice_for_dte(slices: list[SabrSlice], target_dte: int) -> SabrSlice | None:
    """Return the calibrated slice closest to target_dte."""
    if not slices:
        return None
    return min(slices, key=lambda s: abs(s.dte - target_dte))


def _select_iv(point: dict, spot: float) -> float | None:
    """OTM convention: call IV for strike >= spot, put IV otherwise.
    Falls back to whichever is available (matches SabrCalibrator._selectIv).
    """
    strike = float(point.get("strike", 0))
    call_iv = point.get("callIv") or point.get("call_iv")
    put_iv = point.get("putIv") or point.get("put_iv")
    if strike >= spot:
        return float(call_iv) if call_iv else (float(put_iv) if put_iv else None)
    return float(put_iv) if put_iv else (float(call_iv) if call_iv else None)
