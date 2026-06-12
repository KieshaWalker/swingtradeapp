from __future__ import annotations
from typing import Optional

# =============================================================================
# services/iv_analytics.py
# =============================================================================
# IV analytics: GEX, VEX, CEX, zero-gamma, gamma slope, IVR, IVP, skew.
# Exact port of IvAnalyticsService from iv_analytics_service.dart.
#
# Note on IV convention:
#   Schwab delivers impliedVolatility as a PERCENT (e.g., 21.0 = 21%).
#   The Dart code divides by 100 when computing d1/d2.
#   This service expects all chain contract IVs in PERCENT form (raw Schwab).
# =============================================================================

import logging
import math
from dataclasses import dataclass, field
from enum import Enum
from datetime import datetime, timezone
from services.rnd import RndSlice, compute_rnd_surface
from services.vvol_analytics import compute as vvol_compute
from core.chain_utils import normalize_chain

_log = logging.getLogger(__name__)

import numpy as np
from scipy.stats import norm

from core.constants import (
    DEFAULT_R,
    IV_OTM_MIN_PCT,
    IV_OTM_MAX_PCT,
    IV_MIN_DTE_PREF,
    IV_GEX_WINDOW_PCT,
    IV_GAMMA_SLOPE_BAND_PCT,
    IV_GAMMA_SLOPE_THRESHOLD_PCT,
    IV_ZERO_GAMMA_NEAR_PCT,
    IV_PUT_WALL_BAND_PCT,
    IV_MIN_HISTORY_IVR,
    IV_MIN_HISTORY_SKEW,
    IV_WINDOW_4W,
    IV_WINDOW_26W,
    IV_GEX_ELEVATED_PCT,
    IV_DEEP_LONG_GEX,
    MIN_MEANINGFUL_TOTAL_GEX_USD,
)


# ── Enums ─────────────────────────────────────────────────────────────────────

class IvRating(str, Enum):
    cheap = "cheap"
    fair = "fair"
    expensive = "expensive"
    extreme = "extreme"
    no_data = "no_data"


class GammaRegime(str, Enum):
    positive = "positive"
    negative = "negative"
    unknown = "unknown"


class VannaRegime(str, Enum):
    bullish_on_vol_crush = "bullishOnVolCrush"
    bearish_on_vol_crush = "bearishOnVolCrush"
    bullish_on_vol_spike = "bullishOnVolSpike"
    bearish_on_vol_spike = "bearishOnVolSpike"
    unknown = "unknown"


class GammaSlope(str, Enum):
    rising = "rising"
    falling = "falling"
    flat = "flat"


class IvGexSignal(str, Enum):
    classic_short_gamma = "classicShortGamma"
    regime_shift = "regimeShift"
    event_over_pos_gamma = "eventOverPosGamma"
    stable_gamma = "stableGamma"
    unknown = "unknown"


# ── Data classes ──────────────────────────────────────────────────────────────

@dataclass
class GexStrike:
    strike: float
    call_oi: float
    put_oi: float
    call_gamma: float
    put_gamma: float
        
    def dealer_gex(self, spot: float) -> float:
        """GEX in $M: (callOI*callGamma - putOI*putGamma) * 100 * spot / 1e6.
        For every $1 move in the stock price, market makers must hedge $[Result] million worth of the underlying.
        Positive Result (Long Gamma Regime): Market makers need to sell as the price goes up and buy as it goes down. This acts as a "buffer," dampening volatility and keeping the price range-bound. 
        Negative Result (Short Gamma Regime): Market makers must buy as the price goes up and sell as it goes down. This creates a feedback loop that accelerates price moves, leading to higher volatility"""
        return (self.call_oi * self.call_gamma - self.put_oi * self.put_gamma) * 100 * spot / 1_000_000


@dataclass
class SecondOrderStrike:
    strike: float
    call_oi: float
    put_oi: float
    call_vanna: float
    put_vanna: float
    call_charm: float
    put_charm: float
    call_volga: float
    put_volga: float

    def dealer_vex(self, spot: float) -> float:
        """Dealer Vanna Exposure in DOLLARS of delta per 1 vol-point IV move:
        (callOI*callVanna - putOI*putVanna) * 100 * spot.
        Per-contract vanna is stored per vol-point (see _second_order_greeks),
        so x100 contract multiplier converts to shares and x spot dollarises.
        While Gamma is the sensitivity of Delta to Price, Vanna is the sensitivity of Delta to Volatility
        If the market is in a "Long Vanna" state (positive result), and implied volatility drops (a "vol crush"),
        dealers' deltas change in a way that forces them to buy the underlying. This is often why the market rallies after a major risk event—not because the news was "good,"
        but because the drop in IV forced dealers to buy back their hedges.
        Result = +$5M: if implied volatility increases by 1 point (e.g., from 20% to 21%),
        market makers must buy $5M of the underlying to remain delta-neutral.
        Result = -$5M: if IV increases by 1 point, market makers must sell $5M."""
        return (self.call_oi * self.call_vanna - self.put_oi * self.put_vanna) * 100 * spot

    def dealer_cex(self, spot: float) -> float:
        """Dealer Charm Exposure.
        
        Call Charm: OTM call deltas decay toward 0 over time; ITM call deltas decay toward 1.00.
        Put Charm:  OTM put deltas decay toward 0 over time; ITM put deltas decay toward -1.00.

        Positive CEX: dealers' aggregate delta is growing over time (net calls dominate).
            To stay delta-neutral they must BUY the underlying each day.
            Example — Result = 20,000: market makers must buy ~20,000 shares today to remain neutral.
            This creates a passive upward drift as expiration approaches ("Charm Rally").
        Negative CEX: dealers' aggregate delta is shrinking over time (net puts dominate).
            To stay delta-neutral they must SELL the underlying each day.
        
        Weekend / OPEX effect: Charm accelerates sharply in the final days before expiration
                        (OPEX). A three-day weekend compresses three days of decay into one session,
                         producing outsized re-hedging flows on Friday afternoon or Monday morning.
           Weekend Effect" and OPEXCharm is most influential in the final days before an option expiration (OPEX).
           The "Charm Rally": In a typical "Long Gamma" environment where investors have bought puts to hedge, dealers are Short Puts.
             As those puts decay toward zero (Charm), dealers are forced to "un-hedge" by buying back the underlying. This is a major contributor to the "upward drift" often seen during expiration weeks.
           Weekend Bleed: Because Charm is a function of time ($t$), a three-day weekend can represent a massive jump in delta decay, leading to significant re-hedging flows on Monday morning (or Friday afternoon in anticipation).

        Units: DOLLARS of delta per calendar day (charm is shares/day per
        contract-share; x100 contract multiplier; x spot dollarises)."""
        return (self.call_oi * self.call_charm - self.put_oi * self.put_charm) * 100 * spot

    @property
    def dealer_volga(self) -> float:
        """Dealer Volga Exposure: dollars of vega gained/lost per 1 vol-point
        IV move (per-contract volga is $-vega per vol-point; x100 multiplier)."""
        return (self.call_oi * self.call_volga - self.put_oi * self.put_volga) * 100


