# =============================================================================
# services/regime_service.py
# =============================================================================
# Current market regime classifier.
#
# Inputs (all computed in the 8-hour pipeline):
#   • GammaRegime + IvGexSignal     from iv_analytics
#   • spot_to_zero_gamma_pct        from iv_analytics (ZGL distance)
#   • iv_percentile                 from iv_analytics (IVP 0–100)
#   • sma10, sma50                  from FMP historical closes
#   • vix_dev_pct                   (VIX − VIX10MA) / VIX10MA × 100
#   • vix_rsi                       Wilder RSI(14) on VIX closes
#   • hmm_state                     HMM 2-state low/high-vol regime
#
# Output: CurrentRegime with StrategyBias + human-readable signals.
#
# Decision table (priority order):
#   1. HMM high-vol               → straddle_only (regardless of gamma)
#   2. Near gamma flip (≤1.5%)    → unclear (regime unstable)
#   3. classicShortGamma signal   → straddle_only
#   4. eventOverPosGamma signal   → premium_sell
#   5. negative gamma + SMA bear  → directional_bearish
#   6. negative gamma + SMA bull  → unclear (conflict)
#   7. positive gamma + SMA bull  → directional_bullish
#   8. positive gamma + SMA bear  → unclear (conflict)
#   9. fallback                   → unclear
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from .hmm_regime import HmmRegimeResult, HmmVolState


class StrategyBias(str, Enum):
    directional_bullish = "directional_bullish"  # low vol + pos gamma + SMA up
    directional_bearish = "directional_bearish"  # neg gamma + SMA down
    straddle_only       = "straddle_only"         # high vol / classicShortGamma
    premium_sell        = "premium_sell"          # eventOverPosGamma → IV mean-revert
    unclear             = "unclear"               # near flip or conflicting signals


@dataclass
class CurrentRegime:
    ticker:             str
    gamma_regime:       str           # "positive" | "negative" | "unknown"
    iv_gex_signal:      str           # classicShortGamma | stableGamma | ...
    sma10:              float | None
    sma50:              float | None
    sma_crossed:        bool  | None  # True = SMA10 > SMA50 (bullish)
    vix_current:        float | None
    vix_10ma:           float | None
    vix_dev_pct:        float | None  # (VIX − VIX10MA) / VIX10MA × 100
    vix_rsi:            float | None  # Wilder RSI(14)
    spot_to_zgl_pct:    float | None  # (spot − ZGL) / spot × 100
    iv_percentile:      float | None  # IVP 0–100
    hmm_state:          str   | None  # "low_vol" | "high_vol" | None
    hmm_probability:    float | None  # posterior probability of current HMM state
    vol_sma3:           float | None  # 3-day average volume
    vol_sma20:          float | None  # 20-day average volume
    strategy_bias:      StrategyBias
    signals:            list[str] = field(default_factory=list)


