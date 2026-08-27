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
#
# THE MODEL LADDER, and why each rung exists:
#
#   1. BLACK-SCHOLES at the quoted IV. The baseline. By construction it nearly
#      reproduces the market price at that strike, so on its own it can find no
#      edge at all — its role is to be the reference the others are read against.
#
#   2. SABR. Re-prices using a SMILE-CONSISTENT vol at this strike rather than
#      the quoted one. This is where wing options start to differ: a strike
#      whose quoted IV sits off the fitted smile is priced against where the
#      rest of the surface says it should be.
#
#   3. HESTON, when a reliable calibration exists. A full stochastic-vol price
#      rather than a vol substituted into Black-Scholes, so it captures the term
#      structure of vol that SABR (fitted per-slice) cannot see.
#
# `model_fair_value` is Heston when available, otherwise the SABR result plus a
# first-order correction. `heston_fair_value` being non-None is what tells a
# caller which rung was actually used.
#
# EDGE SIGN CONVENTION: positive = the model prices it ABOVE the broker's mid =
# potentially cheap to buy. Identical convention to contract_opportunity's
# edge_bps, so the two are directly comparable.
#
# THE EDGE IS ONLY AS GOOD AS THE INPUT IV. That is what the computed_iv check
# at the bottom is for: it back-solves IV from the broker's own mid and compares
# it against the IV the broker reported. A large gap means the two disagree —
# stale IV field, wide or crossed market — and any edge computed from them rests
# on inconsistent inputs. The check reports; it does not veto.

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
    # Term-matched live rate unless the caller supplies one. The tenor LABEL is
    # replaced with "override" when an explicit r differs from the live value,
    # so a stored valuation records where its rate came from. (A caller passing
    # a rate that coincidentally equals the live one keeps the real label —
    # harmless, since the number is identical either way.)
    live_rate, rate_tenor = get_rate_for_dte(days_to_expiry)
    r = r if r is not None else live_rate
    rate_tenor = rate_tenor if r == live_rate else "override"

    # Guard: zero DTE or zero IV → return broker mid unchanged
    # Returns the mid as every model value with edge 0.0 — an explicit "no
    # opinion" rather than an error. Correct: with no time or no vol there is
    # nothing for a model to disagree with the market about, and returning the
    # mid keeps every downstream consumer working without a null check.
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
    # Calibrated shape parameters when the caller supplies them, otherwise
    # generic equity defaults (ρ=−0.7, ν=0.40). Passing the ticker's own fitted
    # values is the single biggest accuracy improvement available for a wing
    # strike — the defaults describe "a typical equity", not this one.
    sabr_rho = calibrated_rho if calibrated_rho is not None else SABR_RHO
    sabr_nu = calibrated_nu if calibrated_nu is not None else SABR_NU
    # α is SEEDED FROM THE QUOTED IV rather than fitted, so the SABR curve is
    # pinned to pass through this option's own vol at the money and ρ/ν only
    # bend it around that anchor. This is a per-contract adjustment, NOT a
    # surface fit — that is what services/sabr_calibrator.py does.
    alpha = sabr_alpha(implied_vol, F, SABR_BETA)
    sabr_vol_raw = sabr_iv(F=F, K=strike, T=T, alpha=alpha, beta=SABR_BETA, rho=sabr_rho, nu=sabr_nu)
    # Clamped to [1%, 500%]. sabr_iv returns 0.0 for degenerate parameters and
    # can blow up as |ρ| → 1, so this keeps an unusable vol from producing a
    # confidently wrong price. A clamped value here means the SABR rung should
    # not be trusted for this strike.
    sabr_vol_ = max(FV_SABR_VOL_MIN, min(FV_SABR_VOL_MAX, sabr_vol_raw))
    sabr_val = bs_price(F, strike, T, r, sabr_vol_, is_call)

    # 3a. Heston price — used as model_fair_value when calibrated params available
    heston_val:Optional[float] = None
    if heston_params is not None:
        heston_val = heston_price(F, strike, T, r, heston_params, is_call)

    # 3b. Fallback: first-order SABR + heston correction
    # Greeks are computed at the SABR vol, not the quoted IV, so they describe
    # the model's view of the contract rather than the market's. Always computed
    # — even when Heston supersedes the price — because the caller wants
    # vanna/charm/volga regardless of which rung won.
    vanna = bs_vanna(F, strike, T, sabr_vol_, is_call)
    vomma = bs_vomma(F, strike, T, r, sabr_vol_, is_call)
    charm = bs_charm(F, strike, T, r, sabr_vol_, is_call)
    # First-order Taylor adjustment for stochastic vol, using generic κ/ξ/ρ.
    # Floored at zero — the correction is an approximation and can overshoot
    # negative on deep-OTM contracts whose value is already near zero.
    heston_delta = heston_correction(T, vanna, vomma)
    sabr_corrected = max(0.0, sabr_val + heston_delta)

    # THE LADDER RESOLVES HERE. A real Heston price wins whenever one exists;
    # otherwise the corrected SABR value stands in. Callers distinguish the two
    # cases by whether heston_fair_value is None.
    model_price = heston_val if heston_val is not None else sabr_corrected

    # Basis points of the mid, not dollars, so a $0.40 option and a $40 option
    # are comparable. The $0.001 floor avoids dividing by a near-zero mid, where
    # any absolute difference would produce an enormous meaningless edge.
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
            # Seeding Newton with the broker's own IV means it usually converges
            # in one or two iterations when the quote is self-consistent — and
            # when it does NOT converge quickly, that is itself evidence the
            # price and the IV disagree.
            initial_guess=implied_vol,  # use Schwab IV as seed for fast convergence
        )
        if computed_iv is not None:
            # Expressed in VOL POINTS (0.5 = half a vol point), the unit these
            # discrepancies are naturally read in. Three bands follow:
            #   < 0.5 pts  clean quote
            #   < 2.0 pts  minor — stale quote or wide spread
            #   >= 2.0     significant — treat the edge with suspicion
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
                    # Worth stating explicitly in the note: the edge above was
                    # computed from the BROKER's IV, not the back-solved one. The
                    # check is advisory — it never changes the model price.
                    f"Edge calculation uses Schwab IV."
                )
        else:
            # bs_implied_vol returned None: the mid sits outside no-arbitrage
            # bounds, or the solver failed. Usually a crossed or stale book.
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