@dataclass
class SkewPoint:
    strike: float
    moneyness: float  # (strike - spot) / spot * 100
    call_iv:Optional[float]
    put_iv:Optional[float]


@dataclass
class IvAnalysisResult:
    ticker: str
    current_iv: float
    iv52w_high:Optional[float]
    iv52w_low:Optional[float]
    iv_rank:Optional[float]
    iv_percentile:Optional[float]
    iv_rank_4w:Optional[float]
    iv_percentile_4w:Optional[float]
    iv_rank_26w:Optional[float]
    iv_percentile_26w:Optional[float]
    rating: IvRating
    history_days: int
    skew:Optional[float]
    skew_avg_52w:Optional[float]
    skew_z_score:Optional[float]
    skew_rr25:Optional[float]      # 25Δ risk reversal: IV(25Δp) − IV(25Δc), vol pts
    skew_bf25:Optional[float]      # 25Δ butterfly: wing avg − ATM IV, vol pts
    skew_curve: list[SkewPoint]
    term_structure: list[dict]     # [{dte, expiry, atm_iv}] ascending by DTE
    term_slope_pp:Optional[float]  # IV(~90d) − IV(front), vol pts
    term_structure_label: str      # contango / backwardation / flat / unknown
    gex_strikes: list[GexStrike]
    total_gex:Optional[float]
    max_gex_strike:Optional[float]
    put_call_ratio:Optional[float]
    second_order: list[SecondOrderStrike]
    total_vex:Optional[float]
    total_cex:Optional[float]
    total_volga:Optional[float]
    max_vex_strike:Optional[float]
    gamma_regime: GammaRegime
    vanna_regime: VannaRegime
    zero_gamma_level:Optional[float]
    spot_to_zero_gamma_pct:Optional[float]
    delta_gex:Optional[float]
    gamma_slope: GammaSlope
    iv_gex_signal: IvGexSignal
    put_wall_density:Optional[float]
    # ── New institutional-grade fields ──────────────────────────────────────────
    gex_0dte:Optional[float]          # GEX contributed solely by same-day expiries ($M)
    gex_0dte_pct:Optional[float]      # gex_0dte / |total_gex| × 100
    volatility_trigger:Optional[float]  # lowest significant positive-GEX support above ZGL
    spot_to_vt_pct:Optional[float]    # (spot − VT) / spot × 100; <0 = in transition corridor
    rnd: list[RndSlice]             # Breeden-Litzenberger density per DTE; empty if SABR fails
    # ── Vol-of-vol (SABR ν rank) ────────────────────────────────────────────────
    vvol_nu:Optional[float]           # current SABR ν for ~30 DTE slice
    vvol_rank:Optional[float]         # 0–100, mirrors IVR formula on ν series
    vvol_percentile:Optional[float]   # % of prior days with ν below today
    vvol_rating:Optional[str]         # cheap / fair / elevated / extreme
    vvol_trend:Optional[str]          # rising / falling / flat


# ── Main entry point ──────────────────────────────────────────────────────────

