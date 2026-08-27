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
#
# THE FOUNDATION EVERYTHING ELSE SITS ON. SABR and Heston both produce a VOL,
# which is then fed back through these formulas to get a price — so a change
# here moves every model in the system.
#
# WHY THE FORWARD FORM (Black-76) RATHER THAN THE SPOT FORM. Working in F
# collapses the carry into a single discount factor, so the same code prices an
# equity option, a future, or an FX option by changing only how F is built.
# Callers pass F = S·e^{rT} and the discount is applied once at the end.
# NO DIVIDEND YIELD: q = 0 throughout, so the forward is overstated for a
# dividend payer — fine for the non-dividend tech names this app tracks.
#
# READING d1 AND d2. Both are "how many standard deviations is the forward above
# the strike", differing only in which measure they are computed under:
#   N(d2) ≈ risk-neutral probability of finishing in the money
#   N(d1)  = the call's delta, and the probability weighted by the payoff
# Their gap, σ√T, is exactly the total vol over the option's life.
#
# TIME IS ACT/365 ON CALENDAR DAYS, and theta and charm are divided by 365 to
# report PER CALENDAR DAY. This must stay consistent with the routers, which
# build T the same way. Realized vol is the deliberate exception at 252 trading
# days, because it is computed from daily returns rather than over calendar time.
#
# UNITS: vega is per 1.00 of vol (i.e. per 100 vol points), NOT per point — the
# raw derivative, unscaled. Divide by 100 for the usual "dollars per vol point".
#
# EVERY FUNCTION GUARDS ON σ√T. When total vol collapses the formulas divide by
# ~0; the guards return intrinsic value (or zero greeks) instead of NaN. That is
# the correct limit, not a fudge: with no volatility left, an option IS its
# intrinsic value.

import math
from dataclasses import dataclass
from scipy.stats import norm as _norm
from scipy.optimize import brentq as _brentq

from core.constants import DEFAULT_R, FV_SIGXT_GUARD


# ── Helpers ───────────────────────────────────────────────────────────────────

def _cdf(x: float) -> float: return float(_norm.cdf(x))  # noqa: E302
def _pdf(x: float) -> float: return float(_norm.pdf(x))  # noqa: E302


def _d1d2(F: float, K: float, T: float, sigma: float) -> tuple[float, float]:
    """The two standardized moneyness terms. See the header for how to read them.

    UNGUARDED — callers must check σ√T themselves before calling, which every
    function below does. Kept bare so the hot paths pay no redundant checks.

    Note the forward form has +0.5σ²T in d1 with no drift term: the drift is
    already inside F.
    """
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
    # Zero-vol limit: the option is worth its DISCOUNTED intrinsic value. Note
    # the intrinsic is computed against the FORWARD, not spot, then discounted —
    # which is the correct forward-measure limit.
    if sig_sqt < FV_SIGXT_GUARD:
        return df * max(F - K, 0) if is_call else df * max(K - F, 0)
    d1, d2 = _d1d2(F, K, T, sigma)
    if is_call:
        return df * (F * _cdf(d1) - K * _cdf(d2))
    return df * (K * _cdf(-d2) - F * _cdf(-d1))


# ── First-order Greeks ────────────────────────────────────────────────────────

