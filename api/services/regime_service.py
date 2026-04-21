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

import math
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
) -> CurrentRegime:
    """Classify the current market regime and return a StrategyBias."""
    signals: list[str] = []

    sma_crossed = (sma10 is not None and sma50 is not None and sma10 > sma50)
    hmm_state   = hmm_result.state.value if hmm_result else None
    hmm_prob    = hmm_result.state_probability if hmm_result else None

    # ── Gate 1: HMM high-vol state → straddle ────────────────────────────────
    if hmm_result and hmm_result.state == HmmVolState.high_vol:
        prob_pct = f"{hmm_result.state_probability * 100:.0f}%"
        signals.append(
            f"HMM: High-vol state ({prob_pct} confidence, mean VIX "
            f"{hmm_result.high_vol_mean:.1f}) — straddle regime"
        )
        if vix_dev_pct is not None and vix_dev_pct > 10:
            signals.append(
                f"VIX is +{vix_dev_pct:.1f}% above 10-day MA — "
                f"vol spike confirmed, mean-reversion likely near-term"
            )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.straddle_only, signals)

    # ── Gate 2: Near gamma flip zone ─────────────────────────────────────────
    near_flip = spot_to_zgl_pct is not None and abs(spot_to_zgl_pct) <= 1.5
    if near_flip:
        flip_dir = "above" if spot_to_zgl_pct > 0 else "below"  # type: ignore[operator]
        signals.append(
            f"Near gamma flip ({spot_to_zgl_pct:.2f}% {flip_dir} ZGL) — "
            "regime unstable; wait for stabilization. Temporarily bearish per research."
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.unclear, signals)

    # ── Gate 3: IvGexSignal overrides ────────────────────────────────────────
    if iv_gex_signal == "classicShortGamma":
        signals.append(
            "IV-GEX signal: classicShortGamma — "
            "high vol + short gamma → straddle only (both sides benefit)"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.straddle_only, signals)

    if iv_gex_signal == "eventOverPosGamma":
        signals.append(
            "IV-GEX signal: eventOverPosGamma — "
            "post-event with positive gamma cushion; IV mean-revert expected → "
            "premium selling or defined-risk bullish plays"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.premium_sell, signals)

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
                         StrategyBias.unclear, signals)
        signals.append(
            f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) — "
            "price trend confirms bearish directional bias"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.directional_bearish, signals)

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
                         StrategyBias.unclear, signals)
        signals.append(
            f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) — "
            "price trend confirms bullish directional bias"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     StrategyBias.directional_bullish, signals)

    # Fallback
    signals.append("Insufficient regime data — no strong directional edge")
    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                 StrategyBias.unclear, signals)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make(
    ticker, gamma_regime, iv_gex_signal, sma10, sma50, sma_crossed,
    vix_current, vix_10ma, vix_dev_pct, vix_rsi, spot_to_zgl_pct,
    iv_percentile, hmm_state, hmm_prob, bias, signals,
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