def analyse(
    chain: dict,          # Schwab options chain JSON (from Edge Function)
    history: list[dict],  # iv_snapshots rows, sorted ascending by date
    risk_free_rate:Optional[float] = None,
) -> IvAnalysisResult:
    """Compute all IV analytics from a Schwab chain and historical snapshots.

    Matches IvAnalyticsService.analyse() exactly.

    Args:
        chain: Schwab options chain dict (must have 'symbol', 'underlyingPrice',
               'volatility', 'expirations').
        history: List of iv_snapshot dicts from Supabase.
        risk_free_rate: Risk-free rate. If > 0.5 treated as percent and divided by 100.

    Returns:
        IvAnalysisResult with all computed analytics.
    """
    # include_zero_dte: same-day expiries feed the 0DTE GEX split; they are
    # filtered back out of ZGL / skew / RND inside their respective helpers.
    chain = normalize_chain(chain, include_zero_dte=True)

    raw_rate = risk_free_rate if risk_free_rate is not None else DEFAULT_R
    r = raw_rate / 100 if raw_rate > 0.5 else raw_rate

    ticker = chain.get("symbol", "")
    spot = float(chain.get("underlyingPrice", 0))
    expirations = chain.get("expirations", [])
    # Contract-derived ATM IV is authoritative; Schwab's chain-level volatility
    # field is a stale HV estimate that must not override real option prices.
    atm_iv = _compute_atm_iv_from_chain(expirations, spot)
    if atm_iv <= 0:
        atm_iv = float(chain.get("volatility") or 0)

    # ── IVR & IVP (52w / 26w / 4w) ────────────────────────────────────────────
    iv_rank:Optional[float] = None
    iv_percentile:Optional[float] = None
    iv_rank_4w:Optional[float] = None
    iv_percentile_4w:Optional[float] = None
    iv_rank_26w:Optional[float] = None
    iv_percentile_26w:Optional[float] = None
    iv52w_high:Optional[float] = None
    iv52w_low:Optional[float] = None
    rating = IvRating.no_data

    if len(history) >= IV_MIN_HISTORY_IVR:
        ivs = [float(s.get("atm_iv", 0)) for s in history]
        iv52w_high = max(ivs)
        iv52w_low = min(ivs)
        iv_rank, iv_percentile = _ivr_ivp(ivs, atm_iv)
        iv_rank_26w, iv_percentile_26w = _ivr_ivp(ivs[-IV_WINDOW_26W:], atm_iv)
        iv_rank_4w,  iv_percentile_4w  = _ivr_ivp(ivs[-IV_WINDOW_4W:],  atm_iv)
        rating = _rating_from_rank(iv_rank)

    # ── Skew ───────────────────────────────────────────────────────────────────
    exp = _pick_expiration(expirations)
    skew_curve = _compute_skew_curve(exp, spot) if exp else []
    skew_val = _summarise_skew(skew_curve) if exp else None

    # 25Δ risk reversal / butterfly on the same slice, anchored to that
    # slice's own interpolated ATM IV so the BF measures pure convexity.
    skew_rr25: Optional[float] = None
    skew_bf25: Optional[float] = None
    if exp:
        slice_atm = _atm_iv_for_expiration(exp, spot)
        skew_rr25, skew_bf25 = _compute_rr_bf_25d(exp, slice_atm)

    # ── Term structure ─────────────────────────────────────────────────────────
    term_structure = _compute_term_structure(expirations, spot)
    term_slope_pp, term_structure_label = _term_slope(term_structure)

    skew_avg_52w:Optional[float] = None
    skew_z_score:Optional[float] = None
    if history:
        skew_history = [float(s["skew"]) for s in history if s.get("skew") is not None]
        if len(skew_history) >= IV_MIN_HISTORY_SKEW:
            skew_avg_52w = sum(skew_history) / len(skew_history)
            if skew_val is not None:
                variance = sum((s - skew_avg_52w) ** 2 for s in skew_history) / (len(skew_history) - 1)
                std = math.sqrt(variance)
                skew_z_score = 0.0 if std < 0.001 else (skew_val - skew_avg_52w) / std

    # ── GEX ────────────────────────────────────────────────────────────────────
    gex_strikes = _compute_gex(expirations, spot)
    total_gex:Optional[float] = None
    max_gex_strike:Optional[float] = None
    put_call_ratio:Optional[float] = None

    if gex_strikes:
        total_gex = sum(g.dealer_gex(spot) for g in gex_strikes)
        max_gex_strike = max(gex_strikes, key=lambda g: abs(g.dealer_gex(spot))).strike
        total_call_oi = sum(g.call_oi for g in gex_strikes)
        total_put_oi = sum(g.put_oi for g in gex_strikes)
        if total_call_oi > 0:
            put_call_ratio = total_put_oi / total_call_oi

    # ── 0DTE vs longer-dated GEX split ─────────────────────────────────────────
    # 0DTE gamma behaves differently (intraday only); ZGL computed from longer-dated
    # strikes gives a cleaner multi-day support/resistance picture.
    exp_0dte   = [e for e in expirations if int(e.get("dte", 999)) == 0]
    exp_longer = [e for e in expirations if int(e.get("dte", 999)) > 0]

    gex_strikes_longer = _compute_gex(exp_longer, spot) if exp_longer else []

    gex_0dte:Optional[float] = None
    gex_0dte_pct:Optional[float] = None
    if exp_0dte:
        gex_strikes_0dte = _compute_gex(exp_0dte, spot)
        if gex_strikes_0dte:
            gex_0dte = sum(g.dealer_gex(spot) for g in gex_strikes_0dte)
            if total_gex is not None and abs(total_gex) >= MIN_MEANINGFUL_TOTAL_GEX_USD:
                gex_0dte_pct = gex_0dte / abs(total_gex) * 100

    # ── Second-order Greeks ────────────────────────────────────────────────────
    second_order = _compute_second_order(expirations, spot, r)
    total_vex:Optional[float] = None
    total_cex:Optional[float] = None
    total_volga:Optional[float] = None
    max_vex_strike:Optional[float] = None

    if second_order:
        total_vex = sum(s.dealer_vex(spot) for s in second_order)
        total_cex = sum(s.dealer_cex(spot) for s in second_order)
        total_volga = sum(s.dealer_volga for s in second_order)
        max_vex_strike = max(second_order, key=lambda s: abs(s.dealer_vex(spot))).strike

    # ── Regime classification ──────────────────────────────────────────────────
    gamma_regime = GammaRegime.unknown
    vanna_regime = VannaRegime.unknown
    if total_gex is not None:
        gamma_regime = GammaRegime.positive if total_gex >= 0 else GammaRegime.negative
    if total_vex is not None:
        vol_spike_env = iv_rank is not None and iv_rank < 50
        if vol_spike_env:
            # Low IV: dealers are short vanna; a vol spike forces delta adjustments
            # in the opposite direction — negative VEX becomes bullish
            vanna_regime = (VannaRegime.bullish_on_vol_spike if total_vex < 0
                            else VannaRegime.bearish_on_vol_spike)
        else:
            vanna_regime = (VannaRegime.bullish_on_vol_crush if total_vex >= 0
                            else VannaRegime.bearish_on_vol_crush)

    # ── Advanced GEX metrics ───────────────────────────────────────────────────
    # ZGL: prefer the spot-grid gamma-flip simulation (re-prices BS gamma at
    # hypothetical spot levels). Fall back to the per-strike crossing method
    # when contract data is too sparse. 0DTE excluded in both paths: intraday
    # gamma is noise for multi-day swing positioning.
    zgl_source = gex_strikes_longer if gex_strikes_longer else gex_strikes
    zero_gamma_level = _compute_gamma_flip(expirations, spot, r)
    if zero_gamma_level is None:
        zero_gamma_level = _compute_zero_gamma_level(zgl_source, spot)
    spot_to_zero_gamma_pct:Optional[float] = None
    if zero_gamma_level is not None and spot > 0:
        spot_to_zero_gamma_pct = (spot - zero_gamma_level) / spot * 100

    # Volatility Trigger — last meaningful positive-GEX support wall above ZGL.
    # The VT/ZGL corridor is the "transition zone" where bearish feedback loops
    # are latent but not yet ignited (SpotGamma methodology).
    volatility_trigger:Optional[float] = None
    spot_to_vt_pct:Optional[float] = None
    if zero_gamma_level is not None and spot > 0:
        volatility_trigger = _compute_volatility_trigger(zgl_source, spot, zero_gamma_level)
        if volatility_trigger is not None:
            spot_to_vt_pct = (spot - volatility_trigger) / spot * 100

    # Day-over-day ΔGEX. The snapshot endpoint upserts on every chain load, so
    # history may already contain a row for TODAY — comparing against it would
    # yield intraday drift, not the day-over-day change this field promises.
    # Baseline = most recent row dated strictly before today.
    delta_gex:Optional[float] = None
    if total_gex is not None:
        today_iso = datetime.now().date().isoformat()
        with_gex = [
            s for s in history
            if s.get("total_gex") is not None
            and str(s.get("date", ""))[:10] < today_iso
        ]
        if with_gex:
            delta_gex = total_gex - float(with_gex[-1]["total_gex"])

    gamma_slope = _compute_gamma_slope(gex_strikes, spot)
    iv_gex_signal = _compute_iv_gex_signal(gamma_regime, iv_rank)
    put_wall_density = _compute_put_wall_density(gex_strikes, spot)
    rnd_slices = compute_rnd_surface(expirations=expirations, spot=spot, r=r)

    # ── Vol-of-vol rank ────────────────────────────────────────────────────────
    # Pick the ~30 DTE RND slice's SABR ν as today's vol-of-vol reading.
    # Use vvol_nu from prior iv_snapshots rows as the historical ν series.
    vvol_nu:Optional[float] = None
    vvol_rank_val:Optional[float] = None
    vvol_percentile_val:Optional[float] = None
    vvol_rating_val:Optional[str] = None
    vvol_trend_val:Optional[str] = None
    if rnd_slices:
        atm_slice = min(rnd_slices, key=lambda s: abs(s.dte - 30))
        nu_current = atm_slice.sabr_nu
        nu_history = [float(h["vvol_nu"]) for h in history if h.get("vvol_nu") is not None]
        if nu_current > 0:
            vvol_result = vvol_compute(nu_current, nu_history)
            if vvol_result is not None:
                vvol_nu = vvol_result.nu_current
                vvol_rank_val = vvol_result.vvol_rank
                vvol_percentile_val = vvol_result.vvol_percentile
                vvol_rating_val = vvol_result.vvol_rating
                vvol_trend_val = vvol_result.nu_trend

    return IvAnalysisResult(
        ticker=ticker,
        current_iv=atm_iv,
        iv52w_high=iv52w_high,
        iv52w_low=iv52w_low,
        iv_rank=iv_rank,
        iv_percentile=iv_percentile,
        iv_rank_4w=iv_rank_4w,
        iv_percentile_4w=iv_percentile_4w,
        iv_rank_26w=iv_rank_26w,
        iv_percentile_26w=iv_percentile_26w,
        rating=rating,
        history_days=len(history),
        skew=skew_val,
        skew_avg_52w=skew_avg_52w,
        skew_z_score=skew_z_score,
        skew_rr25=skew_rr25,
        skew_bf25=skew_bf25,
        skew_curve=skew_curve,
        term_structure=term_structure,
        term_slope_pp=term_slope_pp,
        term_structure_label=term_structure_label,
        gex_strikes=gex_strikes,
        total_gex=total_gex,
        max_gex_strike=max_gex_strike,
        put_call_ratio=put_call_ratio,
        second_order=second_order,
        total_vex=total_vex,
        total_cex=total_cex,
        total_volga=total_volga,
        max_vex_strike=max_vex_strike,
        gamma_regime=gamma_regime,
        vanna_regime=vanna_regime,
        zero_gamma_level=zero_gamma_level,
        spot_to_zero_gamma_pct=spot_to_zero_gamma_pct,
        delta_gex=delta_gex,
        gamma_slope=gamma_slope,
        iv_gex_signal=iv_gex_signal,
        put_wall_density=put_wall_density,
        gex_0dte=gex_0dte,
        gex_0dte_pct=gex_0dte_pct,
        volatility_trigger=volatility_trigger,
        spot_to_vt_pct=spot_to_vt_pct,
        rnd=rnd_slices,
        vvol_nu=vvol_nu,
        vvol_rank=vvol_rank_val,
        vvol_percentile=vvol_percentile_val,
        vvol_rating=vvol_rating_val,
        vvol_trend=vvol_trend_val,
    )


