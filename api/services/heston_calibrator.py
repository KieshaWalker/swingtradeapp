from __future__ import annotations
from typing import Optional

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
#
# THE HARDEST FIT IN THE SYSTEM, and the reason for every unusual choice below.
# Unlike SABR — three parameters fitted independently per DTE slice — Heston
# fits FIVE parameters GLOBALLY across the entire surface at once. One parameter
# set must reproduce every strike at every expiry simultaneously.
#
# WHY THE OBJECTIVE IS IN IV SPACE, NOT PRICE SPACE. Prices span orders of
# magnitude across a chain — a deep-OTM wing is worth cents while an ATM option
# is worth dollars — so a price-space objective would be dominated entirely by
# near-the-money strikes and would ignore the wings that carry the skew
# information. IV space weights every quote comparably. The cost is an inversion
# per quote per objective evaluation, which is what _bs_iv_batch exists to make
# affordable.
#
# THE TWO-STAGE OPTIMIZER. The surface is non-convex with many local minima, so
# a purely local method lands wherever it started. Differential evolution
# explores globally, then Nelder-Mead polishes. Neither alone is adequate.
#
# ⚠️ BOUNDARY SOLUTIONS ARE THE FAILURE MODE TO WATCH FOR — not high RMSE. A fit
# pinned against a bound reports success and a plausible error while describing
# a surface it never really matched. _on_bounds() at the bottom exists for
# exactly this, and the `converged` flag it feeds is NOT the same thing as
# scipy's own success flag. See the extended note in core/constants.py on why
# fixed bounds silently pin scale-dependent parameters.
#
# ⚠️ theta and V0 are VARIANCES. Their bounds are vol², so a cap of 4.0 admits
# vol up to 200%, not 400%.

import math
import time
from dataclasses import dataclass

import numpy as np
from scipy.optimize import differential_evolution, minimize
from scipy.special import ndtr as _ndtr

from core.constants import (
    DEFAULT_R,
    HESTON_KAPPA_BOUNDS,
    HESTON_THETA_BOUNDS,
    HESTON_XI_BOUNDS,
    HESTON_RHO_BOUNDS,
    HESTON_V0_BOUNDS,
    HESTON_BOUND_TOL,
    HESTON_MIN_DTE,
    HESTON_MAX_DTE,
)
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

    BISECTION, NOT NEWTON — deliberately. Newton is faster per root but can
    diverge, and inside an optimizer loop the parameters are frequently absurd,
    so robustness beats speed. Bisection cannot fail: 50 halvings of [1e-4, 10]
    give ~1e-7 precision unconditionally, in a fixed number of steps with no
    branching, which is what makes it vectorisable at all.

    The fixed iteration count is also what keeps the objective SMOOTH in the
    parameters. A convergence-based loop would take different numbers of steps
    for nearby parameter sets, injecting tiny discontinuities that a
    gradient-free optimizer reads as noise.

    Returns NaN for prices at or below intrinsic (no real IV exists) and for
    solutions pinned at the upper bound. The objective counts those NaNs as a
    fixed penalty rather than dropping them — see _objective.
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
    return np.where(valid & (result < 10.0 - 1e-4), result, np.nan)


# ── Surface parsing (same format as SABR calibrator) ─────────────────────────

def _build_quotes(
    surface_points: list[dict],
    spot: float,
    r: float,
) -> dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]]:
    """Parse surface_points into {dte: (F, K_arr, iv_arr, is_call_arr)}.

    OTM convention: call IV for K ≥ F, put IV for K < F.
    Drops strikes with IV == 0 or IV > 3.0 (data errors), and expiries outside
    [HESTON_MIN_DTE, HESTON_MAX_DTE] — see those constants for why the window
    matters more than any bound width.

    THE DTE WINDOW IS THE SINGLE BIGGEST ACCURACY LEVER, worth more than any
    bound widening: one 5-parameter affine diffusion cannot fit a 1-day smile and
    a 2.4-year smile at the same time. Spanning that range forces corner
    solutions no bound width can fix. Restricting to the tradeable window took
    median RMSE from 3.71 to 1.87 vol points across the test set.

    Note this splits on the FORWARD (K >= F), whereas services/arb_checker.py
    splits on spot — a small inconsistency between the two modules.
    """
    by_dte: dict[int, list[tuple[float, float, bool]]] = {}
    for p in surface_points:
        dte = int(p.get("dte", 0))
        K = float(p.get("strike", 0))
        if dte <= 0 or K <= 0:
            continue
        if dte < HESTON_MIN_DTE or dte > HESTON_MAX_DTE:
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
        K_arr       = np.array([row[0] for row in rows])
        iv_arr      = np.array([row[1] for row in rows])
        is_call_arr = np.array([row[2] for row in rows])
        result[dte] = (F, K_arr, iv_arr, is_call_arr)

    return result


