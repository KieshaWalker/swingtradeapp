from __future__ import annotations
from typing import Optional

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
#
# WHAT THE EXPECTED MOVE IS. Options are priced under a log-normal distribution
# whose width is set by implied vol. Reading that width back out gives the
# market's OWN forecast of how far the underlying travels by expiry — not a
# prediction anyone made, but the number the option prices imply.
#
# WHY IT MATTERS FOR EVERY TRADE: a price target INSIDE the 1σ band is not an
# edge. It is what the market already charges for. A directional thesis only
# pays if it is either outside the band, or right more often than the ~68% the
# band implies.
#
# THE √TIME SCALING IS THE KEY PROPERTY. Vol scales with the square root of
# time, not linearly, so a 4x longer horizon widens the band only 2x. This is
# why short-dated options are cheap in absolute terms but expensive per unit of
# expected movement, and it is the whole basis of calendar spreads.
#
# LOG-NORMAL, NOT NORMAL — the bands are deliberately ASYMMETRIC. exp(+σ) is
# further above spot than exp(−σ) is below it, which is correct: a stock can
# rise without limit but cannot fall below zero. A naive spot ± σ band would
# quietly overstate downside probability and understate upside.
#
# UNITS: `iv` in and out is a DECIMAL (0.25 = 25%), while em_pct is a PERCENT.
# atm_iv_from_chain does the percent→decimal conversion at the chain boundary.

import math
from dataclasses import dataclass


# Probability the price finishes INSIDE each band at expiry. These are
# properties of the normal distribution itself (the log-normal's log is normal),
# so they hold for any ticker, any vol, any horizon — nothing here is calibrated
# or fitted. Exported for display alongside the bands.
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
    """Expected move and 1/2/3σ bands for one expiry.

    Pure arithmetic — no data access, no guards. A zero or negative dte yields a
    zero-width band rather than an error; callers (jobs/expected_move_pull.py)
    validate the IV and DTE before calling.

    CALENDAR days over 365, matching the ACT/365 convention used by the pricing
    services. Note this differs from realized vol, which annualizes over 252
    TRADING days because it is computed from daily returns — the two conventions
    coexist deliberately and must not be swapped.
    """
    t        = dte / 365.0
    # Total vol over the period, not annualized: the √time scaling that makes a
    # 30-day band only ~2.6x wider than a 5-day one rather than 6x.
    sigma_t  = iv * math.sqrt(t)
    return ExpectedMoveSlice(
        iv         = iv,
        dte        = dte,
        # 1σ move. Uses the LINEAR approximation (spot x σ) rather than the
        # log-normal band width, which is the market convention for quoting an
        # expected move and is what a straddle price approximates. The bands
        # below use the exact log-normal form, so em_dollars is very slightly
        # narrower than (upper_1s − spot) — expected, not a bug.
        em_dollars = spot * sigma_t,
        em_pct     = sigma_t * 100.0,
        # Exact log-normal bands: spot x e^(±nσ). Asymmetric by construction —
        # the upside band is further from spot than the downside one.
        upper_1s   = spot * math.exp(     sigma_t),
        lower_1s   = spot * math.exp(    -sigma_t),
        upper_2s   = spot * math.exp( 2 * sigma_t),
        lower_2s   = spot * math.exp(-2 * sigma_t),
        upper_3s   = spot * math.exp( 3 * sigma_t),
        lower_3s   = spot * math.exp(-3 * sigma_t),
    )


def atm_iv_from_chain(expirations: list[dict], spot: float, target_dte: int) -> tuple[Optional[float], Optional[int]]:
    """Extract ATM IV from a parsed expirations list for the DTE closest to target_dte.

    Averages call and put IV at the ATM strike so put-call parity drift doesn't
    bias the result.  Returns (iv_decimal, actual_dte) or (None, None).

    RETURNS THE ACTUAL DTE, not the target, and callers must price with it. Real
    chains rarely list an expiry at exactly the requested tenor, so a "weekly"
    band built from a 10-day expiry has to be scaled by 10 days or it is
    understated by ~20%.

    NEAREST-STRIKE ATM here, not 50-delta as jobs/common._atm_contract uses. The
    cruder measure is fine for this purpose: averaging both sides at the strike
    closest to spot is stable, and unlike the delta method it works when the
    chain omits Greeks entirely.

    Averaging call and put IV matters because put-call parity should force them
    equal but never quite does — bid/ask asymmetry, early-exercise premium on
    the put, and borrow costs all push them apart. Taking one side alone would
    inherit that bias; averaging cancels most of it.

    The percent→decimal conversion (/100) happens here, at the chain boundary.
    """
    if not expirations:
        return None, None

    # Nearest available expiry, in either direction — a 25-day expiry can serve
    # a 30-day target. No maximum distance is enforced, so a sparse chain may
    # return something far from the target; the returned DTE is the only signal
    # of that, which is why callers must store it.
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

    # Both sides accumulate into the SAME per-strike list, so a strike quoted on
    # both sides holds two values and the mean below is the call/put average.
    # A strike quoted on one side only contributes that side alone.
    if not ivs_by_strike:
        return None, None

    atm_strike = min(ivs_by_strike, key=lambda s: abs(s - spot))
    vals = ivs_by_strike[atm_strike]
    return sum(vals) / len(vals), dte
