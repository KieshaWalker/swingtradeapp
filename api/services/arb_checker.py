from __future__ import annotations
from typing import Optional

# =============================================================================
# services/arb_checker.py
# =============================================================================
# Static arbitrage detection for a volatility surface.
# Exact port of ArbChecker from arb_checker.dart.
#
# Checks:
#   1. Calendar spread arb: total variance σ²·T must be non-decreasing in T.
#   2. Butterfly arb: call prices C(K) must be convex in K at fixed T.
# =============================================================================
#
# THIS IS A DATA-QUALITY GATE, NOT A TRADING SIGNAL. A surface assembled from
# real quotes is not automatically self-consistent: wide markets, stale mids and
# thin wings routinely imply a risk-free profit that could never be captured.
# Anything that INTERPOLATES the surface — SABR and Heston fits, RND extraction,
# fair-value comparisons — will amplify such a defect into a confident wrong
# number. Violations mean "do not trust this snapshot".
#
# THE TWO CONDITIONS TEST DIFFERENT AXES:
#   CALENDAR   across TIME at a fixed strike. Total variance σ²·T must be
#              non-decreasing — variance accumulates and cannot un-happen.
#              Note a σ that FALLS with maturity is perfectly normal; only
#              falling σ²·T is a violation.
#   BUTTERFLY  across STRIKE at a fixed expiry. Call prices must be convex in K,
#              or a butterfly spread could be bought for negative cost with a
#              non-negative payoff.
#
# WHY BUTTERFLY WORKS ON PRICES AND CALENDAR ON VOLS: convexity is a statement
# about prices, so the IVs must be converted through Black-Scholes first — which
# is why that check needs a rate and the calendar check does not.
#
# ARB_EPSILON absorbs floating-point noise and one-tick rounding, so a violation
# reported here is larger than quote granularity.

import math
from dataclasses import dataclass

from scipy.stats import norm

from core.constants import ARB_EPSILON, DEFAULT_R


@dataclass
class CalendarViolation:
    strike: float
    near_dte: int
    far_dte: int
    near_total_var: float
    far_total_var: float
    violation: float

    def __str__(self) -> str:
        return (
            f"Calendar arb: K=${self.strike:.1f} {self.near_dte}d vs {self.far_dte}d — "
            f"w²={self.near_total_var:.4f} > {self.far_total_var:.4f} "
            f"(violation: {self.violation:.4f})"
        )


@dataclass
class ButterflyViolation:
    dte: int
    strike: float
    convexity_value: float

    def __str__(self) -> str:
        return (
            f"Butterfly arb: {self.dte}d K=${self.strike:.1f} "
            f"convexity={self.convexity_value:.4f} < 0"
        )


@dataclass
class ArbCheckResult:
    calendar_violations: list[CalendarViolation]
    butterfly_violations: list[ButterflyViolation]

    @property
    def is_arbitrage_free(self) -> bool:
        return not self.calendar_violations and not self.butterfly_violations

    @property
    def total_violations(self) -> int:
        return len(self.calendar_violations) + len(self.butterfly_violations)

    @property
    def summary(self) -> str:
        if self.is_arbitrage_free:
            return "Surface is arbitrage-free"
        parts = []
        if self.calendar_violations:
            n = len(self.calendar_violations)
            parts.append(f"{n} calendar arb {'violation' if n == 1 else 'violations'}")
        if self.butterfly_violations:
            n = len(self.butterfly_violations)
            parts.append(f"{n} butterfly arb {'violation' if n == 1 else 'violations'}")
        return "Surface arb detected: " + ", ".join(parts)

    @property
    def worst_calendar_violation(self) -> float:
        return max((v.violation for v in self.calendar_violations), default=0.0)

    @property
    def worst_butterfly_violation(self) -> float:
        return max((abs(v.convexity_value) for v in self.butterfly_violations), default=0.0)


def _otm_iv(point: dict, spot: float) ->Optional[float]:
    """OTM convention: call IV for K≥spot, put IV for K<spot.

    OTM options are the liquid ones, so their IVs are the trustworthy ones. The
    ITM side of the same strike is usually wide and stale, and including it would
    manufacture violations that are artefacts of the quote rather than the
    surface.

    Falls back to the other side when the preferred one is absent, so a
    one-sided strike still contributes.

    Note this compares against SPOT, whereas the calibrators split on the
    FORWARD. A minor inconsistency — the two differ by the carry, so a strike
    between spot and forward may take the other side's IV here than it would in
    services/sabr_calibrator.py.
    """
    strike = float(point.get("strike") or 0)
    if strike >= spot:
        v = point.get("callIv") or point.get("call_iv") or point.get("putIv") or point.get("put_iv")
    else:
        v = point.get("putIv") or point.get("put_iv") or point.get("callIv") or point.get("call_iv")
    return float(v) if v is not None else None