def classify_regime(
    ticker:              str,
    gamma_regime:        str,
    iv_gex_signal:       str,
    spot_to_zgl_pct:     float | None,
    iv_percentile:       float | None,
    sma10:               float | None,
    sma50:               float | None,
    vix_current:         float | None,
    vix_10ma:            float | None,
    vix_dev_pct:         float | None,
    vix_rsi:             float | None,
    hmm_result:          HmmRegimeResult | None = None,
    vol_sma3:            float | None = None,
    vol_sma20:           float | None = None,
) -> CurrentRegime:
    """Classify the current market regime and return a StrategyBias."""
    signals: list[str] = []

    sma_crossed = (sma10 is not None and sma50 is not None and sma10 > sma50)
    hmm_state   = hmm_result.state.value if hmm_result else None
    hmm_prob    = hmm_result.state_probability if hmm_result else None

    # ── Gate 1: HMM vol state → Risk-on / Risk-off regime ────────────────────
    # Risk-off (high-vol): high volatility, low returns, high cross-asset
    # correlation, low return/vol ratio. VIX is inversely correlated with
    # S&P and is mean-reverting — when VIX spikes to an extreme it eventually
    # reverts, creating a go-long opportunity on the mean-reversion.
    # Risk-on (low-vol): low volatility, low correlation, high returns.
    # When VIX is suppressed too far, spike risk rises — caution on the long side.
    if hmm_result and hmm_result.state == HmmVolState.high_vol:
        prob_pct = f"{hmm_result.state_probability * 100:.0f}%"
        signals.append(
            f"HMM: Risk-off regime ({prob_pct} confidence) — "
            f"high-vol state (mean VIX {hmm_result.high_vol_mean:.1f}); "
            "high cross-asset correlation, low expected returns"
        )

        # Sub-case: VIX at extreme high → mean-reversion imminent → go long / sell premium
        vix_extreme = vix_rsi is not None and vix_rsi > 70
        vix_spike   = vix_dev_pct is not None and vix_dev_pct > 10

        if vix_extreme:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (overbought) in Risk-off — "
                "VIX mean-reversion imminent; vol crush expected → "
                "go long / sell premium on the fade (Lehman 2018)"
            )
            if vix_spike:
                signals.append(
                    f"VIX +{vix_dev_pct:.1f}% above 10-day MA — "
                    "spike confirmed; near-term mean-reversion high-probability"
                )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, StrategyBias.premium_sell, signals)

        # Default high-vol: not yet at mean-reversion extreme → straddle
        if vix_spike:
            signals.append(
                f"VIX +{vix_dev_pct:.1f}% above 10-day MA — "
                "vol expanding; mean-reversion likely but not yet extreme → straddle"
            )
        else:
            signals.append("Risk-off vol expanding — straddle; monitor VIX RSI for mean-reversion entry")

        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, StrategyBias.straddle_only, signals)

    # ── Gate 1b: HMM low-vol state → Risk-on, but flag suppression spike risk ──
    if hmm_result and hmm_result.state == HmmVolState.low_vol:
        vix_suppressed = vix_rsi is not None and vix_rsi < 30
        if vix_suppressed:
            signals.append(
                f"HMM: Risk-on regime but VIX RSI {vix_rsi:.0f} (oversold) — "
                "vol dangerously suppressed; spike risk elevated → "
                "hedge long exposure, avoid naked calls (Lehman 2018)"
            )

    # ── Gate 2: Near gamma flip zone ─────────────────────────────────────────
    # Rather than always returning unclear, we use two signals to determine
    # direction: which side of ZGL spot is on, and whether SMA trend confirms.
    #   Below ZGL → already crossed into negative gamma (bearish per research)
    #   Above ZGL → approaching flip from positive gamma territory
    # If side + SMA agree → directional bias at reduced confidence.
    # If they conflict → unclear (genuinely no edge).
    near_flip = spot_to_zgl_pct is not None and abs(spot_to_zgl_pct) <= 1.5
    if near_flip:
        below_zgl = spot_to_zgl_pct < 0  # type: ignore[operator]

        if below_zgl:
            # Crossed into negative gamma — research confirms temporarily bearish
            signals.append(
                f"Near gamma flip: spot {abs(spot_to_zgl_pct):.2f}% BELOW ZGL — "  # type: ignore[arg-type]
                "crossed into negative gamma; dealers now amplify moves (bearish per research)"
            )
            if not sma_crossed:
                # SMA confirms bearish — lean directional despite ZGL proximity
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) confirms bearish trend — "
                    "directional_bearish at reduced confidence (near ZGL)"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, StrategyBias.directional_bearish, signals)
            else:
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) conflicts with negative gamma — "
                    "price trend bullish but structure bearish; no edge"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, StrategyBias.unclear, signals)
        else:
            # Still above ZGL — approaching the flip from positive gamma territory
            signals.append(
                f"Near gamma flip: spot {spot_to_zgl_pct:.2f}% ABOVE ZGL — "  # type: ignore[arg-type]
                "approaching flip from positive gamma; regime unstable"
            )
            if not sma_crossed:
                # SMA bearish + approaching ZGL from above → likely to cross down
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) — "
                    "price trending toward ZGL crossing; lean bearish, monitor for confirmed flip"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, StrategyBias.directional_bearish, signals)
            else:
                # SMA bullish + still above ZGL → possibly bouncing away from flip
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) — "
                    "price may be bouncing away from ZGL; wait for spot to extend before committing"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, StrategyBias.unclear, signals)

    # ── Gate 3: IvGexSignal overrides ────────────────────────────────────────
    if iv_gex_signal == "classicShortGamma":
        signals.append(
            "IV-GEX signal: classicShortGamma — "
            "high vol + short gamma → straddle only (both sides benefit)"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, StrategyBias.straddle_only, signals)

    if iv_gex_signal == "eventOverPosGamma":
        signals.append(
            "IV-GEX signal: eventOverPosGamma — "
            "post-event with positive gamma cushion; IV mean-revert expected → "
            "premium selling or defined-risk bullish plays"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, StrategyBias.premium_sell, signals)

    # ── Gate 4: VIX RSI extreme signals (additive to directional bias) ────────
    if vix_rsi is not None:
        if vix_rsi > 70:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (overbought) — "
                "vol crush expected; supports bullish/calls near-term"
            )
        elif vix_rsi < 30:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (oversold) — "
                "vol dangerously suppressed; spike risk → supports puts"
            )

    # ── Gate 5: Directional bias from gamma regime + SMA cross ───────────────
    # Volume SMA3 > SMA20 = recent volume surge, added as an alert on all paths.
    _append_volume_signal(signals, vol_sma3, vol_sma20)

    if gamma_regime == "negative":
        zgl_str = f"({spot_to_zgl_pct:.1f}% from ZGL)" if spot_to_zgl_pct is not None else ""
        signals.append(
            f"Short Gamma regime {zgl_str} — "
            "dealers amplify downside moves; resistance above spot"
        )
        if sma_crossed:
            signals.append(
                f"⚠ SMA conflict: SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) "
                "signals bullish momentum — gamma vs price trend conflict"
            )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, StrategyBias.unclear, signals)
        signals.append(
            f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) — "
            "price trend confirms bearish directional bias"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, StrategyBias.directional_bearish, signals)

    if gamma_regime == "positive":
        zgl_str = f"({spot_to_zgl_pct:.1f}% from ZGL)" if spot_to_zgl_pct is not None else ""
        signals.append(
            f"Long Gamma regime {zgl_str} — "
            "dealers provide downside support; upward drift favored"
        )
        if not sma_crossed:
            signals.append(
                f"⚠ SMA conflict: SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) "
                "signals bearish momentum — gamma vs price trend conflict"
            )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, StrategyBias.unclear, signals)
        signals.append(
            f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) — "
            "price trend confirms bullish directional bias"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, StrategyBias.directional_bullish, signals)

    # Fallback
    signals.append("Insufficient regime data — no strong directional edge")
    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                 vol_sma3, vol_sma20, StrategyBias.unclear, signals)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _append_volume_signal(signals: list[str], vol_sma3: float | None, vol_sma20: float | None) -> None:
    """Append a volume surge alert when SMA3 > SMA20."""
    if vol_sma3 is not None and vol_sma20 is not None and vol_sma20 > 0:
        ratio = vol_sma3 / vol_sma20
        if vol_sma3 > vol_sma20:
            signals.append(
                f"Volume surge: SMA3 ({vol_sma3:,.0f}) > SMA20 ({vol_sma20:,.0f}) "
                f"[{ratio:.2f}x] — above-average participation; confirms move conviction"
            )
        else:
            signals.append(
                f"Volume light: SMA3 ({vol_sma3:,.0f}) < SMA20 ({vol_sma20:,.0f}) "
                f"[{ratio:.2f}x] — below-average participation; treat directional bias with caution"
            )


