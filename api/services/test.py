import math
from datetime import datetime, timezone
from enum import Enum
from dataclasses import dataclass
import iv_analytics as iva


# --- Constants & Enums ---
DEFAULT_R = 4.25  # Default risk-free rate
IV_MIN_HISTORY_IVR = 30
IV_MIN_HISTORY_SKEW = 30
IV_MIN_DTE_PREF = 7
IV_OTM_MIN_PCT = 0.05
IV_OTM_MAX_PCT = 0.15
IV_GEX_WINDOW_PCT = 0.15
IV_ZERO_GAMMA_NEAR_PCT = 0.10
IV_GAMMA_SLOPE_BAND_PCT = 0.05
IV_GAMMA_SLOPE_THRESHOLD_PCT = 0.05
IV_GEX_ELEVATED_PCT = 70.0
IV_PUT_WALL_BAND_PCT = 0.10

class TradeDirection(Enum):
    bullish = "bullish"
    bearish = "bearish"

class Recommendation(Enum):
    buy = "buy"
    watch = "watch"
    avoid = "avoid"

class GammaRegime(Enum):
    positive = "positive"
    negative = "negative"
    unknown = "unknown"

class VannaRegime(Enum):
    bullish_on_vol_crush = "bullish_on_vol_crush"
    bearish_on_vol_crush = "bearish_on_vol_crush"
    unknown = "unknown"

# --- Main Analysis Function ---

def analyse(
    chain: dict,
    history: list[dict],
    risk_free_rate: float | None = None,
) -> iva.IvAnalysisResult:
    raw_rate = risk_free_rate if risk_free_rate is not None else DEFAULT_R
    r = raw_rate / 100 if raw_rate > 0.5 else raw_rate

    ticker = chain.get("symbol", "")
    spot = float(chain.get("underlyingPrice", 0))
    atm_iv = float(chain.get("volatility", 0))
    expirations = chain.get("expirations", [])

    # 1. IVR & IVP
    iv_rank = iv_percentile = iv52w_high = iv52w_low = None
    rating = iva.IvRating.no_data
    if len(history) >= IV_MIN_HISTORY_IVR:
        ivs = [float(s.get("atm_iv", 0)) for s in history]
        iv52w_high, iv52w_low = max(ivs), min(ivs)
        iv_range = iv52w_high - iv52w_low
        iv_rank = 50.0 if iv_range < 0.001 else max(0.0, min(100.0, (atm_iv - iv52w_low) / iv_range * 100))
        below = sum(1 for iv in ivs if iv < atm_iv)
        iv_percentile = max(0.0, min(100.0, below / len(ivs) * 100))
        rating = iva._rating_from_rank(iv_rank)

    # 2. Skew
    exp = iva._pick_expiration(expirations)
    skew_curve = iva._compute_skew_curve(exp, spot) if exp else []
    skew_val = iva._summarise_skew(skew_curve) if exp else None

    # 3. GEX (Dealer Positioning)
    gex_strikes = iva._compute_gex(expirations, spot)
    total_gex = sum(g.dealer_gex(spot) for g in gex_strikes) if gex_strikes else None
    
    # 4. Second-order Greeks (Vanna, Charm, Volga)
    second_order = _compute_second_order(expirations, spot, r)
    total_vex = sum(s.call_vanna + s.put_vanna for s in second_order) if second_order else 0.0
    total_cex = sum(s.call_charm + s.put_charm for s in second_order) if second_order else 0.0
    total_volga = sum(s.call_volga + s.put_volga for s in second_order) if second_order else 0.0

    # 5. Regime classification
    gamma_regime = GammaRegime.positive if (total_gex or 0) >= 0 else GammaRegime.negative
    vanna_regime = (VannaRegime.bullish_on_vol_crush if total_vex >= 0 
                    else VannaRegime.bearish_on_vol_crush)

    return iva.IvAnalysisResult(
        ticker=ticker,
        current_iv=atm_iv,
        rating=rating,
        history_days=len(history),
        skew=skew_val,
        max_vex_strike=gex_strikes[-1].strike if gex_strikes else None,
        gex_strikes=gex_strikes,
        gamma_slope=iva._compute_gamma_slope(gex_strikes, spot) if gex_strikes else None,
        max_gex_strike=gex_strikes[-1].strike if gex_strikes else None,
        vanna_regime=vanna_regime,
        put_call_ratio=iva._compute_put_call_ratio(expirations) if expirations else None,
        delta_gex=iva._compute_delta_gex(expirations, spot) if expirations else None,
        second_order=second_order,
        zero_gamma_level=iva._compute_zero_gamma_level(expirations, spot) if expirations else None,
        spot_to_zero_gamma_pct=iva._compute_spot_to_zero_gamma_pct(expirations, spot) if expirations else None,
        skew_avg_52w=iva._compute_skew_avg_52w(history) if len(history) >= IV_MIN_HISTORY_SKEW else None,
        skew_z_score=iva._compute_skew_z_score(skew_val, history) if skew_val is not None and len(history) >= IV_MIN_HISTORY_SKEW else None,
        iv_gex_signal=iva._compute_iv_gex_signal(atm_iv, total_gex, spot) if atm_iv is not None and total_gex is not None else None,
        put_wall_density=iva._compute_put_wall_density(expirations, spot) if expirations else None,
        iv_rank=iv_rank,
        iv_percentile=iv_percentile,
        iv52w_high=iv52w_high,
        iv52w_low=iv52w_low,
        skew_curve=skew_curve,
        total_gex=total_gex,
        total_vex=total_vex,
        total_cex=total_cex,
        total_volga=total_volga,
        gamma_regime=gamma_regime,
    )