# ── ATM IV from chain contracts ───────────────────────────────────────────────

def _atm_iv_for_expiration(exp: dict, spot: float) -> float:
    """Strike-interpolated ATM IV (%) for one expiration; 0.0 if no IV data.

    Linearly interpolates the call/put-averaged IV between the two strikes
    straddling spot. The old nearest-strike pick made the ATM IV series jump
    discretely every time spot crossed a strike midpoint, injecting noise into
    IVR/IVP; interpolation removes that artefact.
    """
    strike_ivs: dict[float, list[float]] = {}
    for side in ("calls", "puts"):
        for c in exp.get(side, []):
            iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
            if iv > 0:
                strike_ivs.setdefault(float(c["strikePrice"]), []).append(iv)
    if not strike_ivs:
        return 0.0

    mean_iv = {k: sum(v) / len(v) for k, v in strike_ivs.items()}
    strikes = sorted(mean_iv)
    below = [k for k in strikes if k <= spot]
    above = [k for k in strikes if k >= spot]

    if below and above:
        k_lo, k_hi = below[-1], above[0]
        if k_hi == k_lo:
            return mean_iv[k_lo]
        t = (spot - k_lo) / (k_hi - k_lo)
        return mean_iv[k_lo] * (1 - t) + mean_iv[k_hi] * t
    # Spot outside the listed strike range — use the nearest edge strike
    return mean_iv[strikes[0]] if above else mean_iv[strikes[-1]]


