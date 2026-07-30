from __future__ import annotations
from typing import Optional

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
    SABR_RETRY_NU0,
    SABR_NU_DEGENERATE,
    SABR_ALPHA_BOUNDS,
    SABR_ALPHA_MAX_MULT,
    SABR_RHO_BOUNDS,
    SABR_NU_BOUNDS,
    SABR_RELIABLE_RMSE,
    SABR_RELIABLE_MIN_POINTS,
    NM_MAX_ITER,
    NM_FATOL,
    NM_XATOL,
)
from services.sabr import sabr_iv, sabr_alpha


def is_reliable_fit(rmse:Optional[float], n_points:Optional[int]) -> bool:
    """Canonical definition of a usable SABR slice.

    The single source of truth for the in-memory check. The DB-side equivalent
    is jobs/sabr_pull.apply_reliability_filter, which reads the same two
    constants — keep them in step. Both exist because one rule was previously
    re-typed inline at every call site, which is how the calibrator's bounds
    drifted from SABR_RHO_BOUNDS without anyone noticing.
    """
    if rmse is None or n_points is None:
        return False
    return n_points >= SABR_RELIABLE_MIN_POINTS and rmse < SABR_RELIABLE_RMSE


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
        return is_reliable_fit(self.rmse, self.n_points)

    def to_dict(self) -> dict:
        return {
            "dte": self.dte,
            "alpha": self.alpha,
            "beta": self.beta,
            "rho": self.rho,
            "nu": self.nu,
            "rmse": self.rmse,
            "n_points": self.n_points,
        }


def calibrate_slice(
    quotes: list[tuple[float, float]],  # (strike, market_iv) pairs
    F: float,
    T: float,
    beta: float = SABR_BETA,
) ->Optional[SabrSlice]:
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
            try:
                iv_model = sabr_iv(F=F, K=K, T=T, alpha=a, beta=beta, rho=rh, nu=nv)
            except (ValueError, ZeroDivisionError):
                sse += 1e4
                continue
            if iv_model <= 0 or math.isnan(iv_model):
                sse += 1e4
                continue
            
            diff = iv_model - iv_mkt
            sse += diff * diff
        return sse
    
    # alpha's ceiling scales with the ATM seed — a fixed cap is a cap on
    # sigma * F^(1-beta), which tightens as the underlying rises and pins every
    # high-priced or high-vol name on the boundary. See SABR_ALPHA_BOUNDS.
    alpha_lo = SABR_ALPHA_BOUNDS[0]
    alpha_hi = max(SABR_ALPHA_BOUNDS[1], SABR_ALPHA_MAX_MULT * alpha0)
    bounds = [(alpha_lo, alpha_hi), SABR_RHO_BOUNDS, SABR_NU_BOUNDS]

    # Nelder-Mead clips both x0 and the simplex it builds around x0 into the
    # box. An out-of-bounds seed collapses several vertices onto the same
    # boundary point, leaving the simplex rank-deficient in that direction —
    # the parameter then cannot move at all. Seed strictly inside the box.
    x0 = [
        min(max(alpha0, alpha_lo), alpha_hi),
        min(max(rho0, SABR_RHO_BOUNDS[0]), SABR_RHO_BOUNDS[1]),
        min(max(nu0, SABR_NU_BOUNDS[0]), SABR_NU_BOUNDS[1]),
    ]

    def _run(seed: list) -> tuple:
        res = minimize(
            objective,
            x0=seed,
            method="Nelder-Mead",
            bounds=bounds,
            options={
                "maxiter": NM_MAX_ITER,
                "fatol": NM_FATOL,
                "xatol": NM_XATOL,
            },
        )
        return float(res.fun), tuple(res.x)

    best_sse, best_x = _run(x0)

    # Nelder-Mead is a local method: on some slices it walks into a corner where
    # nu collapses to ~0 (a pure CEV smile, no vol-of-vol) or rho pins to +/-1,
    # fitting visibly worse than adjacent DTEs. Both show up as a parameter
    # sitting on a bound, so retry from a higher vol-of-vol seed only then —
    # a blanket multi-start would triple this job's runtime for the ~2/3 of
    # slices that already converge to the interior.
    # A retry that finds nothing better is discarded, so a false positive here
    # only costs one extra fit — prefer catching near-degenerate nu (0.001 is
    # as unphysical as 1e-6) over an exact bound test.
    def _on_bound(x: tuple) -> bool:
        _, rh, nv = x
        return (
            nv <= SABR_NU_DEGENERATE or nv >= SABR_NU_BOUNDS[1] * 0.999
            or abs(rh) >= SABR_RHO_BOUNDS[1] * 0.999
        )

    if _on_bound(best_x):
        for retry_nu in SABR_RETRY_NU0:
            sse_r, x_r = _run([x0[0], 0.0, retry_nu])
            if sse_r < best_sse:
                best_sse, best_x = sse_r, x_r
            if not _on_bound(best_x):
                break

    best_alpha, best_rho, best_nu = best_x

    # RMSE is only defined over strikes the model could actually price. Points
    # where SABR returns an invalid IV are excluded from the numerator AND the
    # denominator — so n_points must report n_valid, not len(clean). Reporting
    # the full quote count next to a partial RMSE (the previous behaviour) makes
    # the pair mutually inconsistent, and rmse/n_points are exactly the two
    # fields every read gate gates on.
    sse = 0.0
    n_valid = 0
    for K, iv_mkt in clean:
        try:
            iv_model = sabr_iv(F=F, K=K, T=T, alpha=best_alpha, beta=beta, rho=best_rho, nu=best_nu)
        except (ValueError, ZeroDivisionError):
            continue
        if iv_model <= 0 or math.isnan(iv_model):
            continue
        sse += (iv_model - iv_mkt) ** 2
        n_valid += 1

    # A parameter set that cannot price the minimum number of quotes is not a
    # fit, however small its error on the handful it managed.
    if n_valid < SABR_MIN_POINTS:
        return None

    rmse = math.sqrt(sse / n_valid)

    dte = round(T * 365)
    return SabrSlice(
        dte=dte,
        alpha=best_alpha,
        beta=beta,
        rho=best_rho,
        nu=best_nu,
        rmse=rmse,
        n_points=n_valid,
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
        T = dte / 365.0
        F = spot * math.exp(r * T)
        iv = _select_iv(p, F)
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



def _select_iv(point: dict, F: float) ->Optional[float]:
    """OTM convention: call IV for strike >= F, put IV otherwise.
    Falls back to whichever is available (matches SabrCalibrator._selectIv).
    """
    strike = float(point.get("strike", 0))
    call_iv = point.get("callIv") or point.get("call_iv")
    put_iv = point.get("putIv") or point.get("put_iv")
    if strike >= F:
        return float(call_iv) if call_iv else (float(put_iv) if put_iv else None)
    return float(put_iv) if put_iv else (float(call_iv) if call_iv else None)
