from __future__ import annotations

# =============================================================================
# services/greek_grid_ingester.py
# =============================================================================
# Aggregate a Schwab options chain into (StrikeBand × ExpiryBucket) grid cells.
# Exact port of GreekGridIngester from greek_grid_ingester.dart.
#
# Second-order greeks use the same BS approximations as the Dart code,
# including the rough forward estimate: f = K * exp(iv * sqrtT * 0.5)
# =============================================================================

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from statistics import median as py_median

from core.chain_utils import normalize_chain
from core.constants import (
    GRID_APPROX_FORWARD_FACTOR,
    DEFAULT_R,
)


class StrikeBand(str, Enum):
    deep_itm = "deep_itm"
    itm = "itm"
    atm = "atm"
    otm = "otm"
    deep_otm = "deep_otm"


class ExpiryBucket(str, Enum):
    weekly = "weekly"           # dte <= 7
    near_monthly = "near_monthly"  # dte <= 30
    monthly = "monthly"         # dte <= 60
    far_monthly = "far_monthly"  # dte <= 90
    quarterly = "quarterly"     # dte > 90


def classify_strike_band(moneyness_pct: float) -> StrikeBand:
    """Classify a strike into a band based on moneyness %.
    Matches StrikeBand.fromMoneynessPct() in Dart greek_grid_models.dart.
    """
    if moneyness_pct <= -15.0:
        return StrikeBand.deep_itm
    if moneyness_pct <= -5.0:
        return StrikeBand.itm
    if moneyness_pct <= 5.0:
        return StrikeBand.atm
    if moneyness_pct <= 15.0:
        return StrikeBand.otm
    return StrikeBand.deep_otm


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
    """Compute vanna, charm, volga using the same rough forward approximation
    as greek_grid_ingester.dart _CellAccumulator.add().

    forward = K * exp(iv * sqrtT * 0.5)  (rough, not true forward)
    Uses hardcoded r=0.0433 for charm (matches Dart).
    """
    if iv_decimal <= 0 or dte <= 0 or strike <= 0:
        return 0.0, 0.0, 0.0

    T = dte / 365.0
    sqrt_T = math.sqrt(T)
    sig_sqt = iv_decimal * sqrt_T
    if sig_sqt <= 1e-8:
        return 0.0, 0.0, 0.0

    # Rough forward (matches Dart exactly)
    f = strike * math.exp(iv_decimal * sqrt_T * GRID_APPROX_FORWARD_FACTOR)

    d1 = (math.log(f / strike) + 0.5 * iv_decimal * iv_decimal * T) / sig_sqt
    d2 = d1 - sig_sqt
    phi = math.exp(-0.5 * d1 * d1) / math.sqrt(2 * math.pi)

    vanna = -phi * d2 / iv_decimal
    charm = -phi * (2 * DEFAULT_R * T - d2 * sig_sqt) / (2 * sig_sqt)
    vega_val = f * phi * sqrt_T
    volga = (vega_val * d1 * d2 / iv_decimal) if abs(iv_decimal) > 1e-8 else 0.0

    return vanna, charm, volga


@dataclass
class GridCell:
    strike_band: StrikeBand
    expiry_bucket: ExpiryBucket
    strike: float           # median strike
    delta: float | None
    gamma: float | None
    vega: float | None
    theta: float | None
    iv: float | None        # decimal (e.g. 0.21)
    vanna: float | None
    charm: float | None
    volga: float | None
    open_interest: int | None
    volume: int | None
    contract_count: int


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
        self.nearest_expiry: datetime | None = None

    def add(self, contract: dict, expiry: datetime, spot: float) -> None:
        delta = float(contract.get("delta", 0))
        gamma = float(contract.get("gamma", 0))
        vega = float(contract.get("vega", 0))
        theta = float(contract.get("theta", 0))
        iv_pct = float(contract.get("impliedVolatility", 0))
        strike = float(contract.get("strikePrice", 0))
        oi = int(contract.get("openInterest", 0))
        vol = int(contract.get("totalVolume", 0))
        dte = int(contract.get("daysToExpiration", 0))

        if abs(delta) > 0:
            self.deltas.append(delta)
        if abs(gamma) > 0:
            self.gammas.append(gamma)
        if abs(vega) > 0:
            self.vegas.append(vega)
        if abs(theta) > 0:
            self.thetas.append(theta)
        if iv_pct > 0:
            self.ivs.append(iv_pct / 100)  # store as decimal
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

        if self.nearest_expiry is None or expiry < self.nearest_expiry:
            self.nearest_expiry = expiry

    def to_cell(self, band: StrikeBand, bucket: ExpiryBucket) -> GridCell:
        return GridCell(
            strike_band=band,
            expiry_bucket=bucket,
            strike=_median(self.strikes),
            delta=_median(self.deltas) if self.deltas else None,
            gamma=_median(self.gammas) if self.gammas else None,
            vega=_median(self.vegas) if self.vegas else None,
            theta=_median(self.thetas) if self.thetas else None,
            iv=_median(self.ivs) if self.ivs else None,
            vanna=_median(self.vannas) if self.vannas else None,
            charm=_median(self.charms) if self.charms else None,
            volga=_median(self.volgas) if self.volgas else None,
            open_interest=sum(self.ois) if self.ois else None,
            volume=sum(self.vols) if self.vols else None,
            contract_count=len(self.strikes),
        )


def ingest(chain: dict, obs_date: datetime | None = None) -> list[GridCell]:
    """Aggregate a Schwab options chain into grid cells.

    Matches GreekGridIngester.ingest() exactly.

    Args:
        chain: Schwab options chain dict.
        obs_date: Observation date (defaults to today UTC).

    Returns:
        List of GridCell objects (one per non-empty (StrikeBand, ExpiryBucket) pair).
    """
    chain = normalize_chain(chain)
    spot = float(chain.get("underlyingPrice", 0))
    if spot <= 0:
        return []

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
        try:
            expiry = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
        except Exception:
            expiry = obs_date + __import__("datetime").timedelta(days=dte)

        all_contracts = list(exp.get("calls", [])) + list(exp.get("puts", []))
        for c in all_contracts:
            strike = float(c.get("strikePrice", 0))
            moneyness_pct = (strike - spot) / spot * 100
            band = classify_strike_band(moneyness_pct)
            key = (band, bucket)
            if key not in accumulators:
                accumulators[key] = _CellAccumulator()
            accumulators[key].add(c, expiry, spot)

    return [acc.to_cell(band, bucket) for (band, bucket), acc in accumulators.items()]
