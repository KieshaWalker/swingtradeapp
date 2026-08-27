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
#
# WHY FOURIER INVERSION AT ALL. Under Heston there is no closed-form price, but
# the CHARACTERISTIC FUNCTION of log(S_T) IS known in closed form. Gil-Pelaez
# recovers the probabilities P₁ and P₂ from it by integrating the CF against a
# phase term — trading an unavailable formula for a one-dimensional integral.
#
# The price then has exactly the Black-Scholes SHAPE, C = e^{-rT}(F·P₁ − K·P₂),
# with P₁ and P₂ playing the roles of N(d₁) and N(d₂). Black-Scholes is the
# special case where those probabilities are normal CDFs.
#
# THE BRANCH-CUT PROBLEM, AND WHY THE ALBRECHER FORM MATTERS. The CF involves a
# complex square root. In Heston's original 1993 parameterisation the argument
# of the complex log can wander across the negative real axis for long
# maturities, where the principal branch is DISCONTINUOUS — the CF jumps, the
# integral is wrong, and the resulting price is silently wrong rather than
# obviously broken. The Albrecher et al. (2007) rewrite used below keeps the
# argument in the right half-plane for all real u, so the principal branch is
# always correct. This is the single most important detail in the file.
#
# THREE PRICERS, ONE MODEL — pick by call volume:
#   heston_price()        adaptive quad. ~5 ms. Interactive/production prices.
#   heston_price_fast()   100-pt Gauss-Laguerre. ~0.1 ms. Inner calibration loop.
#   heston_price_batch()  vectorised over strikes at one T. The calibrator's
#                         real workhorse — one CF evaluation serves every strike.
#
# PUTS ARE ALWAYS DERIVED BY PARITY from the call, never integrated separately:
# one numerical result, guaranteed internally consistent.

import cmath
import math
from dataclasses import dataclass

import numpy as np
from scipy.integrate import quad
from scipy.special import roots_laguerre


# ── Parameters ────────────────────────────────────────────────────────────────

@dataclass
class HestonParams:
    """The five Heston parameters, validated on construction.

    ⚠️ theta and V0 are VARIANCES, not vols. theta = 0.09 means a 30% long-run
    vol. Getting this wrong is silent — the price comes back plausible and wrong.

    Validation lives in __post_init__ rather than at the call sites so an
    invalid set cannot exist at all; every pricer below can then assume its
    inputs are sane.
    """
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
        """2κθ ≥ ξ² ensures variance stays strictly positive a.s.

        The Feller condition. When it FAILS the variance process can touch zero,
        which is not fatal — the pricer still returns a number — but it means
        the parameters sit in a corner of the space where the model is less
        well-behaved and the integrand harder to evaluate accurately.

        Reported rather than enforced: real calibrations to equity surfaces
        routinely violate it, because the steep short-dated skew genuinely needs
        a large ξ. Treat a violating fit as usable but suspect.
        """
        return 2 * self.kappa * self.theta >= self.xi ** 2


# ── Gauss-Laguerre quadrature nodes (cached at module load) ───────────────────

# Gauss-Laguerre nodes and weights, computed ONCE at import. Deriving them is
# far more expensive than using them, and the calibrator evaluates against these
# same nodes millions of times per fit.
#
# Gauss-Laguerre is the natural rule here because it integrates over [0, ∞) —
# exactly the Gil-Pelaez domain — with no truncation needed.
_N_GL = 100
_u_gl, _w_gl = roots_laguerre(_N_GL)
# The rule natively computes ∫₀^∞ f(u)·e^{−u} du, but the integrand here has no
# e^{−u} factor. Pre-multiplying the weights by e^{u} cancels it, so the sums
# below can use the raw integrand directly.
_w_gl_exp = _w_gl * np.exp(_u_gl)   # absorb e^u factor for ∫₀^∞ f(u) du


# ── Characteristic function ───────────────────────────────────────────────────

def _cf_scalar(u: complex, T: float, kappa: float, theta: float,
               xi: float, rho: float, V0: float) -> complex:
    """Heston CF of ln(S_T/F) at a single complex u.

    Returns φ̃(u) = E_Q[exp(iu · ln(S_T/F))] using the Albrecher stable form.
    For real u the argument of sqrt always has positive real part, so the
    principal branch never crosses the negative real axis.

    See the module header: this is the Albrecher stable parameterisation, and the
    branch-cut property above is precisely what it buys over Heston's original
    form. Do not "simplify" the h and D expressions back toward the textbook
    version — the algebraic rearrangement IS the fix.

    Returns the CF of ln(S_T/F), i.e. normalised to the forward, which is why no
    drift term appears.
    """
    xi2 = xi * xi
    a = kappa - rho * xi * 1j * u
    d = cmath.sqrt(a ** 2 + xi2 * (u ** 2 + 1j * u))

    # exp(−dT) rather than exp(+dT): d has positive real part, so this DECAYS
    # for large T instead of overflowing. The original formulation's exp(+dT)
    # is what overflows on long maturities.
    exp_dT = cmath.exp(-d * T)
    # h = (a+d)(1 − g·exp(−dT))  avoids explicit g = (a−d)/(a+d)
    # Never forming g explicitly avoids a division by (a+d), which can approach
    # zero and inject a spurious singularity.
    h = (a + d) - (a - d) * exp_dT

    C = kappa * theta / xi2 * ((a - d) * T - 2 * cmath.log(h / (2 * d)))
    # D simplifies using (a−d)(a+d) = a²−d² = −ξ²(u²+iu)
    D = -(u ** 2 + 1j * u) * (1 - exp_dT) / h

    return cmath.exp(C + D * V0)