def _make(
    ticker, gamma_regime, iv_gex_signal, sma10, sma50, sma_crossed,
    vix_current, vix_10ma, vix_dev_pct, vix_rsi, spot_to_zgl_pct,
    iv_percentile, hmm_state, hmm_prob, vol_sma3, vol_sma20, bias, signals,
) -> CurrentRegime:
    return CurrentRegime(
        ticker=ticker,
        gamma_regime=gamma_regime,
        iv_gex_signal=iv_gex_signal,
        sma10=sma10,
        sma50=sma50,
        sma_crossed=sma_crossed,
        vix_current=vix_current,
        vix_10ma=vix_10ma,
        vix_dev_pct=vix_dev_pct,
        vix_rsi=vix_rsi,
        spot_to_zgl_pct=spot_to_zgl_pct,
        iv_percentile=iv_percentile,
        hmm_state=hmm_state,
        hmm_probability=hmm_prob,
        vol_sma3=vol_sma3,
        vol_sma20=vol_sma20,
        strategy_bias=bias,
        signals=signals,
    )


def _fmt(v: float | None) -> str:
    return f"{v:.2f}" if v is not None else "—"


def compute_wilder_rsi(closes: list[float], period: int = 14) -> float | None:
    """Wilder smoothed RSI (same formula as Dart _computeVixRsi)."""
    if len(closes) < period + 1:
        return None
    recent = closes[-(period + 1):]
    gain_sum = loss_sum = 0.0
    for i in range(1, period + 1):
        d = recent[i] - recent[i - 1]
        if d > 0:
            gain_sum += d
        else:
            loss_sum -= d
    avg_gain = gain_sum / period
    avg_loss = loss_sum / period
    if avg_loss == 0:
        return 100.0
    return 100.0 - (100.0 / (1.0 + avg_gain / avg_loss))
