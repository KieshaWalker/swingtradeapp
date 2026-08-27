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
# ⚠️ THE FORMULA BELOW IS SUPERSEDED. This block describes a single lag-ratio
# estimator b = γ₂/γ₁, but the implementation now fits ln(γ_k) against k across
# MANY lags by least squares (see the multi-lag regression in
# estimate_from_closes). The reasoning about measurement error is unchanged and
# still correct — only the estimator was upgraded, for stability. Trust the code.
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
#
# THE P/Q DISTINCTION IS THE POINT OF THIS MODULE. The same five Heston
# parameters can be obtained two entirely different ways:
#   P-measure (here)  from the stock's REALIZED price history — what volatility
#                     actually DID.
#   Q-measure         from today's OPTION PRICES (services/heston_calibrator.py)
#                     — what the market CHARGES for it.
#
# They differ SYSTEMATICALLY, not randomly: options embed a variance risk
# premium, so calibrated κ and ξ come out larger. That gap IS the premium, and
# /heston/estimate-params returns both precisely so it stays visible rather than
# being accidentally conflated. NEVER feed a P-measure estimate into a pricer —
# pricing must reproduce market prices, which only Q-measure parameters do.
#
# WHY THE MEASUREMENT-ERROR CORRECTION MATTERS SO MUCH. Realized variance is a
# NOISY OBSERVATION of a latent process: w_t = v_t + ε_t. Regressing w on its own
# lag attenuates the slope toward zero — the classic errors-in-variables bias —
# and since κ = −ln(b)/Δt, an attenuated b inflates κ enormously. Simulation put
# a true κ of 3 at κ̂ ≈ 40 under naive OLS. The autocovariance approach sidesteps
# it entirely: ε is serially uncorrelated, so autocovariances at lags ≥ 1 are
# noise-free.
#
# IT REFUSES RATHER THAN GUESSES. Four separate gates raise EstimationError with
# a human-readable reason — too few blocks, flat variance, insignificant lag-1
# autocorrelation, non-decaying autocovariances. A name whose vol shows no mean
# reversion over the window HAS no meaningful κ, and inventing one would be worse
# than refusing. The router surfaces these as 422.

import math
from dataclasses import dataclass

