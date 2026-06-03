from __future__ import annotations
from typing import Optional

# =============================================================================
# services/black_scholes.py
# =============================================================================
# Black-Scholes pricing and Greeks — exact port of fair_value_engine.dart.
#
# Key difference from Dart: uses scipy.stats.norm (machine precision) instead
# of the Abramowitz & Stegun approximation (max error ~1.5e-7). Numerical
# output difference is < 1e-6 for all practical inputs — below bid-ask noise.
#
# All functions use the FORWARD price form:
#   F = S * exp(r * T)
#   d1 = (ln(F/K) + 0.5*σ²*T) / (σ*√T)
#   d2 = d1 - σ*√T
#   Call = exp(-r*T) * (F*N(d1) - K*N(d2))
#   Put  = exp(-r*T) * (K*N(-d2) - F*N(-d1))
# =============================================================================

import math
from dataclasses import dataclass
from scipy.stats import norm as _norm
from scipy.optimize import brentq as _brentq

from core.constants import DEFAULT_R, FV_SIGXT_GUARD


# ── Helpers ───────────────────────────────────────────────────────────────────

def _cdf(x: float) -> float: return float(_norm.cdf(x))  # noqa: E302
def _pdf(x: float) -> float: return float(_norm.pdf(x))  # noqa: E302


def _d1d2(F: float, K: float, T: float, sigma: float) -> tuple[float, float]:
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sig_sqt
    d2 = d1 - sig_sqt
    return d1, d2


# ── Pricing ───────────────────────────────────────────────────────────────────