def _cf_vec(u_arr: np.ndarray, T: float, kappa: float, theta: float,
            xi: float, rho: float, V0: float) -> np.ndarray:
    """Vectorised Heston CF over an array of (possibly complex) u values.

    Line-for-line identical to _cf_scalar with cmath swapped for numpy. Kept as a
    separate function rather than unified because the scalar version is called
    inside scipy.quad's Python-level integrand loop, where numpy's array
    overhead would dominate.

    IF YOU CHANGE THE CF, CHANGE BOTH. A divergence between them would make the
    accurate and fast pricers disagree, which would surface as a calibration that
    fits well but prices badly.
    """
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

    The production pricer, used by /heston/price and by fair_value_engine.
    Adaptive quadrature places its nodes where the integrand actually needs
    them, which is what buys the extra accuracy over the fixed Gauss-Laguerre
    rule below.
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
        # The −i shift IS the measure change. P₂ is the probability of finishing
        # ITM under the risk-neutral measure; P₁ is the same probability under
        # the stock-numeraire measure, and the two differ by exactly this
        # translation of the CF's argument. Same integral, shifted argument.
        cf = _cf_scalar(u - 1j, T, kappa, theta, xi, rho, V0)
        return (cmath.exp(-1j * u * k) * cf / (1j * u)).real

    # Integration bounds are pragmatic, not exact. The true domain is (0, ∞):
    #   lower 1e-3 — the integrand has a removable 1/(iu) singularity at u = 0
    #                that quad cannot evaluate; the omitted sliver is negligible.
    #   upper 500  — the CF decays fast enough that the tail beyond 500 is far
    #                below the 1e-8 tolerance for realistic parameters. Extreme
    #                ξ or very short T slow that decay, which is one reason the
    #                calibrator bounds ξ.
    I1, _ = quad(_p1_integrand, 1e-3, 500.0, limit=500, epsabs=1e-8, epsrel=1e-6)
    I2, _ = quad(_p2_integrand, 1e-3, 500.0, limit=500, epsabs=1e-8, epsrel=1e-6)

    P1 = 0.5 + I1 / math.pi
    P2 = 0.5 + I2 / math.pi

    # max(0, ...) floors tiny negative results from quadrature error on deep-OTM
    # options, where the true price is a rounding error away from zero anyway.
    call = max(0.0, df * (F * P1 - K * P2))
    if is_call:
        return call
    # put via parity
    # P = C − e^{−rT}(F − K). Derived rather than integrated separately, so the
    # call and put are guaranteed parity-consistent by construction.
    return max(0.0, call - df * (F - K))


# ── Fast pricer (Gauss-Laguerre, for calibration) ─────────────────────────────

def heston_price_fast(F: float, K: float, T: float, r: float,
                      params: HestonParams, is_call: bool) -> float:
    """Heston price via 100-pt Gauss-Laguerre quadrature.

    ~50× faster than the quad version; accuracy ~1e-4 in price.
    Use for calibration; use heston_price() for final production prices.

    THE ACCURACY TRADE IS THE RIGHT ONE FOR FITTING. 1e-4 in price is far below
    a bid/ask spread, and the calibrator prices thousands of options per
    objective evaluation across hundreds of evaluations — at 5 ms each the fit
    would never finish. Fixed nodes also make the objective SMOOTH in the
    parameters, which matters for the optimizer: adaptive quadrature can change
    its node placement between nearby parameter sets, injecting tiny
    discontinuities that a gradient-free method reads as noise.
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

    THE CALIBRATOR'S REAL WORKHORSE. The CF depends on T but NOT on K, so for a
    whole DTE slice it is evaluated once and shared across every strike — the
    expensive complex arithmetic is paid once per expiry instead of once per
    quote. Everything after that is real-valued matrix multiplication.

    The shape annotations below track the broadcast: (M,1) log-moneyness against
    (1,N) nodes gives an (M,N) phase matrix, summed along the node axis back to
    (M,) prices.
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

    # BOTH sides are computed for every strike and then selected between —
    # cheaper under vectorisation than branching, since parity makes the put
    # nearly free once the call exists.
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

    WHAT IT IS: a first-order Taylor adjustment ADDED to a Black-Scholes price,
    approximating what stochastic vol would do, rather than a real Heston price.
    The two terms are the vanna (spot/vol correlation) and vomma (vol convexity)
    contributions, each damped by mean reversion over the option's life.

    WHY IT SURVIVES: fair_value_engine still calls it whenever no reliable
    calibration exists for a ticker — which is the common case for anything
    outside the actively-calibrated universe. So this is not dead code; it is
    the degraded path, and its output is what model_fair_value carries when
    heston_fair_value is None.

    NOTE THE HARD-CODED DEFAULTS (κ=2.0, ξ=0.50, ρ=−0.70). Generic equity
    values, not fitted to the name being priced, which is exactly why a real
    calibration should replace it when one is available.
    """
    k = kappa
    a = rho_h * xi * vanna * (1 - math.exp(-k * T)) / k
    b = (xi * xi / 2) * vomma * (1 - math.exp(-2 * k * T)) / (2 * k)
    return a + b
