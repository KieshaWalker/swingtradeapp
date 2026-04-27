from __future__ import annotations

# =============================================================================
# services/heston.py
# =============================================================================
# Heston (1993) stochastic-volatility option pricer.
#
# Model:
#   dS/S  = r dt + √V dW₁
#   dV    = κ(θ − V) dt + ξ√V dW₂       Corr(dW₁, dW₂) = ρ
#
# Pricing via Gil-Pelaez Fourier inversion of the characteristic function:
#   C = e^{−rT}(F·P₁ − K·P₂)
#   Pⱼ = ½ + (1/π) ∫₀^∞ Re[e^{−iuk} φⱼ(u) / (iu)] du
#
# Characteristic function uses the Albrecher et al. (2007) stable
# parameterisation that avoids the complex-sqrt branch-cut discontinuity
# present in the original Heston (1993) paper.
#
# Two pricers are provided:
#   heston_price()      — scipy.integrate.quad (accurate, ~5 ms/option)
#   heston_price_fast() — 100-pt Gauss-Laguerre (≈0.1 ms, for calibration)
# =============================================================================

import cmath
import math
from dataclasses import dataclass

import numpy as np
from scipy.integrate import quad
from scipy.special import roots_laguerre


# ── Parameters ────────────────────────────────────────────────────────────────

@dataclass
class HestonParams:
    kappa: float   # mean-reversion speed κ > 0
    theta: float   # long-run variance θ > 0  (long-run vol = √θ)
    xi: float      # vol-of-vol ξ > 0
    rho: float     # spot-vol correlation ρ ∈ (−1, 1)
    V0: float      # initial variance V₀ > 0  (initial vol = √V₀)

    def __post_init__(self) -> None:
        if self.kappa <= 0:
            raise ValueError(f"kappa must be > 0, got {self.kappa}")
        if self.theta <= 0:
            raise ValueError(f"theta must be > 0, got {self.theta}")
        if self.xi <= 0:
            raise ValueError(f"xi must be > 0, got {self.xi}")
        if not (-1 < self.rho < 1):
            raise ValueError(f"rho must be in (−1, 1), got {self.rho}")
        if self.V0 <= 0:
            raise ValueError(f"V0 must be > 0, got {self.V0}")

    @property
    def feller_satisfied(self) -> bool:
        """2κθ ≥ ξ² ensures variance stays strictly positive a.s."""
        return 2 * self.kappa * self.theta >= self.xi ** 2


# ── Gauss-Laguerre quadrature nodes (cached at module load) ───────────────────

_N_GL = 100
_u_gl, _w_gl = roots_laguerre(_N_GL)
_w_gl_exp = _w_gl * np.exp(_u_gl)   # absorb e^u factor for ∫₀^∞ f(u) du


# ── Characteristic function ───────────────────────────────────────────────────

def _cf_scalar(u: complex, T: float, kappa: float, theta: float,
               xi: float, rho: float, V0: float) -> complex:
    """Heston CF of ln(S_T/F) at a single complex u.

    Returns φ̃(u) = E_Q[exp(iu · ln(S_T/F))] using the Albrecher stable form.
    For real u the argument of sqrt always has positive real part, so the
    principal branch never crosses the negative real axis.
    """
    xi2 = xi * xi
    a = kappa - rho * xi * 1j * u
    d = cmath.sqrt(a ** 2 + xi2 * (u ** 2 + 1j * u))

    exp_dT = cmath.exp(-d * T)
    # h = (a+d)(1 − g·exp(−dT))  avoids explicit g = (a−d)/(a+d)
    h = (a + d) - (a - d) * exp_dT

    C = kappa * theta / xi2 * ((a - d) * T - 2 * cmath.log(h / (2 * d)))
    # D simplifies using (a−d)(a+d) = a²−d² = −ξ²(u²+iu)
    D = -(u ** 2 + 1j * u) * (1 - exp_dT) / h

    return cmath.exp(C + D * V0)


def _cf_vec(u_arr: np.ndarray, T: float, kappa: float, theta: float,
            xi: float, rho: float, V0: float) -> np.ndarray:
    """Vectorised Heston CF over an array of (possibly complex) u values."""
    u = u_arr.astype(complex)
    xi2 = xi * xi
    a = kappa - rho * xi * 1j * u
    d = np.sqrt(a ** 2 + xi2 * (u ** 2 + 1j * u))

    exp_dT = np.exp(-d * T)
    h = (a + d) - (a - d) * exp_dT

    C = kappa * theta / xi2 * ((a - d) * T - 2 * np.log(h / (2 * d)))
    D = -(u ** 2 + 1j * u) * (1 - exp_dT) / h

    return np.exp(C + D * V0)


# ── Accurate pricer (scipy.integrate.quad) ────────────────────────────────────

