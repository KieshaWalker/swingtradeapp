from __future__ import annotations

# =============================================================================
# services/rnd.py
# =============================================================================
# Breeden-Litzenberger Risk-Neutral Density extraction.
#
# Theory:
#   q(K) = e^(rT) * d²C/dK²
#
# Method:
#   1. Use a calibrated SabrSlice to synthesize call prices on a fine uniform
#      strike grid via BS(σ_SABR(K)).
#   2. Differentiate twice with central finite differences (h = RND_FD_STEP_PCT * spot).
#   3. Clip negative density values to zero (butterfly-arb noise at extremes).
#   4. Normalise so the density integrates to 1 over the grid.
#   5. Compute CDF complements and implied moments via trapezoidal quadrature.
# =============================================================================

import math
import logging
from dataclasses import dataclass
from typing import List, Optional

import numpy as np

# np.trapezoid added in NumPy 2.0; np.trapz is the legacy name.
try:
    _trapz = np.trapezoid  # type: ignore[attr-defined]
except AttributeError:
    _trapz = np.trapz  # type: ignore[attr-defined]

from core.constants import (
    DEFAULT_R,
    SABR_BETA,
    RND_STRIKE_HALF_WIDTH_PCT,
    RND_NUM_GRID_POINTS,
    RND_FD_STEP_PCT,
)
from services.sabr import sabr_iv
from services.black_scholes import bs_price
from services.sabr_calibrator import SabrSlice, calibrate_slice

_log = logging.getLogger(__name__)


@dataclass
class RndPoint:
    strike: float
    density: float      # q(K), normalised
    prob_above: float   # P(S_T > K)
    prob_below: float   # P(S_T ≤ K)


@dataclass
class RndMoments:
    mean: float
    variance: float
    implied_vol: float  # lognormal cross-check: sqrt(ln(1 + Var/mean²) / T)
    skewness: float
    kurtosis: float     # excess


@dataclass
class RndSlice:
    dte: int
    expiry: str
    strikes: List[RndPoint]
    moments: RndMoments
    sabr_alpha: float
    sabr_rho: float
    sabr_nu: float
    sabr_rmse: float
    reliable: bool

    def to_dict(self) -> dict:
        return {
            "dte": self.dte,
            "expiry": self.expiry,
            "sabr_alpha": self.sabr_alpha,
            "sabr_rho": self.sabr_rho,
            "sabr_nu": self.sabr_nu,
            "sabr_rmse": self.sabr_rmse,
            "reliable": self.reliable,
            "moments": {
                "mean": self.moments.mean,
                "variance": self.moments.variance,
                "implied_vol": self.moments.implied_vol,
                "skewness": self.moments.skewness,
                "kurtosis": self.moments.kurtosis,
            },
            "strikes": [
                {
                    "strike": p.strike,
                    "density": p.density,
                    "prob_above": p.prob_above,
                    "prob_below": p.prob_below,
                }
                for p in self.strikes
            ],
        }


