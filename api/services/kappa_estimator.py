from __future__ import annotations
from typing import Optional

# =============================================================================
# services/kappa_estimator.py
# =============================================================================
# Historical (P-measure) Heston parameter estimation from daily closes.
#
# Implements the recipe described in the calculator's "Estimating Kappa" info
# dialog: fit AR(1) to a realized-variance series, then κ = −ln(b)/Δt.
#
# Realized variance is built from NON-OVERLAPPING blocks of daily log returns
# (default 5 trading days). Rolling windows must not be used here: consecutive
# rolling RVs share most of their returns, which inflates the AR(1)
# coefficient and badly underestimates κ.
#
# CRITICAL: naive OLS of w_t on w_{t-1} is NOT used for b. Block RV is a noisy
# measurement of latent variance (w_t = v_t + ε_t), and that measurement error
# attenuates the OLS slope toward zero, inflating κ by an order of magnitude
# (verified by simulation: true κ=3 came back as κ̂≈40 via OLS). Because ε_t is
# serially uncorrelated, autocovariances of w at lags ≥ 1 are noise-free and
#   b = γ₂ / γ₁          (lag-ratio estimator, robust to measurement error;
#                          block time-averaging also cancels in the ratio)
#
# Derived seeds for the other Heston inputs:
#   θ      = mean(w)                       (unbiased)
#   var(v) = γ₁ / (b·h²),  h = (1−b)/(κΔt) (undo lag-1 + averaging attenuation)
#   ξ      = √(2κ·var(v)/θ)                (CIR stationary variance relation)
#   v₀     = annualized variance of the last 21 daily returns
#
# These are physical-measure estimates. Calibrated (risk-neutral) κ and ξ are
# typically larger because options embed variance risk premia — callers should
# present both when a calibration is available.
# =============================================================================

import math
from dataclasses import dataclass

# Minimum non-overlapping variance blocks for a meaningful AR(1) fit
MIN_BLOCKS = 40
TRADING_DAYS_YEAR = 252
V0_WINDOW_DAYS = 21


@dataclass
class KappaEstimate:
    kappa: float
    theta: float            # long-run variance (annualized)
    xi: float                # vol-of-vol
    v0: float                # current variance (annualized)
    ar1_a: float
    ar1_b: float
    ar1_r2: float
    n_blocks: int
    block_days: int
    half_life_days: float    # calendar days, ln(2)/κ × 365

    @property
    def feller_satisfied(self) -> bool:
        return 2 * self.kappa * self.theta >= self.xi ** 2


class EstimationError(ValueError):
    """Raised when the price history cannot support an AR(1) variance fit."""


def _log_returns(closes: list[float]) -> list[float]:
    rets = []
    for i in range(1, len(closes)):
        if closes[i - 1] and closes[i] and closes[i - 1] > 0 and closes[i] > 0:
            rets.append(math.log(closes[i] / closes[i - 1]))
    return rets


def _block_variances(rets: list[float], block_days: int) -> list[float]:
    """Annualized realized variance per non-overlapping block, oldest first.

    Blocks are aligned to the END of the series so the most recent data is
    always fully used; a partial block at the start is dropped.
    """
    n_blocks = len(rets) // block_days
    if n_blocks == 0:
        return []
    start = len(rets) - n_blocks * block_days
    out = []
    for i in range(n_blocks):
        block = rets[start + i * block_days: start + (i + 1) * block_days]
        rv2 = sum(r * r for r in block) * (TRADING_DAYS_YEAR / block_days)
        out.append(rv2)
    return out


def _autocov(series: list[float], lag: int) -> float:
    """Sample autocovariance at the given lag (mean over n − lag pairs)."""
    n = len(series)
    m = sum(series) / n
    return sum(
        (series[i] - m) * (series[i + lag] - m) for i in range(n - lag)
    ) / (n - lag)