def _compute_atm_iv_from_chain(expirations: list[dict], spot: float) -> float:
    """Compute ATM IV from near-ATM contract IVs when the chain-level volatility field is 0.

    Uses the same expiration picker logic but falls back to the shortest DTE if
    no preferred expiration exists.  Returns 0.0 if no valid IV data found.
    """
    if not expirations or spot <= 0:
        return 0.0
    exp = _pick_expiration(expirations)
    if not exp:
        return 0.0
    return _atm_iv_for_expiration(exp, spot)


# ── Expiration picker ─────────────────────────────────────────────────────────

def _pick_expiration(expirations: list[dict]) ->Optional[dict]:
    if not expirations:
        return None
    preferred = [e for e in expirations if int(e.get("dte", 0)) >= IV_MIN_DTE_PREF]
    if preferred:
        return min(preferred, key=lambda e: int(e.get("dte", 0)))
    # Never fall back to a 0DTE slice — its IVs are too unstable for skew/ATM
    nonzero = [e for e in expirations if int(e.get("dte", 0)) >= 1]
    if nonzero:
        return min(nonzero, key=lambda e: int(e.get("dte", 0)))
    return min(expirations, key=lambda e: int(e.get("dte", 0)))


# ── Skew ──────────────────────────────────────────────────────────────────────

def _compute_skew_curve(exp: dict, spot: float) -> list[SkewPoint]:
    call_map: dict[float, float] = {}
    put_map: dict[float, float] = {}

    for c in exp.get("calls", []):
        iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
        if iv > 0:
            call_map[float(c["strikePrice"])] = iv

    for p in exp.get("puts", []):
        iv = float(p.get("volatility") or p.get("impliedVolatility") or 0)
        if iv > 0:
            put_map[float(p["strikePrice"])] = iv

    all_strikes = sorted(set(call_map) | set(put_map))
    points = []
    for strike in all_strikes:
        moneyness = (strike - spot) / spot * 100
        if abs(moneyness) > IV_OTM_MAX_PCT * 100:
            continue
        points.append(SkewPoint(
            strike=strike,
            moneyness=moneyness,
            call_iv=call_map.get(strike),
            put_iv=put_map.get(strike),
        ))
    return points


def _compute_rr_bf_25d(
    exp: dict, atm_iv: float
) -> tuple[Optional[float], Optional[float]]:
    """25Δ risk reversal and butterfly — the institutional skew quotes.

    RR25 = IV(25Δ put) − IV(25Δ call)   (positive = downside fear premium)
    BF25 = (IV(25Δ put) + IV(25Δ call)) / 2 − ATM IV   (smile convexity)

    Uses Schwab contract deltas to locate the wings, so the measure is
    moneyness-standardised and comparable across tickers and vol levels —
    unlike the fixed ±% OTM band used by the legacy skew summary.

    Returns (None, None) when no quote lands within 0.10 of the 25Δ target.
    """
    best_call: Optional[tuple[float, float]] = None  # (delta, iv)
    best_put: Optional[tuple[float, float]] = None

    for c in exp.get("calls", []):
        iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
        delta = float(c.get("delta") or 0)
        if iv <= 0 or not (0.05 <= delta <= 0.50):
            continue
        if best_call is None or abs(delta - 0.25) < abs(best_call[0] - 0.25):
            best_call = (delta, iv)

    for p in exp.get("puts", []):
        iv = float(p.get("volatility") or p.get("impliedVolatility") or 0)
        delta = float(p.get("delta") or 0)
        if iv <= 0 or not (-0.50 <= delta <= -0.05):
            continue
        if best_put is None or abs(delta + 0.25) < abs(best_put[0] + 0.25):
            best_put = (delta, iv)

    if best_call is None or best_put is None:
        return None, None
    if abs(best_call[0] - 0.25) > 0.10 or abs(best_put[0] + 0.25) > 0.10:
        return None, None  # nearest quotes too far from 25Δ to be meaningful

    rr25 = best_put[1] - best_call[1]
    bf25 = (best_put[1] + best_call[1]) / 2 - atm_iv if atm_iv > 0 else None
    return rr25, bf25


# ── Term structure ────────────────────────────────────────────────────────────

def _compute_term_structure(expirations: list[dict], spot: float) -> list[dict]:
    """ATM IV per expiration: [{dte, expiry, atm_iv}, ...] ascending by DTE.

    0DTE is excluded (gamma-driven IV prints distort the curve's front end).
    """
    points: list[dict] = []
    for exp in sorted(expirations, key=lambda e: int(e.get("dte", 0))):
        dte = int(exp.get("dte", 0))
        if dte <= 0:
            continue
        iv = _atm_iv_for_expiration(exp, spot)
        if iv > 0:
            points.append({
                "dte": dte,
                "expiry": str(exp.get("expirationDate", "")),
                "atm_iv": iv,
            })
    return points


def _term_slope(points: list[dict]) -> tuple[Optional[float], str]:
    """(slope in vol points, label) for the term structure.

    Slope = IV(slice nearest 90 DTE) − IV(front slice ≥ 5 DTE).
    > +1pp → contango (normal markets: near-dated vol cheaper than far-dated),
    < −1pp → backwardation (stress or imminent event: near-dated vol bid over
    far-dated), else flat.
    """
    if len(points) < 2:
        return None, "unknown"
    front = next((p for p in points if p["dte"] >= 5), points[0])
    backs = [p for p in points if p["dte"] > front["dte"]]
    if not backs:
        return None, "unknown"
    back = min(backs, key=lambda p: abs(p["dte"] - 90))
    slope = back["atm_iv"] - front["atm_iv"]
    if slope > 1.0:
        return slope, "contango"
    if slope < -1.0:
        return slope, "backwardation"
    return slope, "flat"