def compute_rnd_slice(
    sabr_slice: SabrSlice,
    spot: float,
    T: float,
    r: float = DEFAULT_R,
    expiry: str = "",
) -> Optional[RndSlice]:
    """Extract Breeden-Litzenberger RND for one DTE slice from a calibrated SabrSlice."""
    if T <= 0 or spot <= 0:
        return None

    F = spot * math.exp(r * T)
    h = spot * RND_FD_STEP_PCT

    K_lo = max(spot * (1.0 - RND_STRIKE_HALF_WIDTH_PCT), spot * 0.05)
    K_hi = spot * (1.0 + RND_STRIKE_HALF_WIDTH_PCT)
    grid: np.ndarray = np.linspace(K_lo, K_hi, RND_NUM_GRID_POINTS)

    def sabr_call(K: float) -> float:
        if K <= 0:
            return max(F - K, 0.0) * math.exp(-r * T)
        iv = sabr_iv(
            F=F, K=K, T=T,
            alpha=sabr_slice.alpha,
            beta=sabr_slice.beta,
            rho=sabr_slice.rho,
            nu=sabr_slice.nu,
        )
        if iv <= 0 or math.isnan(iv):
            return max(F - K, 0.0) * math.exp(-r * T)
        return bs_price(F=F, K=K, T=T, r=r, sigma=iv, is_call=True)

    C_mid  = np.array([sabr_call(K)     for K in grid])
    C_up   = np.array([sabr_call(K + h) for K in grid])
    C_down = np.array([sabr_call(K - h) for K in grid])

    d2C_dK2 = (C_up - 2.0 * C_mid + C_down) / (h * h)
    q_raw = math.exp(r * T) * d2C_dK2

    q_clipped = np.maximum(q_raw, 0.0)
    total_mass = float(_trapz(q_clipped, grid))
    if total_mass < 1e-12:
        _log.warning("rnd: near-zero density mass for DTE=%d, skipping", sabr_slice.dte)
        return None

    q_norm = q_clipped / total_mass

    dK = float(grid[1] - grid[0])
    prob_below = np.zeros(len(grid))
    for i in range(1, len(grid)):
        prob_below[i] = prob_below[i - 1] + 0.5 * (q_norm[i - 1] + q_norm[i]) * dK

    cdf_max = float(prob_below[-1])
    if cdf_max > 0:
        prob_below = prob_below / cdf_max
    prob_above = 1.0 - prob_below

    mean = float(_trapz(grid * q_norm, grid))

    if F > 0 and abs(mean / F - 1.0) > 0.03:
        _log.warning(
            "rnd: mean/F = %.3f for DTE=%d — possible truncation or poor SABR fit",
            mean / F, sabr_slice.dte,
        )

    variance = float(_trapz((grid - mean) ** 2 * q_norm, grid))
    std = math.sqrt(max(variance, 0.0))

    var_ratio = variance / (mean * mean) if mean > 0 else 0.0
    if var_ratio > 0 and T > 0:
        implied_vol_rnd = math.sqrt(math.log(1.0 + var_ratio) / T)
    else:
        implied_vol_rnd = 0.0

    skewness = 0.0
    kurtosis = 0.0
    if std > 1e-12:
        third_central  = float(_trapz((grid - mean) ** 3 * q_norm, grid))
        fourth_central = float(_trapz((grid - mean) ** 4 * q_norm, grid))
        skewness = third_central  / (std ** 3)
        kurtosis = fourth_central / (std ** 4) - 3.0

    points = [
        RndPoint(
            strike=round(float(grid[i]), 4),
            density=round(float(q_norm[i]), 8),
            prob_above=round(float(prob_above[i]), 6),
            prob_below=round(float(prob_below[i]), 6),
        )
        for i in range(len(grid))
    ]

    moments = RndMoments(
        mean=round(mean, 4),
        variance=round(variance, 6),
        implied_vol=round(implied_vol_rnd, 6),
        skewness=round(skewness, 6),
        kurtosis=round(kurtosis, 6),
    )

    return RndSlice(
        dte=sabr_slice.dte,
        expiry=expiry,
        strikes=points,
        moments=moments,
        sabr_alpha=round(sabr_slice.alpha, 6),
        sabr_rho=round(sabr_slice.rho, 6),
        sabr_nu=round(sabr_slice.nu, 6),
        sabr_rmse=round(sabr_slice.rmse, 6),
        reliable=sabr_slice.is_reliable,
    )


def compute_rnd_surface(
    expirations: List[dict],
    spot: float,
    r: float = DEFAULT_R,
) -> List[RndSlice]:
    """Compute RND for every DTE slice that survives SABR calibration.

    Reads directly from the Schwab chain expirations list. IVs are in percent
    form (e.g. 21.0 = 21%) and are divided by 100 before calibration.
    """
    results: List[RndSlice] = []

    for exp in expirations:
        dte = int(exp.get("dte", 0))
        if dte <= 0:
            continue

        T = dte / 365.0
        F = spot * math.exp(r * T)

        call_iv_map: dict = {}
        put_iv_map: dict = {}

        for c in exp.get("calls", []):
            iv_raw = float(c.get("volatility") or c.get("impliedVolatility") or 0)
            k = float(c.get("strikePrice", 0))
            if k > 0 and iv_raw > 0:
                call_iv_map[k] = iv_raw / 100.0

        for p in exp.get("puts", []):
            iv_raw = float(p.get("volatility") or p.get("impliedVolatility") or 0)
            k = float(p.get("strikePrice", 0))
            if k > 0 and iv_raw > 0:
                put_iv_map[k] = iv_raw / 100.0

        # OTM convention: calls above forward, puts below
        quotes: List[tuple] = []
        all_strikes = sorted(set(call_iv_map) | set(put_iv_map))
        for k in all_strikes:
            if k >= F and k in call_iv_map:
                quotes.append((k, call_iv_map[k]))
            elif k < F and k in put_iv_map:
                quotes.append((k, put_iv_map[k]))
            elif k in call_iv_map:
                quotes.append((k, call_iv_map[k]))
            elif k in put_iv_map:
                quotes.append((k, put_iv_map[k]))

        sabr = calibrate_slice(quotes=quotes, F=F, T=T, beta=SABR_BETA)
        if sabr is None:
            _log.debug("rnd: SABR calibration returned None for DTE=%d, skipping", dte)
            continue

        if not sabr.is_reliable:
            _log.debug(
                "rnd: unreliable SABR for DTE=%d (rmse=%.4f, n=%d), proceeding",
                dte, sabr.rmse, sabr.n_points,
            )

        expiry_str = ""
        for c in exp.get("calls", []):
            raw = c.get("expirationDate", "")
            if raw:
                expiry_str = str(raw)[:10]
                break
        if not expiry_str:
            for p in exp.get("puts", []):
                raw = p.get("expirationDate", "")
                if raw:
                    expiry_str = str(raw)[:10]
                    break

        try:
            rnd = compute_rnd_slice(sabr_slice=sabr, spot=spot, T=T, r=r, expiry=expiry_str)
            if rnd is not None:
                results.append(rnd)
        except Exception:
            _log.exception("rnd: unexpected error for DTE=%d, skipping", dte)

    results.sort(key=lambda s: s.dte)
    return results