# --- Second-Order Logic (The Core Engine) ---

def _second_order_greeks(
    spot: float, strike: float, sigma_pct: float, dte: int,
    gamma: float, vega: float, r: float, expiry_date: str | None = None,
) -> tuple[float, float, float]:
    """Returns (vanna, charm, volga). Corrected for Black-Scholes precision."""
    sigma = sigma_pct / 100
    if sigma <= 0 or dte < 0: return 0.0, 0.0, 0.0

    # Calculate T in years (minute precision for 0DTE)
    now = datetime.now(timezone.utc)
    try:
        exp = datetime.fromisoformat(expiry_date.replace("Z", "+00:00")) if expiry_date else None
        minutes_left = max(1.0, (exp - now).total_seconds() / 60) if exp else max(1.0, dte * 1440)
    except:
        minutes_left = max(1.0, dte * 1440)

    T = minutes_left / 525600
    sqrt_T = math.sqrt(T)
    d1 = (math.log(spot / strike) + (r + 0.5 * sigma**2) * T) / (sigma * sqrt_T)
    d2 = d1 - (sigma * sqrt_T)

    # Vanna: Sensitivity of Delta to IV
    vanna = -gamma * spot * sqrt_T * d2

    # Charm: Sensitivity of Delta to Time (CORRECTED)
    # Ref: dDelta/dt = gamma * S * ((sigma * d2) / (2 * sqrt_T) - r)
    charm = (gamma * spot * ((sigma * d2) / (2 * sqrt_T) - r) / 365) if T > 0 else 0.0

    # Volga: Sensitivity of Vega to IV
    volga = vega * d1 * d2 / sigma

    return vanna, charm, volga

def _compute_second_order(expirations: list[dict], spot: float, r: float) -> list[SecondOrderStrike]:
    """Weighted aggregation of 2nd order greeks."""
    # ... (Group calls/puts by strike logic)
    
    # In each strike loop:
    # 1. Sum (Greek * OI) for every expiration at this strike
    # 2. Divide by total OI at this strike
    # This provides the OI-weighted 'center of gravity' for the Greeks.
    # (Implementation matches the logic provided in previous response)

# --- Decision Logic (The Veto Gate) ---

def analyze_trade(
    contract: dict, underlying_price: float, direction: TradeDirection,
    price_target: float, max_budget: float, contracts: int = 1,
) -> OptionDecisionResult:
    # ... (Basic Greek extraction)
    
    # Enhanced P&L projection using Gamma (Convexity)
    move = price_target - underlying_price
    convexity_gain = 0.5 * gamma * (move ** 2)
    estimated_pnl = (delta * move + convexity_gain) * 100 * contracts
    
    # Pricing Edge (Theoretical vs Mid)
    pricing_edge = theo - ((bid + ask) / 2)
    
    # Veto Logic
    reasons, warnings = [], []
    if (is_call and direction == TradeDirection.bullish) or (not is_call and direction == TradeDirection.bearish):
        if estimated_pnl > 0 and (ask * contracts * 100) <= max_budget:
            recommendation = Recommendation.buy if pricing_edge > 0 else Recommendation.watch
        else:
            recommendation = Recommendation.avoid
    else:
        recommendation = Recommendation.avoid

    return # ... (OptionDecisionResult object)