def heston_price(F: float, K: float, T: float, r: float,
                 params: HestonParams, is_call: bool) -> float:
    """European option price under Heston (1993).

    Uses adaptive Gauss-Kronrod quadrature (scipy.integrate.quad).
    Accurate to ~1e-6; typical runtime ~5 ms per option.
    """
    kappa, theta, xi, rho, V0 = (
        params.kappa, params.theta, params.xi, params.rho, params.V0
    )
    df = math.exp(-r * T)
    k = math.log(K / F)   # log-moneyness (≤ 0 for ITM calls)

    def _p2_integrand(u: float) -> float:
        cf = _cf_scalar(u, T, kappa, theta, xi, rho, V0)
        return (cmath.exp(-1j * u * k) * cf / (1j * u)).real

    def _p1_integrand(u: float) -> float:
        # CF evaluated at u − i  (change to stock measure)
        cf = _cf_scalar(u - 1j, T, kappa, theta, xi, rho, V0)
        return (cmath.exp(-1j * u * k) * cf / (1j * u)).real

    I1, _ = quad(_p1_integrand, 1e-6, 500.0, limit=500, epsabs=1e-8, epsrel=1e-6)
    I2, _ = quad(_p2_integrand, 1e-6, 500.0, limit=500, epsabs=1e-8, epsrel=1e-6)

    P1 = 0.5 + I1 / math.pi
    P2 = 0.5 + I2 / math.pi

    call = max(0.0, df * (F * P1 - K * P2))
    if is_call:
        return call
    # put via parity
    return max(0.0, call - df * (F - K))


# ── Fast pricer (Gauss-Laguerre, for calibration) ─────────────────────────────

def heston_price_fast(F: float, K: float, T: float, r: float,
                      params: HestonParams, is_call: bool) -> float:
    """Heston price via 100-pt Gauss-Laguerre quadrature.

    ~50× faster than the quad version; accuracy ~1e-4 in price.
    Use for calibration; use heston_price() for final production prices.
    """
    kappa, theta, xi, rho, V0 = (
        params.kappa, params.theta, params.xi, params.rho, params.V0
    )
    df = math.exp(-r * T)
    k = math.log(K / F)

    cf2 = _cf_vec(_u_gl.astype(complex), T, kappa, theta, xi, rho, V0)
    cf1 = _cf_vec(_u_gl.astype(complex) - 1j, T, kappa, theta, xi, rho, V0)

    u = _u_gl
    I2 = np.sum(_w_gl_exp * np.real(np.exp(-1j * u * k) * cf2 / (1j * u)))
    I1 = np.sum(_w_gl_exp * np.real(np.exp(-1j * u * k) * cf1 / (1j * u)))

    P1 = 0.5 + float(I1) / math.pi
    P2 = 0.5 + float(I2) / math.pi

    call = max(0.0, df * (F * P1 - K * P2))
    if is_call:
        return call
    return max(0.0, call - df * (F - K))


def heston_price_batch(
    F: float,
    K_arr: np.ndarray,
    T: float,
    r: float,
    params: HestonParams,
    is_call_arr: np.ndarray,
) -> np.ndarray:
    """Price a batch of options at the same T but different strikes.

    The CF is computed once for this T, then all K are priced via matrix ops.
    Typical cost: O(N_GL) complex ops + O(M × N_GL) real multiplies,
    where M = number of strikes and N_GL = 100.

    Returns array of prices (shape M).
    """
    kappa, theta, xi, rho, V0 = (
        params.kappa, params.theta, params.xi, params.rho, params.V0
    )
    df = math.exp(-r * T)

    cf2 = _cf_vec(_u_gl.astype(complex), T, kappa, theta, xi, rho, V0)       # (N,)
    cf1 = _cf_vec(_u_gl.astype(complex) - 1j, T, kappa, theta, xi, rho, V0)  # (N,)

    k_col = np.log(K_arr / F)[:, None]       # (M, 1)
    u_row = _u_gl[None, :]                   # (1, N)
    w_row = _w_gl_exp[None, :]               # (1, N)

    phase = np.exp(-1j * u_row * k_col)      # (M, N)
    iu = 1j * u_row                          # (1, N)

    I2 = np.sum(w_row * np.real(phase * cf2[None, :] / iu), axis=1)  # (M,)
    I1 = np.sum(w_row * np.real(phase * cf1[None, :] / iu), axis=1)  # (M,)

    P1 = 0.5 + I1 / math.pi   # (M,)
    P2 = 0.5 + I2 / math.pi   # (M,)

    calls = np.maximum(0.0, df * (F * P1 - K_arr * P2))          # (M,)
    puts  = np.maximum(0.0, calls - df * (F - K_arr))             # (M,)

    return np.where(is_call_arr, calls, puts)


# ── Deprecated first-order correction (kept for backward compat) ──────────────

def heston_correction(
    T: float,
    vanna: float,
    vomma: float,
    kappa: float = 2.0,
    xi: float = 0.50,
    rho_h: float = -0.70,
) -> float:
    """DEPRECATED — first-order Hull-White stochastic-vol correction.

    Retained as a fallback when no calibrated HestonParams are available.
    Replace with heston_price() where possible.
    """
    k = kappa
    a = rho_h * xi * vanna * (1 - math.exp(-k * T)) / k
    b = (xi * xi / 2) * vomma * (1 - math.exp(-2 * k * T)) / (2 * k)
    return a + b
