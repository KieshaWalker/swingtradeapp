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

import math
from dataclasses import dataclass, field
from enum import Enum
from datetime import datetime, timezone

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
    IV_GEX_ELEVATED_PCT,
    IV_DEEP_LONG_GEX,
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

    @property
    def dealer_vex(self) -> float:
        """Dealer Vanna Exposure: (callOI*callVanna - putOI*putVanna) * 100. 
        While Gamma is the sensitivity of Delta to Price, Vanna is the sensitivity of Delta to Volatility
        If the market is in a "Long Vanna" state (positive result), and implied volatility drops (a "vol crush"),
        dealers' deltas change in a way that forces them to buy the underlying. This is often why the market rallies after a major risk event—not because the news was "good,"
        but because the drop in IV forced dealers to buy back their hedges.
        Result = 50,000: This means if implied volatility increases by 1 point (e.g., from 20% to 21%), 
        market makers would need to buy 50,000 shares of the underlying asset to remain delta-neutral.
        Result = -50,000: If IV increases by 1 point, market makers would need to sell 50,000 shares."""
        return (self.call_oi * self.call_vanna - self.put_oi * self.put_vanna) * 100

    @property
    def dealer_cex(self) -> float:
        """Dealer Charm Exposure.
        Call Charm: As time passes, the Delta of OTM (Out-of-the-Money) calls decays toward 0. For ITM (In-the-Money) calls, Delta decays toward 1.00.
        Put Charm: Similarly, OTM put Deltas decay toward 0, while ITM put Deltas decay toward -1.00.
        In a "Long Charm" state (positive result), the passage of time causes dealers' deltas to move in a way that forces them to buy the underlying. 
        This can lead to price support as expiration approaches.
            Result = 20,000: This means that, all else equal, the passage of one day would require market makers to buy 20,000 shares to maintain a delta-neutral position.
            The result represents the number of shares a dealer must buy or sell at the end of each day to remain delta-neutral, assuming price and volatility stay constant.
            Positive Result: Dealers have "Positive Charm." As time passes, their net delta becomes more positive, requiring them to sell shares to re-hedge.
            Negative Result: Dealers have "Negative Charm." As time passes, they must buy shares to remain neutral.
           Weekend Effect" and OPEXCharm is most influential in the final days before an option expiration (OPEX).
           The "Charm Rally": In a typical "Long Gamma" environment where investors have bought puts to hedge, dealers are Short Puts.
             As those puts decay toward zero (Charm), dealers are forced to "un-hedge" by buying back the underlying. This is a major contributor to the "upward drift" often seen during expiration weeks.
           Weekend Bleed: Because Charm is a function of time ($t$), a three-day weekend can represent a massive jump in delta decay, leading to significant re-hedging flows on Monday morning (or Friday afternoon in anticipation). 
            
            """
        return (self.call_oi * self.call_charm - self.put_oi * self.put_charm) * 100

    @property
    def dealer_volga(self) -> float:
        """Dealer Volga Exposure."""
        return (self.call_oi * self.call_volga - self.put_oi * self.put_volga) * 100


@dataclass
class SkewPoint:
    strike: float
    moneyness: float  # (strike - spot) / spot * 100
    call_iv: float | None
    put_iv: float | None


@dataclass
class IvAnalysisResult:
    ticker: str
    current_iv: float
    iv52w_high: float | None
    iv52w_low: float | None
    iv_rank: float | None
    iv_percentile: float | None
    rating: IvRating
    history_days: int
    skew: float | None
    skew_avg_52w: float | None
    skew_z_score: float | None
    skew_curve: list[SkewPoint]
    gex_strikes: list[GexStrike]
    total_gex: float | None
    max_gex_strike: float | None
    put_call_ratio: float | None
    second_order: list[SecondOrderStrike]
    total_vex: float | None
    total_cex: float | None
    total_volga: float | None
    max_vex_strike: float | None
    gamma_regime: GammaRegime
    vanna_regime: VannaRegime
    zero_gamma_level: float | None
    spot_to_zero_gamma_pct: float | None
    delta_gex: float | None
    gamma_slope: GammaSlope
    iv_gex_signal: IvGexSignal
    put_wall_density: float | None


