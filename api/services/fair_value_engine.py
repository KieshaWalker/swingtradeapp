# =============================================================================
# services/fair_value_engine.py
# =============================================================================
# Full pricing pipeline: BS baseline → SABR smile adjustment → Heston correction.
# Exact port of FairValueEngine.compute() from fair_value_engine.dart.
#
# Model hierarchy:
#   1. Black-Scholes (baseline, using market IV)
#   2. SABR (Hagan 2002) — captures vol smile/skew
#   3. Heston correction — accounts for stochastic vol mean-reversion
#
# Edge = (ModelFairValue - BrokerMid) / BrokerMid × 10,000 bps
# Positive edge = model prices above broker mid → BUY signal.
# =============================================================================

import math
from dataclasses import dataclass

from core.constants import (
    DEFAULT_R,
    SABR_BETA,
    SABR_RHO,
    SABR_NU,
    FV_SABR_VOL_MIN,
    FV_SABR_VOL_MAX,
)
from services.black_scholes import bs_price, bs_vanna, bs_charm, bs_vomma
from services.sabr import sabr_alpha, sabr_iv
from services.heston import heston_correction


@dataclass
class FairValueResult:
    bs_fair_value: float
    sabr_fair_value: float
    model_fair_value: float
    broker_mid: float
    edge_bps: float
    sabr_vol: float
    implied_vol: float
    vanna: float | None = None
    charm: float | None = None
    volga: float | None = None


def compute(
    spot: float,
    strike: float,
    implied_vol: float,       # decimal (e.g. 0.21)
    days_to_expiry: int,
    is_call: bool,
    broker_mid: float,
    r: float = DEFAULT_R,
    calibrated_rho: float | None = None,
    calibrated_nu: float | None = None,
) -> FairValueResult:
    """Full BS → SABR → Heston pricing pipeline.

    Args:
        spot: Underlying price.
        strike: Option strike price.
        implied_vol: Market IV as decimal (e.g. 0.21 for 21%).
        days_to_expiry: Days until expiration.
        is_call: True for call, False for put.
        broker_mid: Broker mid-price (bid+ask)/2.
        r: Risk-free rate (default 4.33% SOFR).
        calibrated_rho: Surface-calibrated SABR rho (overrides -0.7 default).
        calibrated_nu: Surface-calibrated SABR nu (overrides 0.40 default).

    Returns:
        FairValueResult with all model prices and edge_bps.
    """
    # Guard: zero DTE or zero IV → return broker mid unchanged
    if days_to_expiry <= 0 or implied_vol <= 0:
        return FairValueResult(
            bs_fair_value=broker_mid,
            sabr_fair_value=broker_mid,
            model_fair_value=broker_mid,
            broker_mid=broker_mid,
            edge_bps=0.0,
            sabr_vol=implied_vol,
            implied_vol=implied_vol,
        )

    T = days_to_expiry / 365.0
    F = spot * math.exp(r * T)  # forward price

    # 1. Black-Scholes baseline (market IV)
    bs_val = bs_price(F, strike, T, r, implied_vol, is_call)

    # 2. SABR smile-adjusted vol and price
    sabr_rho = calibrated_rho if calibrated_rho is not None else SABR_RHO
    sabr_nu = calibrated_nu if calibrated_nu is not None else SABR_NU
    alpha = sabr_alpha(implied_vol, F, SABR_BETA)
    sabr_vol_raw = sabr_iv(F=F, K=strike, T=T, alpha=alpha, beta=SABR_BETA, rho=sabr_rho, nu=sabr_nu)
    sabr_vol_ = max(FV_SABR_VOL_MIN, min(FV_SABR_VOL_MAX, sabr_vol_raw))
    sabr_val = bs_price(F, strike, T, r, sabr_vol_, is_call)

    # 3. Heston correction (first-order stochastic vol expansion)
    vanna = bs_vanna(F, strike, T, sabr_vol_, is_call)
    vomma = bs_vomma(F, strike, T, r, sabr_vol_, is_call)
    charm = bs_charm(F, strike, T, r, sabr_vol_, is_call)
    heston_delta = heston_correction(T, vanna, vomma)
    model_price = max(0.0, sabr_val + heston_delta)

    edge_bps = (
        (model_price - broker_mid) / broker_mid * 10_000
        if broker_mid > 0.001
        else 0.0
    )

    return FairValueResult(
        bs_fair_value=bs_val,
        sabr_fair_value=sabr_val,
        model_fair_value=model_price,
        broker_mid=broker_mid,
        edge_bps=edge_bps,
        sabr_vol=sabr_vol_,
        implied_vol=implied_vol,
        vanna=vanna,
        charm=charm,
        volga=vomma,
    )