# Minimum non-overlapping variance blocks for a meaningful AR(1) fit
# Floor on non-overlapping blocks. At the 5-day default that is 200 trading
# days — roughly a year — and it is what makes the autocovariance decay
# estimable at all.
MIN_BLOCKS = 40
# RV is built from daily RETURNS, so it annualizes over TRADING days. The option
# pricers use ACT/365 calendar days because they price over calendar time. The
# two conventions coexist deliberately; swapping them rescales vol by ~1.2x.
TRADING_DAYS_YEAR = 252
# ~1 trading month for the v0 (current variance) estimate. Short enough to
# reflect the present regime, long enough not to be a single-day artefact.
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

    END-ALIGNMENT MATTERS: the most recent observations are the ones the current
    regime is inferred from, so a partial block is discarded from the START
    rather than the end.

    NON-OVERLAPPING IS NON-NEGOTIABLE — see the module header. Consecutive
    rolling windows share most of their returns, which manufactures
    autocorrelation and collapses the κ estimate toward zero.
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
    """Sample autocovariance at the given lag (mean over n − lag pairs).

    THE WHOLE ESTIMATOR RESTS ON ONE PROPERTY: because the RV measurement error
    ε is serially uncorrelated, it contributes to the variance (lag 0) but NOT to
    any autocovariance at lag >= 1. So every γ_k with k >= 1 is a clean view of
    the latent variance process, uncontaminated by observation noise.

    Divides by (n − lag), so each lag averages over however many pairs exist —
    higher lags therefore rest on fewer observations and are noisier, which is
    why the regression below caps how far out it goes.
    """
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

    # γ₀ is the plain variance of the block series — the only autocovariance
    # that DOES contain measurement noise. Used solely to normalise ρ₁ below.
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
    # Lag range is adaptive: at least 3 (below which a slope is meaningless),
    # at most 10, and otherwise a tenth of the sample so higher lags always rest
    # on enough pairs to be informative.
    max_lag = max(3, min(10, len(w) // 10))
    # Starts at k=1, skipping γ₀ — the one contaminated lag.
    # NEGATIVE autocovariances are skipped rather than clamped: log is undefined
    # for them, and at higher lags a negative value is sampling noise around
    # zero, i.e. no remaining persistence to measure.
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
    # Least-squares fit of ln(γ_k) = ln(C) + k·ln(b). Written out longhand
    # rather than via numpy — a handful of points, and it keeps the module
    # dependency-free.
    #
    # Fitting the DECAY RATE across many lags is far more stable than any single
    # lag ratio, because each individual γ_k carries sampling noise that the
    # regression averages out.
    n_pts = len(pts)
    mk = sum(k for k, _ in pts) / n_pts
    mg = sum(g for _, g in pts) / n_pts
    skk = sum((k - mk) ** 2 for k, _ in pts)
    skg = sum((k - mk) * (g - mg) for k, g in pts)
    slope = skg / skk
    log_c = mg - slope * mk

    # A non-negative slope means autocovariance is NOT decaying with lag, i.e.
    # the variance process is trending or has a unit root — there is no mean
    # reversion to measure, and κ = −ln(b)/Δt would be zero or negative.
    if slope >= 0:
        raise EstimationError(
            "Autocovariances do not decay with lag — variance shows no mean "
            "reversion over this lookback (trending or unit-root vol)."
        )
    # b is the per-block persistence, in (0,1) for a decaying process.
    b = math.exp(slope)

    # Δt in YEARS, so κ comes out annualized and directly comparable to the
    # calibrated Q-measure κ.
    dt = block_days / TRADING_DAYS_YEAR
    kappa = -math.log(b) / dt

    # θ is simply the mean realized variance — UNBIASED, because the measurement
    # error ε is zero-mean and averages out. The one parameter here needing no
    # correction.
    theta = sum(w) / len(w)
    if theta <= 0:
        raise EstimationError("Mean realized variance is ≤ 0 — bad data.")

    # ξ from the CIR stationary variance: var(v) = ξ²θ/(2κ).
    # The fitted intercept C = var(v)·h² where h = (1−b)/(κΔt) is the
    # within-block averaging attenuation, so var(v) = C/h².
    # h undoes the WITHIN-BLOCK AVERAGING attenuation: each block RV is an
    # average of the latent variance over its window, not a point sample, which
    # shrinks its variance by h². Recovering var(v) requires dividing it back out.
    h = (1.0 - b) / (kappa * dt)
    var_v = math.exp(log_c) / (h * h)
    # CIR stationary relation var(v) = ξ²θ/(2κ), inverted for ξ. So ξ is not
    # fitted directly — it is implied by the other three, which is why an error
    # in κ or θ propagates straight into it.
    xi = math.sqrt(2.0 * kappa * var_v / theta)

    # Raw lag-1 r² of the block series — a signal-to-noise diagnostic
    # (deliberately NOT used for b; OLS slope is attenuated by RV noise).
    r2 = rho1 * rho1

    # v₀ from the most recent ~1 month of daily returns
    # v0 is measured from RAW DAILY returns over the last month, NOT from the
    # block series — the current state should reflect the most recent data at
    # full resolution rather than being smoothed into a 5-day block.
    #
    # Note this is a zero-mean estimator with no Bessel correction, consistent
    # with the block variance above and with services/realized_vol.py's
    # convention.
    tail = rets[-V0_WINDOW_DAYS:]
    v0 = sum(r * r for r in tail) * (TRADING_DAYS_YEAR / len(tail))

    # The intuitive reading of κ: how long a vol shock takes to half-decay.
    # Reported in CALENDAR days (x365) even though κ is estimated on a trading-day
    # clock — the more natural unit for a human.
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