# ── Surface downsampling ──────────────────────────────────────────────────────

# ⚠️ THE MOST AGGRESSIVE SPEED/ACCURACY TRADE IN THE FILE. At most 5 expiries x
# 7 strikes = 35 quotes reach the objective, out of the hundreds a liquid chain
# offers. Since the objective is evaluated thousands of times per fit, cost
# scales directly with quote count.
#
# It works because Heston has only five parameters: 35 well-chosen quotes
# over-determine them comfortably, and adding more mostly re-states information
# already present. The selection is what matters — spanning the term structure
# and staying near the money, where quotes are reliable.
_MAX_EXPIRIES = 5
_MAX_STRIKES  = 7

def _downsample_quotes(
    quotes: dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]],
) -> dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]]:
    """Reduce to at most _MAX_EXPIRIES spanning the term structure,
    keeping the _MAX_STRIKES strikes nearest ATM at each expiry."""
    if not quotes:
        return quotes

    dtes = sorted(quotes)
    # EVENLY SPACED ACROSS THE TERM STRUCTURE, not the nearest five. Term
    # structure is precisely what a global fit exists to capture, so the sample
    # must span it — five clustered near-dated expiries would leave κ (the
    # mean-reversion speed, which only reveals itself over time) unidentified.
    #
    # The set() collapses duplicate indices when there are barely more expiries
    # than the cap, so the result can be fewer than _MAX_EXPIRIES.
    if len(dtes) > _MAX_EXPIRIES:
        n = len(dtes)
        indices = sorted({round(i * (n - 1) / (_MAX_EXPIRIES - 1)) for i in range(_MAX_EXPIRIES)})
        dtes = [dtes[i] for i in indices]

    out: dict[int, tuple[float, np.ndarray, np.ndarray, np.ndarray]] = {}
    for dte in dtes:
        F, K_arr, iv_arr, is_call_arr = quotes[dte]
        # Nearest the FORWARD, not the widest span — near-the-money quotes are
        # the liquid, trustworthy ones, and the far wings are where a fit is most
        # easily dragged by a stale mid. The cost is less leverage on the extreme
        # tails of the smile.
        if len(K_arr) > _MAX_STRIKES:
            keep = np.argsort(np.abs(K_arr - F))[:_MAX_STRIKES]
            K_arr       = K_arr[keep]
            iv_arr      = iv_arr[keep]
            is_call_arr = is_call_arr[keep]
        out[dte] = (F, K_arr, iv_arr, is_call_arr)

    return out


# ── Calibration ───────────────────────────────────────────────────────────────

