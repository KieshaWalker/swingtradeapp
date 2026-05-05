from __future__ import annotations

# =============================================================================
# services/heston_calibrator.py
# =============================================================================
# Calibrate Heston (1993) parameters to a vol-surface snapshot.
#
# Objective: min_{κ,θ,ξ,ρ,V₀}  Σᵢ (IV_heston(Fᵢ,Kᵢ,Tᵢ) − IV_mktᵢ)²
#
# Speed strategy:
#   • heston_price_batch() prices all strikes for a given T in one shot
#     (CF computed once per T, then matrix ops over K × GL-nodes).
#   • IV inversion uses bisection (50 iterations ≈ 1e-7 precision).
#   • Outer optimiser: differential_evolution (global) → Nelder-Mead (local).
# =============================================================================

import math
from dataclasses import dataclass

import numpy as np
from scipy.optimize import differential_evolution, minimize
from scipy.special import ndtr as _ndtr

from core.constants import DEFAULT_R
from services.heston import HestonParams, heston_price_batch


@dataclass
class HestonCalibResult:
    params: HestonParams
    rmse_iv: float         # root-mean-square IV error (decimal, e.g. 0.01 = 1 vol point)
    n_points: int          # number of (K, T) quotes used
    converged: bool        # True if local refinement reported success

    @property
    def is_reliable(self) -> bool:
        return self.n_points >= 8 and self.rmse_iv < 0.02  # < 2 vol points


# ── IV inversion ──────────────────────────────────────────────────────────────

def _bs_iv_batch(
    prices: np.ndarray,
    F: float,
    K_arr: np.ndarray,
    T: float,
    r: float,
    is_call_arr: np.ndarray,
) -> np.ndarray:
    """Vectorized Black-Scholes IV via bisection — returns NaN for invalid inputs.

    Replaces per-strike scalar bisection loops; ~50x faster in the calibration
    objective because all strikes at a given T are solved in 50 numpy array ops.
    """
    df = math.exp(-r * T)
    sqrt_T = math.sqrt(T)
    log_fk = np.log(F / K_arr)

    intrinsic = np.where(
        is_call_arr,
        np.maximum(df * (F - K_arr), 0.0),
        np.maximum(df * (K_arr - F), 0.0),
    )
    valid = prices > intrinsic + 1e-10

    lo = np.full(len(prices), 1e-4)
    hi = np.full(len(prices), 10.0)

    for _ in range(50):
        mid = 0.5 * (lo + hi)
        sig_sqt = mid * sqrt_T
        d1 = (log_fk + 0.5 * mid * mid * T) / sig_sqt
        d2 = d1 - sig_sqt
        p_call = df * (F * _ndtr(d1) - K_arr * _ndtr(d2))
        p_put  = df * (K_arr * _ndtr(-d2) - F * _ndtr(-d1))
        p_mid  = np.where(is_call_arr, p_call, p_put)
        lo = np.where(p_mid < prices, mid, lo)
        hi = np.where(p_mid >= prices, mid, hi)

    result = 0.5 * (lo + hi)
    return np.where(valid & (result < 9.99), result, np.nan)


# ── Surface parsing (same format as SABR calibrator) ─────────────────────────

def _build_quotes(
    surface_points: list[dict],
    spot: float,
    r: float,
) -> dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]]:
    """Parse surface_points into {dte: (F, K_arr, iv_arr, is_call_arr)}.

    OTM convention: call IV for K ≥ F, put IV for K < F.
    Drops strikes with IV == 0 or IV > 3.0 (data errors).
    """
    by_dte: dict[int, list[tuple[float, float, bool]]] = {}
    for p in surface_points:
        dte = int(p.get("dte", 0))
        K = float(p.get("strike", 0))
        if dte <= 0 or K <= 0:
            continue

        T = dte / 365.0
        F = spot * math.exp(r * T)
        is_call = K >= F

        call_iv = p.get("callIv") or p.get("call_iv")
        put_iv  = p.get("putIv") or p.get("put_iv")
        raw_iv  = (call_iv if is_call else put_iv) or (put_iv if is_call else call_iv)
        if raw_iv is None:
            continue
        iv = float(raw_iv)
        if iv <= 0 or iv > 3.0:
            continue

        by_dte.setdefault(dte, []).append((K, iv, is_call))

    result: dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]] = {}
    for dte, rows in by_dte.items():
        T = dte / 365.0
        F = spot * math.exp(r * T)
        K_arr       = np.array([r[0] for r in rows])
        iv_arr      = np.array([r[1] for r in rows])
        is_call_arr = np.array([r[2] for r in rows])
        result[dte] = (F, K_arr, iv_arr, is_call_arr)

    return result


