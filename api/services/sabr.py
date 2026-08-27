# =============================================================================
# services/sabr.py
# =============================================================================
# SABR stochastic vol model — Hagan et al. (2002) implied-vol approximation.
# Exact port of _sabrIv() and _sabrAlpha() from fair_value_engine.dart and
# sabr_calibrator.dart (both files contain identical SABR formula code).
# =============================================================================
#
# WHAT THE FOUR PARAMETERS DO TO THE SMILE — the intuition worth having:
#   α (alpha)  overall LEVEL. Scales the whole curve up or down.
#   β (beta)   CEV exponent, FIXED at 0.5. Governs how vol responds to the
#              forward's level. Not fitted — see below.
#   ρ (rho)    SKEW / tilt. Negative for equities: vol rises as price falls.
#   ν (nu)     CURVATURE / smile depth. The vol-of-vol; ν→0 gives a pure CEV
#              curve with no smile at all.
#
# WHY β IS PINNED AND NOT FITTED. β and ρ are nearly indistinguishable from a
# single smile — they trade off against each other, so the objective has a long
# flat valley and an optimizer wanders along it without improving the fit.
# Fixing β at the square-root-CEV value (the standard equity convention) leaves
# three well-identified parameters. See core/constants.SABR_BETA.
#
# THIS IS AN ASYMPTOTIC EXPANSION, NOT AN EXACT SOLUTION. Hagan's formula is an
# expansion in T and in log-moneyness, so accuracy degrades for long maturities
# and far strikes — which is why core/constants caps calibration DTE and why the
# router rejects expiries beyond ~3 years.
#
# NUMERICALLY DELICATE: the non-ATM branch divides by χ(z), which → 0 as z → 0
# (i.e. as K → F). Both branches below exist to keep that from exploding, and
# the ATM branch is the analytic limit of the non-ATM one, not an approximation
# of it.

import math
from core.constants import SABR_ATM_LOG_THRESHOLD, SABR_CHIZ_THRESHOLD


def sabr_alpha(atm_iv: float, F: float, beta: float) -> float:
    """Back out SABR alpha from ATM IV: σ_ATM ≈ α / F^(1-β).

    Matches: FairValueEngine._sabrAlpha and SabrCalibrator initial guess.

    The inverse of the leading term of the ATM formula below, giving the α that
    reproduces an observed ATM vol. Used as the calibrator's SEED — starting the
    optimizer at an α that already matches the money is what lets three
    parameters converge from a handful of quotes.

    NOTE α IS NOT SCALE-INVARIANT: it carries a factor of F^(1−β), so its
    magnitude depends on the underlying's price level. A $1,200 stock produces a
    much larger α than a $30 one at the same vol, which is exactly why a FIXED
    upper bound on α silently pins high-priced names — see the extended note on
    SABR_ALPHA_BOUNDS in core/constants.py.
    """
    return atm_iv * (F ** (1 - beta))


def sabr_iv(
    F: float,
    K: float,
    T: float,
    alpha: float,
    beta: float,
    rho: float,
    nu: float,
) -> float:
    """Hagan (2002) SABR implied vol approximation — exact port of Dart code.

    Handles:
    - ATM case (|ln(F/K)| < 1e-6)
    - Non-ATM case with z/χ(z) ratio
    - chi(z) near-zero guard (returns 1.0)

    Returns 0.0 for invalid inputs (alpha <= 0, T <= 0, F <= 0, K <= 0).
    """
    # Returns 0.0, not None and not an exception — the calibrator's objective
    # calls this thousands of times inside an optimizer loop, and a sentinel it
    # can test is cheaper than exception handling per evaluation. Callers must
    # therefore treat a returned 0.0 as "unusable parameters", never as a real
    # vol of zero.
    if alpha <= 0 or T <= 0 or F <= 0 or K <= 0:
        return 0.0

    log_fk = math.log(F / K)
    abs_log = abs(log_fk)

    # ── ATM case ──────────────────────────────────────────────────────────────
    # The z/χ(z) ratio in the general formula is 0/0 at K = F. This branch is its
    # ANALYTIC LIMIT (the ratio → 1), not a fallback approximation — so the two
    # branches agree smoothly across the threshold rather than stepping.
    if abs_log < SABR_ATM_LOG_THRESHOLD:
        f_beta = F ** (1 - beta)
        # The three first-order correction terms, shared with the non-ATM branch:
        #   t1  CEV/backbone contribution (vanishes at β = 1)
        #   t2  skew-vol cross term (correlation x vol-of-vol)
        #   t3  pure vol-of-vol convexity
        # Each is multiplied by T, so all three vanish as expiry approaches and
        # grow with maturity — the mechanism behind the expansion's degradation
        # at long tenors.
        t1 = ((1 - beta) ** 2) / 24 * alpha * alpha / (F ** (2 * (1 - beta)))
        t2 = rho * beta * nu * alpha / (4 * f_beta)
        t3 = (2 - 3 * rho * rho) * nu * nu / 24
        # Leading term α/F^(1−β) — the inverse of sabr_alpha() above.
        return (alpha / f_beta) * (1 + (t1 + t2 + t3) * T)

    # ── Non-ATM case ──────────────────────────────────────────────────────────
    # Geometric mean of F and K raised to (1−β)/2 — the natural generalization
    # of the ATM branch's F^(1−β), reducing to it exactly when K = F.
    fk_beta = (F * K) ** ((1 - beta) / 2)
    # Denominator expansion in log-moneyness. Only even powers appear (2nd and
    # 4th), so the correction is symmetric in ln(F/K): it widens the curve away
    # from the money without tilting it. All the tilt comes from ρ, via z below.
    denom = fk_beta * (
        1
        + ((1 - beta) ** 2) / 24 * log_fk * log_fk
        + ((1 - beta) ** 4) / 1920 * (log_fk ** 4)
    )

    # z measures how far the strike sits from the forward in units of vol-of-vol.
    # χ(z) is the integral that maps that distance onto the smile, and the ratio
    # z/χ(z) is what produces the skew.
    z = nu / alpha * fk_beta * log_fk
    chi_z = math.log(
        (math.sqrt(1 - 2 * rho * z + z * z) + z - rho) / (1 - rho)
    )
    # Near the money both z and χ(z) → 0 and their ratio → 1 analytically. The
    # guard substitutes that limit directly rather than dividing two near-zero
    # floats, which would be numerically meaningless.
    if abs(chi_z) < SABR_CHIZ_THRESHOLD:
        zx = 1.0
    else:
        zx = z / chi_z
        # Clamp: z/chi_z → 1 analytically as z→0; large ratio means near-singular rho
        # As |ρ| → 1 the (1−ρ) denominator inside χ(z) collapses and the ratio
        # explodes. The clamp keeps the calibrator's objective FINITE so the
        # optimizer can walk back out of that corner, rather than seeing a NaN
        # and stalling there. It is a numerical guard, not a modelling choice —
        # a fit that relies on it has ρ pinned and should be treated as
        # unreliable (see SABR_RHO_BOUNDS and the retry logic in the calibrator).
        zx = max(0.01, min(100.0, zx))

    t1 = ((1 - beta) ** 2) / 24 * alpha * alpha / ((F * K) ** (1 - beta))
    t2 = rho * beta * nu * alpha / (4 * fk_beta)
    t3 = (2 - 3 * rho * rho) * nu * nu / 24

    # Same three correction terms as the ATM branch, but with (F·K) in place of
    # F² — again reducing exactly to the ATM form when K = F.
    return (alpha / denom) * zx * (1 + (t1 + t2 + t3) * T)