def _summarise_skew(curve: list[SkewPoint]) ->Optional[float]:
    # 1. Use filter/list comprehensions with clear boundaries
    # Note: Ensure IV_OTM_MIN_PCT is defined in your scope
    otm_puts = [p.put_iv for p in curve if p.moneyness < -IV_OTM_MIN_PCT * 100 and p.put_iv is not None]
    otm_calls = [p.call_iv for p in curve if p.moneyness > IV_OTM_MIN_PCT * 100 and p.call_iv is not None]

    # 2. Guard clause for empty lists to prevent DivisionByZero
    if not otm_puts or not otm_calls:
        return None

    # 3. Calculate averages and return the spread
    avg_put_iv = sum(otm_puts) / len(otm_puts)
    avg_call_iv = sum(otm_calls) / len(otm_calls)
    
    return avg_put_iv - avg_call_iv


# ── GEX ───────────────────────────────────────────────────────────────────────

def _compute_gex(expirations: list[dict], spot: float) -> list[GexStrike]:
    calls_by_strike: dict[float, list[dict]] = {}
    puts_by_strike: dict[float, list[dict]] = {}

    for exp in expirations:
        for c in exp.get("calls", []):
            k = float(c["strikePrice"])
            calls_by_strike.setdefault(k, []).append(c)
        for p in exp.get("puts", []):
            k = float(p["strikePrice"])
            puts_by_strike.setdefault(k, []).append(p)

    all_strikes = sorted(set(calls_by_strike) | set(puts_by_strike))
    results = []
    for strike in all_strikes:
        if abs(strike - spot) / spot > IV_GEX_WINDOW_PCT:
            continue

        calls = calls_by_strike.get(strike, [])
        puts = puts_by_strike.get(strike, [])

        call_oi = sum(float(c.get("openInterest", 0)) for c in calls)
        put_oi = sum(float(p.get("openInterest", 0)) for p in puts)

        if call_oi == 0 and put_oi == 0:
            continue

        call_gamma = 0.0
        if call_oi > 0:
            call_gamma = sum(float(c.get("gamma", 0)) * float(c.get("openInterest", 0)) for c in calls) / call_oi

        put_gamma = 0.0
        if put_oi > 0:
            put_gamma = sum(float(p.get("gamma", 0)) * float(p.get("openInterest", 0)) for p in puts) / put_oi

        gex_strike = GexStrike(strike=strike, call_oi=call_oi, put_oi=put_oi,
                               call_gamma=call_gamma, put_gamma=put_gamma)
        results.append(gex_strike)
    return results


# ── Zero Gamma Level ──────────────────────────────────────────────────────────

def _compute_zero_gamma_level(gex_strikes: list[GexStrike], spot: float) ->Optional[float]:
    if not gex_strikes:
        return None
    sorted_strikes = sorted(gex_strikes, key=lambda g: g.strike)
    for i in range(len(sorted_strikes) - 1):
        g_a = sorted_strikes[i].dealer_gex(spot)
        g_b = sorted_strikes[i + 1].dealer_gex(spot)
        if g_a <= 0 and g_b >= 0:
            dg = g_b - g_a
            if dg == 0:
                return (sorted_strikes[i].strike + sorted_strikes[i + 1].strike) / 2
            t = -g_a / dg
            return sorted_strikes[i].strike + t * (sorted_strikes[i + 1].strike - sorted_strikes[i].strike)

    # No crossing — return nearest-to-zero GEX strike within ±10% of spot
    near = [s for s in sorted_strikes if abs(s.strike - spot) / spot < IV_ZERO_GAMMA_NEAR_PCT]
    if not near:
        return None
    return min(near, key=lambda s: abs(s.dealer_gex(spot))).strike


# ── Gamma Flip (spot-grid simulation) ────────────────────────────────────────

def _compute_gamma_flip(
    expirations: list[dict], spot: float, r: float
) -> Optional[float]:
    """Zero-gamma level via spot-level simulation (institutional method).

    The per-strike crossing method asks "at which strike does today's GEX
    profile change sign" — but dealer gamma at every strike CHANGES as spot
    moves, so the honest question is "at what spot level does NET dealer gamma
    flip sign". This re-prices Black-Scholes gamma for every contract across a
    grid of hypothetical spot levels and locates the sign change of
    Σ(callOI·Γ − putOI·Γ), interpolating linearly between grid points.

    0DTE contracts are excluded: their gamma exists only intraday and pollutes
    the multi-day flip level used for swing positioning.

    Returns the flip level nearest to spot, or None if net gamma never
    changes sign within ±IV_ZERO_GAMMA_NEAR_PCT of spot.
    """
    if spot <= 0:
        return None

    Ks: list[float] = []
    Ts: list[float] = []
    sigs: list[float] = []
    ws: list[float] = []  # +callOI / -putOI (dealer long calls, short puts)

    for exp in expirations:
        dte = int(exp.get("dte", 0))
        if dte <= 0:
            continue
        T = dte / 365.0
        for side, sign in (("calls", 1.0), ("puts", -1.0)):
            for c in exp.get(side, []):
                oi = float(c.get("openInterest", 0))
                iv = float(c.get("volatility") or c.get("impliedVolatility") or 0)
                k = float(c.get("strikePrice", 0))
                if oi <= 0 or iv <= 0 or k <= 0:
                    continue
                if abs(k - spot) / spot > IV_GEX_WINDOW_PCT:
                    continue
                Ks.append(k)
                Ts.append(T)
                sigs.append(iv / 100.0)
                ws.append(sign * oi)

    if len(Ks) < 4:
        return None

    K = np.asarray(Ks)
    T = np.asarray(Ts)
    sig = np.asarray(sigs)
    w = np.asarray(ws)
    sig_sqt = sig * np.sqrt(T)

    levels = np.linspace(
        spot * (1 - IV_ZERO_GAMMA_NEAR_PCT),
        spot * (1 + IV_ZERO_GAMMA_NEAR_PCT),
        41,
    )
    net = np.empty(len(levels))
    for i, s_level in enumerate(levels):
        d1 = (np.log(s_level / K) + (r + 0.5 * sig * sig) * T) / sig_sqt
        gamma = norm.pdf(d1) / (s_level * sig_sqt)
        net[i] = float(np.dot(w, gamma))

    crossings: list[float] = []
    for i in range(len(levels) - 1):
        a, b = net[i], net[i + 1]
        if a == 0.0:
            crossings.append(float(levels[i]))
        elif (a < 0 <= b) or (a > 0 >= b):
            t = a / (a - b)
            crossings.append(float(levels[i] + t * (levels[i + 1] - levels[i])))

    if not crossings:
        return None
    return min(crossings, key=lambda x: abs(x - spot))


