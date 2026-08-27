from __future__ import annotations
from typing import Optional

# =============================================================================
# services/greek_grid_ingester.py
# =============================================================================
# Aggregate a Schwab options chain into (StrikeBand × ExpiryBucket) grid cells.
# Exact port of GreekGridIngester from greek_grid_ingester.dart.
#
# Second-order greeks use true BS forward: F = S * exp(r * T).
# Matches greek_grid_ingester.dart after the same fix was applied.
# =============================================================================
#
# COLLAPSES A WHOLE CHAIN INTO A 5x5 MATRIX — five strike bands (deep_itm ..
# deep_otm) by five expiry buckets (weekly .. quarterly), at most 25 cells. The
# point is a readable map of WHERE risk sits on the surface, rather than the
# hundreds of individual contracts that produced it.
#
# MEDIANS, NOT MEANS, for every greek. A cell can contain contracts of very
# different liquidity and a single stale quote with an absurd greek would drag a
# mean badly. The median is unmoved by it. Open interest and volume are SUMMED
# instead, because those are genuinely additive quantities.
#
# CALLS AND PUTS ARE POOLED for every greek EXCEPT DELTA. Gamma, vega, theta,
# vanna and volga are the same sign for both sides, so pooling them doubles the
# sample. Put delta is negative and would cancel call delta into a meaningless
# median, so only call deltas are collected — see include_delta below.
#
# SECOND-ORDER GREEKS ARE COMPUTED HERE, not taken from Schwab, which does not
# supply vanna, charm or volga at all. That recomputation is the main reason
# jobs/greek_grid_pull.py fetches its own chain rather than reading the stored
# vol surface.
#
# ⚠️ contract_count IS THE FIELD TO CHECK FIRST. A cell aggregating one contract
# is not a reading about a band — it is a single strike wearing a band's label.

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from statistics import median as py_median

from core.chain_utils import normalize_chain
from core.constants import DEFAULT_R


class StrikeBand(str, Enum):
    deep_itm = "deep_itm"
    itm = "itm"
    atm = "atm"
    otm = "otm"
    deep_otm = "deep_otm"


class ExpiryBucket(str, Enum):
    weekly = "weekly"             # dte <= 7
    near_monthly = "near_monthly" # dte <= 30
    monthly = "monthly"           # dte <= 60
    far_monthly = "far_monthly"   # dte <= 90
    quarterly = "quarterly"       # dte > 90


# Bands are cut on MONEYNESS PERCENT relative to spot, not on absolute dollars,
# so the same taxonomy works for a $30 stock and a $1,200 one. Note the bands are
# defined from the CALL perspective (negative moneyness = strike below spot =
# in-the-money for a call); puts falling in a "deep_itm" band are actually deep
# OTM. The band describes the STRIKE's position, not any contract's status.
def classify_strike_band(moneyness_pct: float) -> StrikeBand:
    """Classify a strike into a band based on moneyness %.
    Matches StrikeBand.fromMoneynessPct() in Dart greek_grid_models.dart.
    """
    if moneyness_pct < -15.0:
        return StrikeBand.deep_itm
    if moneyness_pct < -5.0:
        return StrikeBand.itm
    if moneyness_pct <= 5.0:
        return StrikeBand.atm
    if moneyness_pct <= 15.0:
        return StrikeBand.otm
    return StrikeBand.deep_otm


# Buckets are uneven by design — tight near the front (7, 30) where option
# behaviour changes fastest, wide at the back (60, 90, beyond) where a few days
# either way makes little difference.
def classify_expiry_bucket(dte: int) -> ExpiryBucket:
    """Classify DTE into an expiry bucket.
    Matches ExpiryBucket.fromDte() in Dart greek_grid_models.dart.
    """
    if dte <= 7:
        return ExpiryBucket.weekly
    if dte <= 30:
        return ExpiryBucket.near_monthly
    if dte <= 60:
        return ExpiryBucket.monthly
    if dte <= 90:
        return ExpiryBucket.far_monthly
    return ExpiryBucket.quarterly


def _median(vals: list[float]) -> float:
    """Matches Dart _median() function exactly."""
    if not vals:
        return 0.0
    return py_median(vals)