def calibrate_heston(
    surface_points: list[dict],
    spot: float,
    r: float = DEFAULT_R,
    atm_iv:Optional[float] = None,
    deadline_s:Optional[float] = None,
) ->Optional[HestonCalibResult]:
    """Fit Heston {κ, θ, ξ, ρ, V₀} to a vol-surface snapshot.

    Args:
        surface_points: List of vol surface dicts (same format as
            SabrCalibrator: [{strike, dte, callIv?, putIv?}]).
        spot: Underlying price.
        r: Risk-free rate.
        atm_iv: ATM implied vol (decimal) used to seed V₀ and θ.
            If None it is estimated from the surface itself.
        deadline_s: Optional wall-clock budget in seconds. When exceeded, both
            optimizers stop at their current best instead of running to
            completion (result has converged=False). Lets callers bound
            runtime without abandoning the worker thread mid-calibration.

    Returns:
        HestonCalibResult or None if surface is too thin.
    """
    # COOPERATIVE DEADLINE. monotonic() rather than wall-clock so a clock
    # adjustment cannot extend or truncate the budget. Both optimizers poll this
    # via callbacks and stop at their current best; see jobs/heston_pull.py for
    # why stopping cooperatively matters far more than an outer timeout —
    # asyncio.wait_for cannot kill the thread, only stop awaiting it.
    deadline = (time.monotonic() + deadline_s) if deadline_s else None

    def _out_of_time() -> bool:
        return deadline is not None and time.monotonic() > deadline

    by_dte = _downsample_quotes(_build_quotes(surface_points, spot, r))
    # Fewer than 8 quotes cannot identify five parameters — the fit would be
    # under-determined and would report a low RMSE precisely because it can pass
    # through nearly every point. Same threshold the read gates use.
    n_total = sum(len(v[1]) for v in by_dte.values())
    if n_total < 8:
        return None

    # ATM vol estimate for initial guess
    # MEDIAN, not mean — robust to a single mispriced wing quote dragging the
    # seed. Only a starting point, but a bad one wastes most of the global
    # search's budget getting back to a sensible vol level.
    if atm_iv is None:
        all_ivs = np.concatenate([v[2] for v in by_dte.values()])
        atm_iv = float(np.median(all_ivs))
    # Vol -> VARIANCE, the units theta and V0 are actually in.
    V_atm = atm_iv ** 2

    def _objective(x: np.ndarray) -> float:
        kappa, theta, xi, rho, V0 = x
        # Soft Feller penalty (2κθ ≥ ξ²)
        # SOFT, not a hard constraint, and that is the right choice: real equity
        # surfaces frequently need parameters that violate Feller, because the
        # steep short-dated skew genuinely requires a large ξ. A hard constraint
        # would refuse to fit them at all. The penalty makes violation costly
        # without forbidding it, so the optimizer prefers the well-behaved region
        # but can leave it when the data insists.
        feller_viol = max(0.0, xi ** 2 - 2 * kappa * theta)
        sse = 100.0 * feller_viol ** 2

        for dte, (F, K_arr, iv_mkt, is_call_arr) in by_dte.items():
            T = dte / 365.0
            try:
                params = HestonParams(kappa, theta, xi, rho, V0)
                prices = heston_price_batch(F, K_arr, T, r, params, is_call_arr)
            except Exception:
                # A parameter set that cannot even be priced is penalised at a
                # FINITE, calibrated cost rather than infinity. Infinity would
                # flatten the objective's gradient across the whole invalid
                # region, leaving the optimizer no information about which way to
                # move back out. 0.5² per strike is the same scale as a genuinely
                # terrible IV error, so an unpriceable set is treated as "very
                # bad" rather than "impossible".
                sse += float(len(K_arr)) * 0.25   # 0.5² per strike — same scale as IV errors
                continue

            iv_h = _bs_iv_batch(prices, F, K_arr, T, r, is_call_arr)
            # NaN means the model priced this strike at or below intrinsic, so
            # no IV exists. Penalised rather than skipped — skipping would let
            # the optimizer improve its score by producing UNPRICEABLE options,
            # which is the opposite of the intent.
            nan_mask = np.isnan(iv_h)
            sse += float(np.sum(nan_mask)) * 0.25  # 0.5² per NaN strike
            sse += float(np.sum((iv_h[~nan_mask] - iv_mkt[~nan_mask]) ** 2))

        return sse

    bounds = [
        HESTON_KAPPA_BOUNDS,
        HESTON_THETA_BOUNDS,
        HESTON_XI_BOUNDS,
        HESTON_RHO_BOUNDS,
        HESTON_V0_BOUNDS,
    ]

    # Seed from the observed ATM variance, clipped into the box. This was
    # previously computed and then dropped on the floor — differential_evolution
    # was left to find the vol level from Sobol points alone.
    # Clipped into the box because differential_evolution rejects an x0 outside
    # its bounds outright — and V_atm can exceed the theta ceiling on an
    # extremely high-vol name.
    x0 = np.clip(
        np.array([2.0, V_atm, 0.5, -0.7, V_atm]),
        [b[0] for b in bounds],
        [b[1] for b in bounds],
    )

    # Global search (differential evolution with Sobol initialisation).
    # Aggressively reduced for production speed: maxiter=20, popsize=4. Raising
    # this to 60/10 was measured and changed median RMSE by 0.00 vol points at
    # 2.7x the runtime — the global search is not the binding constraint.
    de_result = differential_evolution(
        _objective,
        bounds,
        maxiter=20,
        tol=1e-3,
        seed=42,
        init="sobol",
        popsize=4,
        # workers=1: single-process. The job already runs several tickers
        # concurrently and Cloud Run provides one core, so internal parallelism
        # would only contend with that.
        # polish=False: skip DE's own L-BFGS polish, since Nelder-Mead below
        # does the local refinement — and does it respecting the bounds.
        # seed=42 makes the fit REPRODUCIBLE; without it the same surface could
        # calibrate differently between hourly runs, and stored parameters would
        # jitter for no reason.
        workers=1,
        polish=False,
        x0=x0,
        # Returning True from a DE callback stops the search. The default
        # argument absorbs the `convergence` kwarg scipy passes positionally.
        callback=lambda xk, convergence=0.0: _out_of_time(),
    )

    # Nelder-Mead has no "stop" return convention, so the deadline is enforced
    # by raising StopIteration — which scipy catches internally and treats as a
    # request to terminate, returning the best point found so far.
    def _nm_deadline_cb(xk):
        if _out_of_time():
            raise StopIteration

    # Local refinement from the DE solution
    nm_result = minimize(
        _objective,
        de_result.x,
        method="Nelder-Mead",
        bounds=bounds,
        options={"maxiter": 1000, "fatol": 1e-9, "xatol": 1e-8},
        callback=_nm_deadline_cb,
    )

    # Clamp into the optimiser's own box. The previous version re-imposed
    # rho <= 0 here, silently discarding a positive-skew fit *after* the
    # optimiser had chosen it — see HESTON_RHO_BOUNDS.
    solution = [
        min(max(v, lo), hi) for v, (lo, hi) in zip(nm_result.x, bounds)
    ]
    kappa, theta, xi, rho, V0 = solution

    params = HestonParams(kappa=kappa, theta=theta, xi=xi, rho=rho, V0=V0)

    # Final RMSE — count only strikes where the model produced a valid IV
    sq_errors: list[float] = []
    n_valid = 0
    for dte, (F, K_arr, iv_mkt, is_call_arr) in by_dte.items():
        T = dte / 365.0
        try:
            prices = heston_price_batch(F, K_arr, T, r, params, is_call_arr)
        except Exception:
            continue
        iv_h = _bs_iv_batch(prices, F, K_arr, T, r, is_call_arr)
        valid = ~np.isnan(iv_h)
        sq_errors.extend((iv_h[valid] - iv_mkt[valid]) ** 2)
        n_valid += int(valid.sum())

    # RMSE is recomputed cleanly here rather than reusing the objective's SSE,
    # which carries the Feller and NaN penalties and so is not an error measure.
    #
    # Averaged over VALID strikes only, and n_valid is reported alongside — the
    # two must be read together, since a low RMSE over three strikes says
    # nothing. The 1.0 fallback (100 vol points) marks a total failure as
    # unmistakably unusable rather than as a suspiciously good zero.
    rmse = math.sqrt(sum(sq_errors) / n_valid) if n_valid > 0 else 1.0

    # nm_result.success alone is not a quality signal: Nelder-Mead reports
    # success whenever the simplex tolerance is met, and a simplex wedged in a
    # corner meets it reliably. Every boundary-pinned fit in 2026-05..07 was
    # stored as converged=True with RMSE up to 70 vol points. Require that no
    # parameter is sitting on an end of its box.
    return HestonCalibResult(
        params=params,
        rmse_iv=rmse,
        n_points=n_valid,
        converged=bool(nm_result.success) and not _on_bounds(solution, bounds),
    )


def _on_bounds(values: list, bounds: list) -> bool:
    """True when any parameter rests within HESTON_BOUND_TOL of its box end.

    THE REAL CONVERGENCE TEST. A parameter sitting on a bound means the optimizer
    wanted to go further and could not — the fit describes the edge of the
    allowed region, not the surface. Such a fit can still report a modest RMSE,
    which is what makes it dangerous.

    Tolerance is a FRACTION OF EACH BOX'S RANGE, not an absolute distance, so it
    scales correctly across parameters whose ranges differ by orders of magnitude
    (rho spans 1.98, kappa spans 49.9).

    ANY parameter on a bound condemns the whole fit: the five are jointly
    determined, so one pinned parameter distorts the others.
    """
    for v, (lo, hi) in zip(values, bounds):
        margin = HESTON_BOUND_TOL * (hi - lo)
        if v <= lo + margin or v >= hi - margin:
            return True
    return False
