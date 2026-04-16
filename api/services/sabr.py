# =============================================================================
# services/sabr.py
# =============================================================================
# SABR stochastic vol model — Hagan et al. (2002) implied-vol approximation.
# Exact port of _sabrIv() and _sabrAlpha() from fair_value_engine.dart and
# sabr_calibrator.dart (both files contain identical SABR formula code).
# =============================================================================

import math
from core.constants import SABR_ATM_LOG_THRESHOLD, SABR_CHIZ_THRESHOLD


def sabr_alpha(atm_iv: float, F: float, beta: float) -> float:
    """Back out SABR alpha from ATM IV: σ_ATM ≈ α / F^(1-β).

    Matches: FairValueEngine._sabrAlpha and SabrCalibrator initial guess.
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
    if alpha <= 0 or T <= 0 or F <= 0 or K <= 0:
        return 0.0

    log_fk = math.log(F / K)
    abs_log = abs(log_fk)

    # ── ATM case ──────────────────────────────────────────────────────────────
    if abs_log < SABR_ATM_LOG_THRESHOLD:
        f_beta = F ** (1 - beta)
        t1 = ((1 - beta) ** 2) / 24 * alpha * alpha / (F ** (2 * (1 - beta)))
        t2 = rho * beta * nu * alpha / (4 * f_beta)
        t3 = (2 - 3 * rho * rho) * nu * nu / 24
        return (alpha / f_beta) * (1 + (t1 + t2 + t3) * T)

    # ── Non-ATM case ──────────────────────────────────────────────────────────
    fk_beta = (F * K) ** ((1 - beta) / 2)
    denom = fk_beta * (
        1
        + ((1 - beta) ** 2) / 24 * log_fk * log_fk
        + ((1 - beta) ** 4) / 1920 * (log_fk ** 4)
    )

    z = nu / alpha * fk_beta * log_fk
    chi_z = math.log(
        (math.sqrt(1 - 2 * rho * z + z * z) + z - rho) / (1 - rho)
    )
    zx = 1.0 if abs(chi_z) < SABR_CHIZ_THRESHOLD else z / chi_z

    t1 = ((1 - beta) ** 2) / 24 * alpha * alpha / ((F * K) ** (1 - beta))
    t2 = rho * beta * nu * alpha / (4 * fk_beta)
    t3 = (2 - 3 * rho * rho) * nu * nu / 24

    return (alpha / denom) * zx * (1 + (t1 + t2 + t3) * T)