def _second_order_approx(
    spot: float,
    strike: float,
    iv_decimal: float,
    dte: int,
) -> tuple[float, float, float]:
    """Compute vanna, charm, volga using the true Black-Scholes forward.

    forward = S * exp(r * T)  where r = DEFAULT_R
    Matches greek_grid_ingester.dart after the same fix was applied there.

    Schwab supplies no second-order greeks, so they are derived here from the
    contract's own IV and strike.

    ⚠️ USES DEFAULT_R, NOT THE TERM-MATCHED LIVE RATE. Unlike every pricing path,
    which calls get_rate_for_dte(), this hard-codes the constant. The effect on
    vanna/charm/volga is small (r enters only through the forward and the charm
    carry term), and it keeps the grid reproducible independent of the rate
    cache's state — but it does mean these values will not exactly reconcile
    against services/black_scholes.py computed at a live rate.

    Returns (0,0,0) rather than raising on any degenerate input, so one bad
    contract contributes nothing instead of aborting the cell.
    """
    if iv_decimal <= 0 or dte <= 0 or strike <= 0 or spot <= 0:
        return 0.0, 0.0, 0.0

    T = dte / 365.0
    sqrt_T = math.sqrt(T)
    sig_sqt = iv_decimal * sqrt_T
    if sig_sqt <= 1e-8:
        return 0.0, 0.0, 0.0

    # True BS forward
    f = spot * math.exp(DEFAULT_R * T)

    d1 = (math.log(f / strike) + 0.5 * iv_decimal * iv_decimal * T) / sig_sqt
    d2 = d1 - sig_sqt
    phi = math.exp(-0.5 * d1 * d1) / math.sqrt(2 * math.pi)

    # Same formulas as services/black_scholes.py, inlined rather than imported
    # to match the Dart original line-for-line. IF YOU FIX A GREEK, FIX BOTH.
    vanna = -phi * d2 / iv_decimal
    # Divide by 365 to express charm as delta-decay per calendar day,
    # matching the convention used in iv_analytics.py and greek_interpreter.py thresholds.
    charm = -phi * (2 * DEFAULT_R * T - d2 * sig_sqt) / (2 * T * sig_sqt * 365)
    # NOTE this vega omits the discount factor that bs_vega applies, so volga
    # here is very slightly larger than the black_scholes.py equivalent. A
    # deliberate match to the Dart source, immaterial at these rates.
    vega_val = f * phi * sqrt_T
    volga = (vega_val * d1 * d2 / iv_decimal) if abs(iv_decimal) > 1e-8 else 0.0

    return vanna, charm, volga


@dataclass
class GridCell:
    strike_band: StrikeBand
    expiry_bucket: ExpiryBucket
    strike: float           # median strike
    expiry_date:Optional[datetime]
    delta:Optional[float]
    gamma:Optional[float]
    vega:Optional[float]
    theta:Optional[float]
    iv:Optional[float]        # decimal (e.g. 0.21)
    vanna:Optional[float]
    charm:Optional[float]
    volga:Optional[float]
    open_interest:Optional[int]
    volume:Optional[int]
    contract_count: int


# Collects contracts into one cell, then reduces them in to_cell(). Kept as a
# mutable accumulator rather than a list comprehension because each contract
# contributes to eight separate series with different admission rules.
class _CellAccumulator:
    def __init__(self):
        self.deltas: list[float] = []
        self.gammas: list[float] = []
        self.vegas: list[float] = []
        self.thetas: list[float] = []
        self.ivs: list[float] = []
        self.vannas: list[float] = []
        self.charms: list[float] = []
        self.volgas: list[float] = []
        self.strikes: list[float] = []
        self.ois: list[int] = []
        self.vols: list[int] = []
        self.nearest_expiry:Optional[datetime] = None

    def add(self, contract: dict, expiry: datetime, spot: float, include_delta: bool = True) -> None:
        delta = float(contract.get("delta", 0))
        gamma = float(contract.get("gamma", 0))
        vega = float(contract.get("vega", 0))
        theta = float(contract.get("theta", 0))
        iv_pct = float(contract.get("volatility", contract.get("impliedVolatility", 0)))
        strike = float(contract.get("strikePrice", 0))
        oi = int(contract.get("openInterest", 0))
        vol = int(contract.get("totalVolume", 0))
        dte = int(contract.get("daysToExpiration", 0))

        # ZERO IS TREATED AS MISSING for every greek — a Schwab convention (see
        # the extractor family in jobs/common.py). Consequence: a genuinely
        # zero-gamma deep-OTM contract contributes nothing to the gamma median
        # rather than pulling it down, so cell medians are computed only over
        # contracts that actually reported a value.
        #
        # include_delta is False for puts — see the module header.
        if include_delta and abs(delta) > 0:
            self.deltas.append(delta)
        if abs(gamma) > 0:
            self.gammas.append(gamma)
        if abs(vega) > 0:
            self.vegas.append(vega)
        if abs(theta) > 0:
            self.thetas.append(theta)
        # PERCENT -> DECIMAL conversion boundary. Schwab reports percent; the
        # stored cell and the second-order approximation below both want decimals.
        if iv_pct > 0:
            self.ivs.append(iv_pct / 100)  # store as decimal
        # These three are appended UNCONDITIONALLY, unlike the greeks above, so
        # contract_count (len(strikes)) counts every contract in the cell — not
        # just those with usable greeks. A cell can therefore have a high
        # contract_count and a null gamma.
        self.strikes.append(strike)
        self.ois.append(oi)
        self.vols.append(vol)

        # Second-order greeks (same rough approximation as Dart)
        iv_dec = iv_pct / 100
        if iv_dec > 0 and dte > 0 and strike > 0:
            vanna, charm, volga = _second_order_approx(spot, strike, iv_dec, dte)
            self.vannas.append(vanna)
            self.charms.append(charm)
            self.volgas.append(volga)

        # NEAREST expiry within the bucket, not the median or the range. A
        # bucket spans a span of dates, and the soonest one is what dominates the
        # cell's near-term behaviour.
        if self.nearest_expiry is None or expiry < self.nearest_expiry:
            self.nearest_expiry = expiry

    def to_cell(self, band: StrikeBand, bucket: ExpiryBucket) -> GridCell:
        return GridCell(
            strike_band=band,
            expiry_bucket=bucket,
            strike=_median(self.strikes),
            expiry_date=self.nearest_expiry,
            delta=_median(self.deltas) if self.deltas else None,
            gamma=_median(self.gammas) if self.gammas else None,
            vega=_median(self.vegas) if self.vegas else None,
            theta=_median(self.thetas) if self.thetas else None,
            iv=_median(self.ivs) if self.ivs else None,
            vanna=_median(self.vannas) if self.vannas else None,
            charm=_median(self.charms) if self.charms else None,
            volga=_median(self.volgas) if self.volgas else None,
            # SUMMED, not medianed — open interest and volume are additive, and
            # the cell's total is the meaningful quantity. Everything above uses
            # medians because greeks are intensive properties, not extensive ones.
            open_interest=sum(self.ois) if self.ois else None,
            volume=sum(self.vols) if self.vols else None,
            contract_count=len(self.strikes),
        )