def bs_price(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """Black-Scholes option price using forward price F = S*exp(r*T)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    df = math.exp(-r * T)
    if sig_sqt < FV_SIGXT_GUARD:
        return df * max(F - K, 0) if is_call else df * max(K - F, 0)
    d1, d2 = _d1d2(F, K, T, sigma)
    if is_call:
        return df * (F * _cdf(d1) - K * _cdf(d2))
    return df * (K * _cdf(-d2) - F * _cdf(-d1))


# ── First-order Greeks ────────────────────────────────────────────────────────

def bs_delta(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂V/∂S — directional sensitivity."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD:
        return (1.0 if F > K else 0.0) if is_call else (-1.0 if F < K else 0.0)
    d1, _ = _d1d2(F, K, T, sigma)
    return _cdf(d1) if is_call else (_cdf(d1) - 1.0)


def bs_gamma(F: float, K: float, T: float, r: float, sigma: float) -> float:
    """∂²V/∂S² — convexity (same for calls and puts)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, _ = _d1d2(F, K, T, sigma)
    # S = F·e^{-rT}, so φ(d1)/(S·σ·√T) = φ(d1)/(F·df·sig_sqt)
    df = math.exp(-r * T)
    return _pdf(d1) / (F * df * sig_sqt)


def bs_vega(F: float, K: float, T: float, r: float, sigma: float) -> float:
    """∂V/∂σ — sensitivity to 1 unit move in vol (same for calls and puts)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, _ = _d1d2(F, K, T, sigma)
    df = math.exp(-r * T)
    return F * df * _pdf(d1) * sqrt_T


def bs_theta(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂V/∂t — time decay per calendar day (negative for long options)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    df = math.exp(-r * T)
    phi_d1 = _pdf(d1)
    decay = -F * df * phi_d1 * sigma / (2 * sqrt_T)
    if is_call:
        return (decay - r * K * df * _cdf(d2)) / 365
    return (decay + r * K * df * _cdf(-d2)) / 365


def bs_rho(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂V/∂r — sensitivity to interest rate change."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    df = math.exp(-r * T)
    if is_call:
        return K * T * df * _cdf(d2)
    return -K * T * df * _cdf(-d2)


# ── Second-order Greeks ───────────────────────────────────────────────────────

def bs_vanna(F: float, K: float, T: float, sigma: float, is_call: bool = True) -> float:
    """∂²V/∂S∂σ — Vanna = -φ(d₁)·d₂/σ  (matches fair_value_engine.dart exactly)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    return -_pdf(d1) * d2 / sigma


def bs_charm(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂Δ/∂t — Charm (matches _bsCharm in fair_value_engine.dart exactly).

    Formula: -df * φ(d₁) * (2r·T - d₂·σ·√T) / (2·σ·√T)
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    df = math.exp(-r * T)
    return -df * _pdf(d1) * (2 * r * T - d2 * sigma * sqrt_T) / (2 * sigma * sqrt_T)


def bs_vomma(F: float, K: float, T: float, r: float, sigma: float, is_call: bool = True) -> float:
    """∂²V/∂σ² — Vomma/Volga = vega·d₁·d₂/σ  (matches _bsVomma in fair_value_engine.dart)."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    vega = F * math.exp(-r * T) * _pdf(d1) * sqrt_T
    return vega * d1 * d2 / sigma


# ── Implied vol solver ────────────────────────────────────────────────────────

def bs_implied_vol(
    market_price: float,
    F: float,
    K: float,
    T: float,
    r: float,
    is_call: bool,
    initial_guess: float = 0.25,
    max_iter: int = 100,
    tol: float = 1e-7,
) ->Optional[float]:
    """Newton-Raphson IV solver: find σ such that bs_price(σ) = market_price.

    Returns None when the solver fails to converge or the price is outside
    the no-arbitrage bounds (below intrinsic or above the forward).
    """
    df = math.exp(-r * T)
    intrinsic = df * max(F - K, 0) if is_call else df * max(K - F, 0)
    upper = df * (F if is_call else K)
    if market_price <= intrinsic or market_price >= upper:
        return None

    sigma = initial_guess
    for _ in range(max_iter):
        price = bs_price(F, K, T, r, sigma, is_call)
        vega = bs_vega(F, K, T, r, sigma)
        if vega < 1e-10:
            break
        diff = price - market_price
        if abs(diff) < tol:
            return sigma
        sigma -= diff / vega
        if sigma <= 0:
            sigma = 1e-6
    else:
        return None  # hit max_iter without converging

    # N-R diverged (vega collapsed). Fall back to brentq — guaranteed convergence
    # because bounds check above confirmed price is strictly inside [intrinsic, upper].
    try:
        return _brentq(
            lambda s: bs_price(F, K, T, r, s, is_call) - market_price,
            1e-6, 20.0, xtol=tol, maxiter=200,
        )
    except (ValueError, RuntimeError):
        return None


# ── Convenience bundle ────────────────────────────────────────────────────────

@dataclass
class GreeksResult:
    delta: float
    gamma: float
    theta: float
    vega: float
    rho: float
    vanna: float
    charm: float
    vomma: float


def bs_all_greeks(
    F: float,
    K: float,
    T: float,
    r: float,
    sigma: float,
    is_call: bool,
) -> GreeksResult:
    """Compute all first- and second-order Greeks in one pass."""
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    df = math.exp(-r * T)

    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return GreeksResult(
            delta=(1.0 if F > K else 0.0) if is_call else (-1.0 if F < K else 0.0),
            gamma=0.0, theta=0.0, vega=0.0, rho=0.0,
            vanna=0.0, charm=0.0, vomma=0.0,
        )

    d1, d2 = _d1d2(F, K, T, sigma)
    phi_d1 = _pdf(d1)
    cdf_d1 = _cdf(d1)
    cdf_d2 = _cdf(d2)
    cdf_neg_d2 = _cdf(-d2)

    # Delta: spot ∂V/∂S = N(d1) for calls, N(d1)-1 for puts
    delta = cdf_d1 if is_call else (cdf_d1 - 1.0)

    # Gamma: spot ∂²V/∂S² = φ(d1)/(S·σ·√T) = φ(d1)/(F·df·sig_sqt)
    gamma = phi_d1 / (F * df * sig_sqt)

    # Vega (same for calls and puts)
    vega = F * df * phi_d1 * sqrt_T

    # Theta
    decay = -F * df * phi_d1 * sigma / (2 * sqrt_T)
    if is_call:
        theta = (decay - r * K * df * cdf_d2) / 365
    else:
        theta = (decay + r * K * df * cdf_neg_d2) / 365

    # Rho
    rho = K * T * df * cdf_d2 if is_call else -K * T * df * cdf_neg_d2

    # Vanna = -φ(d1)*d2/σ
    vanna = -phi_d1 * d2 / sigma

    # Charm = -df * φ(d1) * (2rT - d2*σ*√T) / (2σ*√T)
    charm = -df * phi_d1 * (2 * r * T - d2 * sigma * sqrt_T) / (2 * sigma * sqrt_T)

    # Vomma = vega * d1 * d2 / σ
    vomma = vega * d1 * d2 / sigma

    return GreeksResult(
        delta=delta,
        gamma=gamma,
        theta=theta,
        vega=vega,
        rho=rho,
        vanna=vanna,
        charm=charm,
        vomma=vomma,
    )