# ── Calibration ───────────────────────────────────────────────────────────────

def calibrate_heston(
    surface_points: list[dict],
    spot: float,
    r: float = DEFAULT_R,
    atm_iv: float | None = None,
) -> HestonCalibResult | None:
    """Fit Heston {κ, θ, ξ, ρ, V₀} to a vol-surface snapshot.

    Args:
        surface_points: List of vol surface dicts (same format as
            SabrCalibrator: [{strike, dte, callIv?, putIv?}]).
        spot: Underlying price.
        r: Risk-free rate.
        atm_iv: ATM implied vol (decimal) used to seed V₀ and θ.
            If None it is estimated from the surface itself.

    Returns:
        HestonCalibResult or None if surface is too thin.
    """
    by_dte = _build_quotes(surface_points, spot, r)
    n_total = sum(len(v[1]) for v in by_dte.values())
    if n_total < 8:
        return None

    # ATM vol estimate for initial guess
    if atm_iv is None:
        all_ivs = np.concatenate([v[2] for v in by_dte.values()])
        atm_iv = float(np.median(all_ivs))
    V_atm = atm_iv ** 2

    def _objective(x: np.ndarray) -> float:
        kappa, theta, xi, rho, V0 = x
        # Soft Feller penalty (2κθ ≥ ξ²)
        feller_viol = max(0.0, xi ** 2 - 2 * kappa * theta)
        sse = 100.0 * feller_viol ** 2

        for dte, (F, K_arr, iv_mkt, is_call_arr) in by_dte.items():
            T = dte / 365.0
            try:
                params = HestonParams(kappa, theta, xi, rho, V0)
                prices = heston_price_batch(F, K_arr, T, r, params, is_call_arr)
            except Exception:
                sse += float(len(K_arr))
                continue

            iv_h = _bs_iv_batch(prices, F, K_arr, T, r, is_call_arr)
            nan_mask = np.isnan(iv_h)
            sse += float(np.sum(nan_mask))
            sse += float(np.sum((iv_h[~nan_mask] - iv_mkt[~nan_mask]) ** 2))

        return sse

    bounds = [
        (0.1,   15.0),    # kappa
        (0.005,  0.5),    # theta  (long-run variance)
        (0.01,   2.0),    # xi     (vol-of-vol)
        (-0.99,  0.0),    # rho    (negative for equities)
        (0.005,  0.5),    # V0     (initial variance)
    ]

    x0 = np.array([2.0, V_atm, 0.5, -0.7, V_atm])

    # Global search (differential evolution with Sobol initialisation)
    de_result = differential_evolution(
        _objective,
        bounds,
        maxiter=150,
        tol=1e-5,
        seed=42,
        init="sobol",
        popsize=8,
        workers=1,
        polish=False,
    )

    # Local refinement from the DE solution
    nm_result = minimize(
        _objective,
        de_result.x,
        method="Nelder-Mead",
        options={"maxiter": 1000, "fatol": 1e-9, "xatol": 1e-8},
    )

    kappa, theta, xi, rho, V0 = nm_result.x
    # Clamp to feasible region after optimisation
    kappa = max(0.01, kappa)
    theta = max(1e-4, theta)
    xi    = max(1e-4, xi)
    rho   = max(-0.9999, min(0.9999, rho))
    V0    = max(1e-4, V0)

    params = HestonParams(kappa=kappa, theta=theta, xi=xi, rho=rho, V0=V0)

    # Final RMSE
    sq_errors: list[float] = []
    for dte, (F, K_arr, iv_mkt, is_call_arr) in by_dte.items():
        T = dte / 365.0
        try:
            prices = heston_price_batch(F, K_arr, T, r, params, is_call_arr)
        except Exception:
            continue
        iv_h = _bs_iv_batch(prices, F, K_arr, T, r, is_call_arr)
        valid = ~np.isnan(iv_h)
        sq_errors.extend((iv_h[valid] - iv_mkt[valid]) ** 2)

    rmse = math.sqrt(sum(sq_errors) / len(sq_errors)) if sq_errors else 1.0

    return HestonCalibResult(
        params=params,
        rmse_iv=rmse,
        n_points=n_total,
        converged=bool(nm_result.success),
    )