def ingest(chain: dict, obs_date:Optional[datetime] = None) -> list[GridCell]:
    """Aggregate a Schwab options chain into grid cells.

    Matches GreekGridIngester.ingest() exactly.

    Args:
        chain: Schwab options chain dict.
        obs_date: Observation date (defaults to today UTC).

    Returns:
        List of GridCell objects (one per non-empty (StrikeBand, ExpiryBucket) pair).
    """
    chain = normalize_chain(chain)
    # Spot is required: every band assignment is relative to it, so without a
    # valid spot the whole grid would be one arbitrary band.
    spot = float(chain.get("underlyingPrice", 0))
    if spot <= 0:
        return []

    # Callers pass an explicit obs_date so every cell in a run is computed
    # against ONE instant; the fallback truncates to UTC midnight.
    if obs_date is None:
        now = datetime.now(timezone.utc)
        obs_date = datetime(now.year, now.month, now.day, tzinfo=timezone.utc)

    accumulators: dict[tuple[StrikeBand, ExpiryBucket], _CellAccumulator] = {}

    for exp in chain.get("expirations", []):
        dte = int(exp.get("dte", 0))
        bucket = classify_expiry_bucket(dte)

        # Parse expiry date
        raw_date = exp.get("expirationDate", "")
        date_str = raw_date.split(":")[0].strip() if ":" in raw_date else raw_date
        # Falls back to obs_date + dte when the expiration string is malformed
        # or absent — an approximation, but it keeps the cell rather than losing
        # every contract in that expiry.
        try:
            expiry = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
        except Exception:
            expiry = obs_date + timedelta(days=dte)

        # Calls and puts are aggregated together per band/bucket for all greeks
        # except delta: put delta is negative and would cancel call delta, producing
        # a meaningless median. Only call deltas (0–1 range) are collected.
        for c in exp.get("calls", []):
            strike = float(c.get("strikePrice", 0))
            moneyness_pct = (strike - spot) / spot * 100
            band = classify_strike_band(moneyness_pct)
            key = (band, bucket)
            if key not in accumulators:
                accumulators[key] = _CellAccumulator()
            accumulators[key].add(c, expiry, spot, include_delta=True)

        for c in exp.get("puts", []):
            strike = float(c.get("strikePrice", 0))
            moneyness_pct = (strike - spot) / spot * 100
            band = classify_strike_band(moneyness_pct)
            key = (band, bucket)
            if key not in accumulators:
                accumulators[key] = _CellAccumulator()
            accumulators[key].add(c, expiry, spot, include_delta=False)

    # Only NON-EMPTY (band, bucket) pairs are returned — accumulators are created
    # lazily on first contact — so a thin chain yields fewer than 25 cells rather
    # than a matrix padded with nulls. Order follows dict insertion, i.e. the
    # order contracts were encountered, NOT band/bucket order; consumers that
    # want a sorted grid must sort it themselves.
    return [acc.to_cell(band, bucket) for (band, bucket), acc in accumulators.items()]