# ── Volatility Trigger ───────────────────────────────────────────────────────

def _compute_volatility_trigger(
    gex_strikes: list[GexStrike], spot: float, zgl: float
) ->Optional[float]:
    """Derive the Volatility Trigger — lowest significant positive-GEX support above ZGL.

    Scans strikes between ZGL and spot. The VT is the floor of meaningful positive
    gamma support: once spot breaches VT but stays above ZGL, the market is in the
    'transition corridor' where bearish feedback loops are latent but not ignited.

    Returns the lowest strike with dealer_gex >= 5% of total positive GEX in the
    ZGL-to-spot zone, or None if no meaningful support exists.
    """
    if not gex_strikes or spot <= 0:
        return None

    # Collect strikes between ZGL and spot with positive dealer GEX
    support_strikes = sorted(
        [s for s in gex_strikes if zgl < s.strike <= spot and s.dealer_gex(spot) > 0],
        key=lambda s: s.strike,
    )
    if not support_strikes:
        return None

    total_pos_gex = sum(s.dealer_gex(spot) for s in support_strikes)
    if total_pos_gex <= 0:
        return None

    threshold = total_pos_gex * 0.05  # 5% significance floor
    for s in support_strikes:
        if s.dealer_gex(spot) >= threshold:
            return s.strike  # lowest strike with meaningful positive GEX support

    return support_strikes[0].strike  # all tiny, but best available floor


# ── Gamma Slope ───────────────────────────────────────────────────────────────

def _compute_gamma_slope(gex_strikes: list[GexStrike], spot: float) -> GammaSlope:
    band = sorted(
        [s for s in gex_strikes if abs(s.strike - spot) / spot < IV_GAMMA_SLOPE_BAND_PCT],
        key=lambda s: s.strike,
    )
    if len(band) < 3:
        return GammaSlope.flat

    mid = len(band) // 2
    lower = band[:mid]
    upper = band[mid:]

    avg_lower = sum(s.dealer_gex(spot) for s in lower) / len(lower)
    avg_upper = sum(s.dealer_gex(spot) for s in upper) / len(upper)
    diff = avg_upper - avg_lower

    all_abs = [abs(s.dealer_gex(spot)) for s in gex_strikes]
    max_abs = max(all_abs) if all_abs else 1.0
    threshold = max_abs * IV_GAMMA_SLOPE_THRESHOLD_PCT

    if diff > threshold:
        return GammaSlope.rising
    if diff < -threshold:
        return GammaSlope.falling
    return GammaSlope.flat


# ── IV / GEX Signal ───────────────────────────────────────────────────────────

def _compute_iv_gex_signal(gamma_regime: GammaRegime, iv_rank:Optional[float]) -> IvGexSignal:
    if gamma_regime == GammaRegime.unknown:
        return IvGexSignal.unknown
    if iv_rank is None:
        return IvGexSignal.unknown
    iv_elevated = iv_rank >= IV_GEX_ELEVATED_PCT
    if gamma_regime == GammaRegime.negative:
        return IvGexSignal.classic_short_gamma if iv_elevated else IvGexSignal.regime_shift
    return IvGexSignal.event_over_pos_gamma if iv_elevated else IvGexSignal.stable_gamma


# ── Put Wall Density ───────────────────────────────────────────────────────────

def _compute_put_wall_density(gex_strikes: list[GexStrike], spot: float) ->Optional[float]:
    if not gex_strikes or spot == 0:
        return None
    band = [s for s in gex_strikes if abs(s.strike - spot) / spot < IV_PUT_WALL_BAND_PCT]
    if not band:
        return None
    avg_oi = sum(s.put_oi for s in band) / len(band)
    if avg_oi == 0:
        return None
    below_spot = sorted([s for s in gex_strikes if s.strike < spot], key=lambda s: -s.put_oi)
    if not below_spot:
        return None
    return below_spot[0].put_oi / avg_oi


# ── Second-order Greeks ───────────────────────────────────────────────────────