# ── Main entry point ──────────────────────────────────────────────────────────

def analyse(
    chain: dict,          # Schwab options chain JSON (from Edge Function)
    history: list[dict],  # iv_snapshots rows, sorted ascending by date
    risk_free_rate: float | None = None,
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
    raw_rate = risk_free_rate if risk_free_rate is not None else DEFAULT_R
    r = raw_rate / 100 if raw_rate > 0.5 else raw_rate

    ticker = chain.get("symbol", "")
    spot = float(chain.get("underlyingPrice", 0))
    atm_iv = float(chain.get("volatility", 0))
    expirations = chain.get("expirations", [])

    # ── IVR & IVP ──────────────────────────────────────────────────────────────
    iv_rank: float | None = None
    iv_percentile: float | None = None
    iv52w_high: float | None = None
    iv52w_low: float | None = None
    rating = IvRating.no_data

    if len(history) >= IV_MIN_HISTORY_IVR:
        ivs = [float(s.get("atm_iv", 0)) for s in history]
        iv52w_high = max(ivs)
        iv52w_low = min(ivs)
        iv_range = iv52w_high - iv52w_low
        iv_rank = 50.0 if iv_range < 0.001 else max(0.0, min(100.0, (atm_iv - iv52w_low) / iv_range * 100))
        below = sum(1 for iv in ivs if iv < atm_iv)
        iv_percentile = max(0.0, min(100.0, below / len(ivs) * 100))
        rating = _rating_from_rank(iv_rank)

    # ── Skew ───────────────────────────────────────────────────────────────────
    exp = _pick_expiration(expirations)
    skew_curve = _compute_skew_curve(exp, spot) if exp else []
    skew_val = _summarise_skew(skew_curve) if exp else None

    skew_avg_52w: float | None = None
    skew_z_score: float | None = None
    if history:
        skew_history = [float(s["skew"]) for s in history if s.get("skew") is not None]
        if len(skew_history) >= IV_MIN_HISTORY_SKEW:
            skew_avg_52w = sum(skew_history) / len(skew_history)
            if skew_val is not None:
                variance = sum((s - skew_avg_52w) ** 2 for s in skew_history) / len(skew_history)
                std = math.sqrt(variance)
                skew_z_score = 0.0 if std < 0.001 else (skew_val - skew_avg_52w) / std

    # ── GEX ────────────────────────────────────────────────────────────────────
    gex_strikes = _compute_gex(expirations, spot)
    total_gex: float | None = None
    max_gex_strike: float | None = None
    put_call_ratio: float | None = None

    if gex_strikes:
        total_gex = sum(g.dealer_gex(spot) for g in gex_strikes)
        max_gex_strike = max(gex_strikes, key=lambda g: abs(g.dealer_gex(spot))).strike
        total_call_oi = sum(g.call_oi for g in gex_strikes)
        total_put_oi = sum(g.put_oi for g in gex_strikes)
        if total_call_oi > 0:
            put_call_ratio = total_put_oi / total_call_oi

    # ── Second-order Greeks ────────────────────────────────────────────────────
    second_order = _compute_second_order(expirations, spot, r)
    total_vex: float | None = None
    total_cex: float | None = None
    total_volga: float | None = None
    max_vex_strike: float | None = None

    if second_order:
        total_vex = sum(s.dealer_vex for s in second_order)
        total_cex = sum(s.dealer_cex for s in second_order)
        total_volga = sum(s.dealer_volga for s in second_order)
        max_vex_strike = max(second_order, key=lambda s: abs(s.dealer_vex)).strike

    # ── Regime classification ──────────────────────────────────────────────────
    gamma_regime = GammaRegime.unknown
    vanna_regime = VannaRegime.unknown
    if total_gex is not None:
        gamma_regime = GammaRegime.positive if total_gex >= 0 else GammaRegime.negative
    if total_vex is not None:
        vanna_regime = (VannaRegime.bullish_on_vol_crush if total_vex >= 0
                        else VannaRegime.bearish_on_vol_crush)

    # ── Advanced GEX metrics ───────────────────────────────────────────────────
    zero_gamma_level = _compute_zero_gamma_level(gex_strikes, spot)
    spot_to_zero_gamma_pct: float | None = None
    if zero_gamma_level is not None and spot > 0:
        spot_to_zero_gamma_pct = (spot - zero_gamma_level) / spot * 100

    delta_gex: float | None = None
    if total_gex is not None and len(history) >= 2:
        with_gex = [s for s in history if s.get("total_gex") is not None]
        if with_gex:
            delta_gex = total_gex - float(with_gex[-1]["total_gex"])

    gamma_slope = _compute_gamma_slope(gex_strikes, spot)
    iv_gex_signal = _compute_iv_gex_signal(gamma_regime, iv_percentile)
    put_wall_density = _compute_put_wall_density(gex_strikes, spot)

    return IvAnalysisResult(
        ticker=ticker,
        current_iv=atm_iv,
        iv52w_high=iv52w_high,
        iv52w_low=iv52w_low,
        iv_rank=iv_rank,
        iv_percentile=iv_percentile,
        rating=rating,
        history_days=len(history),
        skew=skew_val,
        skew_avg_52w=skew_avg_52w,
        skew_z_score=skew_z_score,
        skew_curve=skew_curve,
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
    )


# ── Expiration picker ─────────────────────────────────────────────────────────

def _pick_expiration(expirations: list[dict]) -> dict | None:
    if not expirations:
        return None
    preferred = [e for e in expirations if int(e.get("dte", 0)) >= IV_MIN_DTE_PREF]
    if preferred:
        return min(preferred, key=lambda e: int(e.get("dte", 0)))
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


def _summarise_skew(curve: list[SkewPoint]) -> float | None:
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


        results.append(GexStrike(
            strike=strike,
            call_oi=call_oi,
            put_oi=put_oi,
            call_gamma=call_gamma,
            put_gamma=put_gamma,
        ))
    return results


# ── Zero Gamma Level ──────────────────────────────────────────────────────────

def _compute_zero_gamma_level(gex_strikes: list[GexStrike], spot: float) -> float | None:
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

def _compute_iv_gex_signal(gamma_regime: GammaRegime, iv_percentile: float | None) -> IvGexSignal:
    if gamma_regime == GammaRegime.unknown:
        return IvGexSignal.unknown
    if iv_percentile is None:
        return IvGexSignal.unknown
    iv_elevated = iv_percentile >= IV_GEX_ELEVATED_PCT
    if gamma_regime == GammaRegime.negative:
        return IvGexSignal.classic_short_gamma if iv_elevated else IvGexSignal.regime_shift
    return IvGexSignal.event_over_pos_gamma if iv_elevated else IvGexSignal.stable_gamma


# ── Put Wall Density ───────────────────────────────────────────────────────────

def _compute_put_wall_density(gex_strikes: list[GexStrike], spot: float) -> float | None:
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
    expiry_date: str | None = None,
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

    # Vanna = -gamma * S * sqrt(T) * d2
    vanna = -gamma * spot * sqrt_T * d2

    # Charm = gamma * S * (r*d1/σ - d2/(2T)) / 365
    charm = (-gamma * spot * (2 * r * T - d2 * sigma * sqrt_T) / (2 * 365)) if T > 0 else 0.0

    # Volga = vega * d1 * d2 / σ
    volga = vega * d1 * d2 / sigma

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


# ── Rating helper ──────────────────────────────────────────────────────────────

def _rating_from_rank(ivr: float) -> IvRating:
    if ivr >= 80:
        return IvRating.extreme
    if ivr >= 50:
        return IvRating.expensive
    if ivr >= 25:
        return IvRating.fair
    return IvRating.cheap
