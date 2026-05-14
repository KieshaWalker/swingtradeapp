from __future__ import annotations
from typing import Optional

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
from services.rate_service import get_rate_for_dte
from services.black_scholes import bs_price, bs_vanna, bs_charm, bs_vomma, bs_implied_vol
from services.sabr import sabr_alpha, sabr_iv
from services.heston import HestonParams, heston_correction, heston_price


@dataclass
class FairValueResult:
    bs_fair_value: float
    sabr_fair_value: float
    model_fair_value: float
    broker_mid: float
    edge_bps: float
    sabr_vol: float
    implied_vol: float          # Schwab-supplied IV (decimal)
    vanna:Optional[float] = None
    charm:Optional[float] = None
    volga:Optional[float] = None
    heston_fair_value:Optional[float] = None   # set when calibrated HestonParams provided
    computed_iv:Optional[float] = None         # IV back-solved from broker_mid
    iv_diff_pct:Optional[float] = None         # (computed_iv - implied_vol) × 100 in vol points
    iv_note:Optional[str] = None               # human-readable explanation for UI
    rate_used: float = 0.0                   # actual risk-free rate used in pricing (decimal)
    rate_tenor: str = ""                     # e.g. "3-month T-bill"


def compute(
    spot: float,
    strike: float,
    implied_vol: float,       # decimal (e.g. 0.21)
    days_to_expiry: int,
    is_call: bool,
    broker_mid: float,
    r:Optional[float] = None,
    calibrated_rho:Optional[float] = None,
    calibrated_nu:Optional[float] = None,
    heston_params:Optional[HestonParams] = None,
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
        heston_params: Calibrated Heston parameters. When provided, Heston
            replaces the SABR+correction pipeline as the model_fair_value.

    Returns:
        FairValueResult with all model prices and edge_bps.
    """
    live_rate, rate_tenor = get_rate_for_dte(days_to_expiry)
    r = r if r is not None else live_rate
    rate_tenor = rate_tenor if r == live_rate else "override"

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

    # 3a. Heston price — used as model_fair_value when calibrated params available
    heston_val:Optional[float] = None
    if heston_params is not None:
        heston_val = heston_price(F, strike, T, r, heston_params, is_call)

    # 3b. Fallback: first-order SABR + heston correction
    vanna = bs_vanna(F, strike, T, sabr_vol_, is_call)
    vomma = bs_vomma(F, strike, T, r, sabr_vol_, is_call)
    charm = bs_charm(F, strike, T, r, sabr_vol_, is_call)
    heston_delta = heston_correction(T, vanna, vomma)
    sabr_corrected = max(0.0, sabr_val + heston_delta)

    model_price = heston_val if heston_val is not None else sabr_corrected

    edge_bps = (
        (model_price - broker_mid) / broker_mid * 10_000
        if broker_mid > 0.001
        else 0.0
    )

    # IV comparison: back-solve IV from broker_mid and compare to Schwab's feed value
    computed_iv:Optional[float] = None
    iv_diff_pct:Optional[float] = None
    iv_note:Optional[str] = None
    if broker_mid > 0.001:
        computed_iv = bs_implied_vol(
            market_price=broker_mid,
            F=F,
            K=strike,
            T=T,
            r=r,
            is_call=is_call,
            initial_guess=implied_vol,  # use Schwab IV as seed for fast convergence
        )
        if computed_iv is not None:
            iv_diff_pct = (computed_iv - implied_vol) * 100  # in vol points
            abs_diff = abs(iv_diff_pct)
            if abs_diff < 0.5:
                iv_note = (
                    f"IV check: Schwab reports {implied_vol*100:.1f}% IV; "
                    f"our model computes {computed_iv*100:.1f}% from the market price. "
                    f"These agree within {abs_diff:.2f} vol pts — quote looks clean."
                )
            elif abs_diff < 2.0:
                direction = "higher" if iv_diff_pct > 0 else "lower"
                iv_note = (
                    f"IV check: Schwab reports {implied_vol*100:.1f}% IV; "
                    f"our model computes {computed_iv*100:.1f}% from the market price "
                    f"({abs_diff:.2f} vol pts {direction}). "
                    f"Minor discrepancy — possibly stale quote or wide spread."
                )
            else:
                direction = "higher" if iv_diff_pct > 0 else "lower"
                iv_note = (
                    f"IV check: Schwab reports {implied_vol*100:.1f}% IV; "
                    f"our model computes {computed_iv*100:.1f}% from the market price "
                    f"({abs_diff:.2f} vol pts {direction}). "
                    f"Significant divergence — Schwab IV may be stale or the spread is very wide. "
                    f"Edge calculation uses Schwab IV."
                )
        else:
            iv_note = (
                "IV check: could not back-solve IV from the market price "
                "(price outside no-arbitrage bounds or solver failed). "
                "Using Schwab-supplied IV."
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
        heston_fair_value=heston_val,
        computed_iv=computed_iv,
        iv_diff_pct=iv_diff_pct,
        iv_note=iv_note,
        rate_used=r,
        rate_tenor=rate_tenor,
    )