def _bs_call(F: float, K: float, T: float, sigma: float, r: float = DEFAULT_R) -> float:
    """Black-Scholes call price for butterfly check. Matches ArbChecker._bsCall().

    A LOCAL COPY of services/black_scholes.bs_price, kept to match the Dart
    original exactly. Always prices a CALL regardless of which side the IV came
    from — correct, since convexity is a property of the call price surface, and
    put-call parity means a convex call surface implies a convex put surface.
    """
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    df = math.exp(-r * T)
    if sig_sqt < 1e-8:
        return df * max(F - K, 0)
    d1 = (math.log(F / K) + 0.5 * sigma * sigma * T) / sig_sqt
    d2 = d1 - sig_sqt
    return float(df * (F * norm.cdf(d1) - K * norm.cdf(d2)))


def check(
    points: list[dict],  # [{strike, dte, callIv?, putIv?}]
    spot: float,
    r: float = DEFAULT_R,
) -> ArbCheckResult:
    """Run both arb checks on a vol surface snapshot.

    Args:
        points: Vol surface points (same shape as vol_surface_snapshots.points JSONB).
        spot: Underlying price at observation date.
        r: Risk-free rate.

    Returns:
        ArbCheckResult with lists of violations.
    """
    if not points or spot <= 0:
        return ArbCheckResult(calendar_violations=[], butterfly_violations=[])

    return ArbCheckResult(
        calendar_violations=_check_calendar(points, spot),
        butterfly_violations=_check_butterfly(points, spot, r),
    )


def _check_calendar(points: list[dict], spot: float) -> list[CalendarViolation]:
    """Calendar arb: w²(T) = σ²·T must be non-decreasing in T for each strike.

    Groups by strike, sorts by DTE, and compares ADJACENT pairs only — sufficient
    by transitivity, since if every neighbouring pair is non-decreasing the whole
    sequence is.

    Strikes with fewer than two expiries are skipped: there is nothing to compare.

    The violation magnitude is the raw total-variance difference, so it is
    comparable across strikes but not across very different maturities.
    """
    by_strike: dict[float, list[tuple[int, float]]] = {}
    for p in points:
        iv = _otm_iv(p, spot)
        if iv is None or iv <= 0:
            continue
        strike = float(p.get("strike", 0))
        dte = int(p.get("dte", 0))
        if strike <= 0 or dte <= 0:
            continue
        by_strike.setdefault(strike, []).append((dte, iv))

    violations = []
    for strike, slices in by_strike.items():
        slices.sort(key=lambda x: x[0])
        if len(slices) < 2:
            continue
        for i in range(len(slices) - 1):
            near_dte, near_iv = slices[i]
            far_dte, far_iv = slices[i + 1]
            near_T = near_dte / 365.0
            far_T = far_dte / 365.0
            near_total_var = near_iv * near_iv * near_T
            far_total_var = far_iv * far_iv * far_T
            diff = near_total_var - far_total_var
            if diff > ARB_EPSILON:
                violations.append(CalendarViolation(
                    strike=strike,
                    near_dte=near_dte,
                    far_dte=far_dte,
                    near_total_var=near_total_var,
                    far_total_var=far_total_var,
                    violation=diff,
                ))

    return violations


def _check_butterfly(points: list[dict], spot: float, r: float = DEFAULT_R) -> list[ButterflyViolation]:
    """Butterfly arb: call prices C(K) must be convex in K at each fixed DTE.

    Converts each strike's IV to a call price, then tests the discrete second
    difference C(K₋) − 2C(K₀) + C(K₊) at every interior strike. That expression
    IS the cost of a butterfly spread, so a negative value means the spread could
    be bought for less than nothing.

    Needs at least three strikes per expiry — a second difference has no meaning
    with fewer.

    NOTE THE STRIKES NEED NOT BE EVENLY SPACED, and the test does not weight for
    that. On a chain with uneven strike increments (common in the wings) the
    unweighted second difference can flag a violation that is really an artefact
    of the spacing. Read wing violations with that in mind; near-the-money
    strikes, where spacing is uniform, are the reliable ones.
    """
    by_dte: dict[int, list[tuple[float, float]]] = {}
    for p in points:
        iv = _otm_iv(p, spot)
        if iv is None or iv <= 0:
            continue
        strike = float(p.get("strike", 0))
        dte = int(p.get("dte", 0))
        if strike <= 0 or dte <= 0:
            continue
        by_dte.setdefault(dte, []).append((strike, iv))

    violations = []
    for dte, slice_pts in by_dte.items():
        slice_pts.sort(key=lambda x: x[0])
        if len(slice_pts) < 3:
            continue
        T = dte / 365.0
        F = spot * math.exp(r * T)
        call_prices = [_bs_call(F=F, K=K, T=T, sigma=iv, r=r) for K, iv in slice_pts]

        for i in range(1, len(slice_pts) - 1):
            convexity = call_prices[i - 1] - 2 * call_prices[i] + call_prices[i + 1]
            if convexity < -ARB_EPSILON:
                violations.append(ButterflyViolation(
                    dte=dte,
                    strike=slice_pts[i][0],
                    convexity_value=convexity,
                ))

    return violations