def bs_delta(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂V/∂S — directional sensitivity, and roughly the payoff-weighted
    probability of finishing in the money.

    Calls run 0..1, puts −1..0. The zero-vol limit is a step function: fully
    in-the-money options have |delta| 1, everything else 0 — correct, since with
    no vol left there is no chance of crossing the strike.

    Strictly this is ∂V/∂F (forward delta); spot delta differs by the discount
    factor. The distinction is immaterial at the rates and tenors used here, and
    matching the Dart original was the priority.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD:
        return (1.0 if F > K else 0.0) if is_call else (-1.0 if F < K else 0.0)
    d1, _ = _d1d2(F, K, T, sigma)
    return _cdf(d1) if is_call else (_cdf(d1) - 1.0)


def bs_gamma(F: float, K: float, T: float, r: float, sigma: float) -> float:
    """∂²V/∂S² — convexity (same for calls and puts).

    How fast delta changes as spot moves — the value of being long options, and
    the quantity dealer-positioning analytics (GEX) aggregate across a chain.

    Identical for calls and puts by put-call parity: their prices differ by a
    term linear in F, which twice-differentiates to zero.

    Peaks at the money and collapses toward both wings, which is why near-dated
    at-the-money strikes dominate any gamma total.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, _ = _d1d2(F, K, T, sigma)
    # S = F·e^{-rT}, so φ(d1)/(S·σ·√T) = φ(d1)/(F·df·sig_sqt)
    df = math.exp(-r * T)
    return _pdf(d1) / (F * df * sig_sqt)


def bs_vega(F: float, K: float, T: float, r: float, sigma: float) -> float:
    """∂V/∂σ — sensitivity to 1 unit move in vol (same for calls and puts).

    PER 1.00 OF VOL, i.e. per 100 vol points — divide by 100 for the usual
    "dollars per vol point" reading.

    Same for calls and puts, again by parity. Scales with √T, so longer-dated
    options carry far more vol exposure — the reason a vol view is expressed in
    LEAPS and a direction view in weeklies.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, _ = _d1d2(F, K, T, sigma)
    df = math.exp(-r * T)
    return F * df * _pdf(d1) * sqrt_T


def bs_theta(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂V/∂t — time decay per calendar day (negative for long options).

    Two components: the vol-decay term (always negative for a long option — the
    remaining optionality shrinking) and an interest term on the strike, which
    is negative for calls and POSITIVE for puts. Deep in-the-money European puts
    can therefore have positive theta, since exercise proceeds are being
    discounted for less time.

    Divided by 365 to report per CALENDAR day, matching the ACT/365 convention.
    Note real decay ACCELERATES into expiry, so today's theta extrapolated
    linearly understates total remaining decay — see the caveat on
    total_theta_drag in routers/decision.py.
    """
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
    """∂V/∂r — sensitivity to interest rate change.

    Positive for calls, negative for puts. The smallest of the first-order
    Greeks at short tenors — scales with T, so it barely matters on a weekly and
    is meaningful on a LEAP.
    """
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
    """∂²V/∂S∂σ — Vanna = -φ(d₁)·d₂/σ  (matches fair_value_engine.dart exactly).

    How DELTA moves when vol moves (equivalently, how vega moves when spot
    moves). The mechanism behind vol-crush rallies: as IV collapses after an
    event, dealers' aggregate delta shifts and they must trade spot to re-hedge,
    moving price without any news.

    Sign flips across the money (via d₂), so vanna is zero near ATM and largest
    in the wings — which is why a skewed book carries vanna risk that an ATM
    position does not.

    The `is_call` parameter is accepted and IGNORED: vanna is identical for calls
    and puts by parity. Kept for signature symmetry with the other Greeks.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    return -_pdf(d1) * d2 / sigma


def bs_charm(F: float, K: float, T: float, r: float, sigma: float, is_call: bool) -> float:
    """∂Δ/∂t — Charm, delta decay per CALENDAR DAY (same for calls and puts, q=0).

    Annual formula: -φ(d₁) * (2r·T - d₂·σ·√T) / (2·T·σ·√T), divided by 365.

    How delta drifts purely from TIME PASSING, with spot and vol unchanged. This
    is why pinning strengthens into a Friday expiry: dealers' deltas move on
    their own as the clock runs, forcing re-hedging that pushes price toward the
    strike with the most open interest.

    Same for calls and puts because q = 0 here. Grows sharply as T → 0, so it is
    a near-expiry phenomenon and negligible on longer-dated positions.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return 0.0
    d1, d2 = _d1d2(F, K, T, sigma)
    return -_pdf(d1) * (2 * r * T - d2 * sigma * sqrt_T) / (2 * T * sigma * sqrt_T) / 365


def bs_vomma(F: float, K: float, T: float, r: float, sigma: float, is_call: bool = True) -> float:
    """∂²V/∂σ² — Vomma/Volga = vega·d₁·d₂/σ  (matches _bsVomma in fair_value_engine.dart).

    Convexity in VOL: how vega itself changes as vol moves. Positive in both
    wings and near zero at the money (d₁·d₂ changes sign there), so out-of-the-
    money options gain vega as vol rises — they benefit disproportionately from a
    vol spike. That asymmetry is what makes wing options the instrument for a
    vol-of-vol view, and it is the empirical analogue of SABR's ν.

    `is_call` accepted and ignored, as with vanna.
    """
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

    THE INVERSE PROBLEM. There is no closed form for σ given a price, so this
    runs Newton-Raphson using vega as the derivative — a natural choice, since
    vega IS ∂price/∂σ, and convergence is quadratic near the solution.

    The bounds check comes FIRST and is not merely defensive: a price at or
    below intrinsic, or at or above the discounted forward, has NO real implied
    vol. Returning None there is the honest answer, and it is why the router
    reports 422 (a statement about the input) rather than 500.

    TWO-STAGE SOLVER. Newton is fast but fails where vega collapses — deep ITM or
    OTM, where price is nearly insensitive to vol and the derivative is
    near-zero. On that path the loop breaks and falls through to bracketed
    brentq over [1e-6, 20.0], which cannot fail to converge because the bounds
    check already proved a root exists inside the interval.

    Note the for/else: `else` runs only if the loop completed WITHOUT break, i.e.
    max_iter was exhausted without converging, and returns None immediately. So
    brentq is reached only via the explicit `break` when vega collapsed — an
    honest divergence gets the fallback, plain non-convergence does not.
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
        # Vega collapsed — Newton's step would explode. Break out to the brentq
        # fallback rather than dividing by a near-zero derivative.
        if vega < 1e-10:
            break
        diff = price - market_price
        if abs(diff) < tol:
            return sigma
        # Newton step. Clamped to stay positive: a large overshoot can drive
        # sigma negative, where bs_price is undefined, so it is reset just above
        # zero and the iteration continues from there.
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


# Computing the Greeks one at a time would re-derive d1/d2 and re-evaluate the
# normal pdf/cdf for each — this shares all of it in a single pass, which matters
# because the calibrators call it across thousands of strikes per fit.
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

    # Zero-vol limit: delta becomes a step function and every other Greek is
    # zero — with no vol and no time left, nothing is sensitive to anything.
    if sig_sqt < FV_SIGXT_GUARD or T < 1e-8:
        return GreeksResult(
            delta=(1.0 if F > K else 0.0) if is_call else (-1.0 if F < K else 0.0),
            gamma=0.0, theta=0.0, vega=0.0, rho=0.0,
            vanna=0.0, charm=0.0, vomma=0.0,
        )

    # Evaluated once and reused by every Greek below — the point of this
    # function. The normal pdf/cdf calls are the expensive part.
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

    # Charm = -φ(d1) * (2rT - d2*σ*√T) / (2T*σ*√T), per calendar day
    charm = -phi_d1 * (2 * r * T - d2 * sigma * sqrt_T) / (2 * T * sigma * sqrt_T) / 365

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
