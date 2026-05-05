from __future__ import annotations

# =============================================================================
# services/expected_move.py
# =============================================================================
# Expected move and standard-deviation price bands from ATM implied volatility.
#
# Formula:
#   σ_period = IV × √(DTE / 365)          (total vol for the period)
#   EM ($)   = spot × σ_period
#   EM (%)   = σ_period × 100
#
# Log-normal bands (matches how options markets price probability):
#   upper_nσ = spot × exp( n × σ_period)
#   lower_nσ = spot × exp(-n × σ_period)
#
# Probability of price ending within each band at expiry:
#   ±1σ → 68.27%   ±2σ → 95.45%   ±3σ → 99.73%
# These are fixed constants of the log-normal model regardless of timeframe.
# =============================================================================

import math
from dataclasses import dataclass


PROB_1S: float = 0.6827
PROB_2S: float = 0.9545
PROB_3S: float = 0.9973


@dataclass
class ExpectedMoveSlice:
    iv:         float   # ATM IV (decimal, e.g. 0.25 = 25%)
    dte:        int     # actual DTE of the expiry used
    em_dollars: float   # 1σ expected move in dollars
    em_pct:     float   # 1σ expected move as % of spot
    upper_1s:   float
    lower_1s:   float
    upper_2s:   float
    lower_2s:   float
    upper_3s:   float
    lower_3s:   float


def compute(spot: float, iv: float, dte: int) -> ExpectedMoveSlice:
    t        = dte / 365.0
    sigma_t  = iv * math.sqrt(t)
    return ExpectedMoveSlice(
        iv         = iv,
        dte        = dte,
        em_dollars = spot * sigma_t,
        em_pct     = sigma_t * 100.0,
        upper_1s   = spot * math.exp(     sigma_t),
        lower_1s   = spot * math.exp(    -sigma_t),
        upper_2s   = spot * math.exp( 2 * sigma_t),
        lower_2s   = spot * math.exp(-2 * sigma_t),
        upper_3s   = spot * math.exp( 3 * sigma_t),
        lower_3s   = spot * math.exp(-3 * sigma_t),
    )


def atm_iv_from_chain(expirations: list[dict], spot: float, target_dte: int) -> tuple[float | None, int | None]:
    """Extract ATM IV from a parsed expirations list for the DTE closest to target_dte.

    Averages call and put IV at the ATM strike so put-call parity drift doesn't
    bias the result.  Returns (iv_decimal, actual_dte) or (None, None).
    """
    if not expirations:
        return None, None

    exp = min(expirations, key=lambda e: abs(e["dte"] - target_dte))
    dte = exp["dte"]

    ivs_by_strike: dict[float, list[float]] = {}
    for c in exp.get("calls", []):
        raw = float(c.get("volatility") or c.get("impliedVolatility") or 0)
        strike = float(c.get("strikePrice", 0))
        if raw > 0 and strike > 0:
            ivs_by_strike.setdefault(strike, []).append(raw / 100.0)
    for p in exp.get("puts", []):
        raw = float(p.get("volatility") or p.get("impliedVolatility") or 0)
        strike = float(p.get("strikePrice", 0))
        if raw > 0 and strike > 0:
            ivs_by_strike.setdefault(strike, []).append(raw / 100.0)

    if not ivs_by_strike:
        return None, None

    atm_strike = min(ivs_by_strike, key=lambda s: abs(s - spot))
    vals = ivs_by_strike[atm_strike]
    return sum(vals) / len(vals), dte