def _second_order_greeks(
    spot: float,
    strike: float,
    sigma_pct: float,    # IV as percent (e.g. 21.0 for 21%)
    dte: int,
    gamma: float,        # from Schwab
    vega: float,         # from Schwab
    r: float,
    expiry_date:Optional[str] = None,
) -> tuple[float, float, float]:
    """Returns (vanna, charm, volga). Matches IvAnalyticsService._secondOrderGreeks()."""
    sigma = sigma_pct / 100
    if sigma <= 0 or dte < 0:
        return 0.0, 0.0, 0.0

    # Minute-precision T to handle 0DTE correctly
    now = datetime.now(timezone.utc)
    if expiry_date:
        try:
            exp = datetime.fromisoformat(expiry_date.replace("Z", "+00:00"))
            minutes_left = max(1.0, float((exp - now).total_seconds() / 60))
        except Exception:
            minutes_left = max(1.0, float(dte * 24 * 60))
    else:
        minutes_left = max(1.0, float(dte * 24 * 60))

    T = minutes_left / (365 * 24 * 60)
    sqrt_T = math.sqrt(T)
    sig_sqt = sigma * sqrt_T
    if sig_sqt < 1e-6:
        return 0.0, 0.0, 0.0

    log_moneyness = math.log(spot / strike)
    d1 = (log_moneyness + (r + 0.5 * sigma * sigma) * T) / sig_sqt
    d2 = d1 - sig_sqt

    # Clamp d1/d2 to prevent extreme values for deep OTM/ITM options near expiry
    d1 = max(-50.0, min(50.0, d1))
    d2 = max(-50.0, min(50.0, d2))

    # Vanna = -gamma * S * sqrt(T) * d2 = ∂Δ/∂σ (σ in absolute units, i.e. per
    # 100 vol points). Scale by 0.01 so the stored value is per 1 vol point,
    # matching the "1% IV move" convention used everywhere downstream.
    vanna = -gamma * spot * sqrt_T * d2 * 0.01

    # Charm = -gamma * S * (2rT - d2*σ*√T) / (2T), per calendar day (/365)
    charm = (-gamma * spot * (2 * r * T - d2 * sigma * sqrt_T) / (2 * T * 365)) if T > 0 else 0.0

    # Volga = vega * d1 * d2 / σ = ∂vega/∂σ. Schwab vega is already $ per
    # vol-point, so this derivative is w.r.t. absolute σ; scale by 0.01 to get
    # $-vega change per 1 vol-point IV move.
    volga = vega * d1 * d2 / sigma * 0.01

    return vanna, charm, volga


def _compute_second_order(
    expirations: list[dict],
    spot: float,
    r: float,
) -> list[SecondOrderStrike]:
    """Aggregate second-order Greeks per strike across all expirations."""
    calls_by_strike: dict[float, list[dict]] = {}
    puts_by_strike: dict[float, list[dict]] = {}

    for exp in expirations:
        for c in exp.get("calls", []):
            k = float(c["strikePrice"])
            calls_by_strike.setdefault(k, []).append(c)
        for p in exp.get("puts", []):
            k = float(p["strikePrice"])
            puts_by_strike.setdefault(k, []).append(p)

    all_strikes = sorted(set(calls_by_strike) | set(puts_by_strike))
    results = []

    for strike in all_strikes:
        if abs(strike - spot) / spot > IV_GEX_WINDOW_PCT:
            continue

        calls = calls_by_strike.get(strike, [])
        puts = puts_by_strike.get(strike, [])
        
        # 1. Initialize weighted sums
        call_oi = 0.0
        c_vanna_sum = c_charm_sum = c_volga_sum = 0.0
        
        # 2. Process Calls
        for c in calls:
            oi = float(c.get("openInterest", 0))
            if oi <= 0: continue
            
            vn, ch, vg = _second_order_greeks(
                spot, strike,
                float(c.get("volatility") or c.get("impliedVolatility") or 0),
                int(c.get("daysToExpiration", 0)),
                float(c.get("gamma", 0)),
                float(c.get("vega", 0)),
                r,
                c.get("expirationDate"),
            )
            call_oi += oi
            c_vanna_sum += (vn * oi)
            c_charm_sum += (ch * oi)
            c_volga_sum += (vg * oi)

        # 3. Process Puts
        put_oi = 0.0
        p_vanna_sum = p_charm_sum = p_volga_sum = 0.0
        for p in puts:
            oi = float(p.get("openInterest", 0))
            if oi <= 0: continue
            
            vn, ch, vg = _second_order_greeks(
                spot, strike,
                float(p.get("volatility") or p.get("impliedVolatility") or 0),
                int(p.get("daysToExpiration", 0)),
                float(p.get("gamma", 0)),
                float(p.get("vega", 0)),
                r,
                p.get("expirationDate"),
            )
            put_oi += oi
            p_vanna_sum += (vn * oi)
            p_charm_sum += (ch * oi)
            p_volga_sum += (vg * oi)

        if call_oi == 0 and put_oi == 0:
            continue

        # 4. Final Weighted Averages
        # We divide the sum of (Greek * OI) by the Total OI for that strike
        results.append(SecondOrderStrike(
            strike=strike,
            call_oi=call_oi,
            put_oi=put_oi,
            call_vanna=c_vanna_sum / call_oi if call_oi > 0 else 0.0,
            put_vanna=p_vanna_sum / put_oi if put_oi > 0 else 0.0,
            call_charm=c_charm_sum / call_oi if call_oi > 0 else 0.0,
            put_charm=p_charm_sum / put_oi if put_oi > 0 else 0.0,
            call_volga=c_volga_sum / call_oi if call_oi > 0 else 0.0,
            put_volga=p_volga_sum / put_oi if put_oi > 0 else 0.0,
        ))
        
    return results


# ── IVR / IVP helper ──────────────────────────────────────────────────────────

def _ivr_ivp(ivs: list[float], current: float) -> tuple[Optional[float], Optional[float]]:
    """Compute IV Rank and IV Percentile for the given slice of history.

    Returns (None, None) when there is insufficient history.
    """
    if len(ivs) < IV_MIN_HISTORY_IVR:
        return None, None
    lo, hi = min(ivs), max(ivs)
    iv_range = hi - lo
    rank = 50.0 if iv_range < 0.001 else max(0.0, min(100.0, (current - lo) / iv_range * 100))
    # Strictly below: IVP is defined as "% of days where IV was LOWER than
    # today" (see the glossary in iv_screen.dart). <= would count today's own
    # already-persisted snapshot as a day below itself.
    pct  = max(0.0, min(100.0, sum(1 for iv in ivs if iv < current) / len(ivs) * 100))
    return rank, pct


# ── Rating helper ──────────────────────────────────────────────────────────────

def _rating_from_rank(ivr: float) -> IvRating:
    if ivr >= 80:
        return IvRating.extreme
    if ivr >= 50:
        return IvRating.expensive
    if ivr >= 25:
        return IvRating.fair
    return IvRating.cheap