def estimate_from_closes(
    closes: list[float],
    block_days: int = 5,
) -> KappaEstimate:
    """Estimate Heston (κ, θ, ξ, v₀) from daily closes, oldest first.

    Raises EstimationError with a human-readable reason when the data cannot
    support the fit (too short, flat, or no detectable mean reversion).
    """
    rets = _log_returns(closes)
    w = _block_variances(rets, block_days)
    if len(w) < MIN_BLOCKS:
        raise EstimationError(
            f"Need at least {MIN_BLOCKS} non-overlapping {block_days}-day "
            f"variance blocks ({MIN_BLOCKS * block_days} trading days); "
            f"got {len(w)}."
        )

    gamma0 = _autocov(w, 0)
    if gamma0 < 1e-18:
        raise EstimationError(
            "Variance series is flat — cannot fit mean reversion."
        )

    # Significance gate: under white noise rho1_hat ~ N(0, 1/n). Without this,
    # constant-vol series (no vol dynamics at all) can still produce a
    # plausible-looking kappa from pure noise in the autocovariances.
    gamma1 = _autocov(w, 1)
    rho1 = gamma1 / gamma0
    if rho1 < 2.0 / math.sqrt(len(w)):
        raise EstimationError(
            f"Lag-1 autocorrelation of realized variance ({rho1:.3f}) is not "
            f"statistically significant for {len(w)} blocks — no detectable "
            "vol mean reversion. Try a longer lookback."
        )

    # Autocovariances at lags ≥ 1 are free of RV measurement noise and decay
    # as γ_k = C·b^k. Fit ln(γ_k) = ln(C) + k·ln(b) across many lags — far
    # more stable than any single lag ratio on noisy series.
    max_lag = max(3, min(10, len(w) // 10))
    pts = []
    for k in range(1, max_lag + 1):
        g = _autocov(w, k)
        if g > 0:
            pts.append((float(k), math.log(g)))
    if len(pts) < 3:
        raise EstimationError(
            "Too few positive autocovariance lags — variance shows no "
            "usable persistence; try a longer lookback or larger blocks."
        )
    n_pts = len(pts)
    mk = sum(k for k, _ in pts) / n_pts
    mg = sum(g for _, g in pts) / n_pts
    skk = sum((k - mk) ** 2 for k, _ in pts)
    skg = sum((k - mk) * (g - mg) for k, g in pts)
    slope = skg / skk
    log_c = mg - slope * mk

    if slope >= 0:
        raise EstimationError(
            "Autocovariances do not decay with lag — variance shows no mean "
            "reversion over this lookback (trending or unit-root vol)."
        )
    b = math.exp(slope)

    dt = block_days / TRADING_DAYS_YEAR
    kappa = -math.log(b) / dt

    theta = sum(w) / len(w)
    if theta <= 0:
        raise EstimationError("Mean realized variance is ≤ 0 — bad data.")

    # ξ from the CIR stationary variance: var(v) = ξ²θ/(2κ).
    # The fitted intercept C = var(v)·h² where h = (1−b)/(κΔt) is the
    # within-block averaging attenuation, so var(v) = C/h².
    h = (1.0 - b) / (kappa * dt)
    var_v = math.exp(log_c) / (h * h)
    xi = math.sqrt(2.0 * kappa * var_v / theta)

    # Raw lag-1 r² of the block series — a signal-to-noise diagnostic
    # (deliberately NOT used for b; OLS slope is attenuated by RV noise).
    r2 = rho1 * rho1

    # v₀ from the most recent ~1 month of daily returns
    tail = rets[-V0_WINDOW_DAYS:]
    v0 = sum(r * r for r in tail) * (TRADING_DAYS_YEAR / len(tail))

    half_life_days = math.log(2) / kappa * 365

    return KappaEstimate(
        kappa=kappa,
        theta=theta,
        xi=xi,
        v0=v0,
        ar1_a=theta * (1.0 - b),
        ar1_b=b,
        ar1_r2=r2,
        n_blocks=len(w),
        block_days=block_days,
        half_life_days=half_life_days,
    )
