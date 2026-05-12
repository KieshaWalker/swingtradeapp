# =============================================================================
# services/regime_service.py
# =============================================================================
# Current market regime classifier.
#
# SCOPE: Thresholds calibrated for index and large-cap equity underlyings
# (SPY, QQQ, single large-caps with |GEX| > $100M). Do not use for small/mid-cap
# without recalibrating thresholds. See MIN_MEANINGFUL_TOTAL_GEX_USD in constants.
#
# Inputs (all computed in the 8-hour pipeline):
#   • GammaRegime + IvGexSignal        from iv_analytics
#   • spot_to_zero_gamma_pct           from iv_analytics (ZGL distance)
#   • spot_to_vt_pct                   from iv_analytics (Volatility Trigger distance)
#   • iv_percentile                    from iv_analytics (IVP 0–100)
#   • delta_gex, total_gex, gex_0dte_pct from iv_analytics
#   • sma10, sma50, price_roc5         from Schwab price history
#   • vix_dev_pct, vix_rsi             VIX momentum + mean-reversion signals
#   • vix_term_structure_ratio         VIX / VIX3M (<1 contango, >1 backwardation)
#   • vvix_current, vvix_10ma          VVIX early warning for regime transition
#   • hmm_state                        HMM 2-state low/high-vol regime
#   • breadth_proxy                    RSP/SPY breadth z-score
#
# Decision table (priority order):
#   0. VVIX spike (>15% above 10-day MA) → overrides any premium_sell to straddle_only
#   1. HMM high-vol                 → straddle_only (regardless of gamma)
#      1a. VIX RSI > 70 in high-vol → premium_sell (mean-reversion imminent)
#          UNLESS VVIX spike → straddle_only
#      1b. Backwardation (VIX/VIX3M > 1) → reinforces straddle_only (additive signal)
#   2. Near gamma flip (≤1.5%)      → directional or unclear (side + SMA)
#      2a. Transition corridor (VT < spot < ZGL) → additive signal; directional_bearish elevated
#   3. classicShortGamma signal     → straddle_only
#   4. regimeShift signal           → straddle_only (stealth danger zone)
#   5. eventOverPosGamma signal     → premium_sell; VVIX spike → straddle_only
#   6. stableGamma signal           → premium_sell; backwardation → unclear; VVIX → straddle_only
#   7. negative gamma + SMA bear    → directional_bearish
#   8. negative gamma + SMA bull    → ROC5 tiebreaker:
#        ROC5 > +1% → directional_bullish; ROC5 < -1% → directional_bearish; else unclear
#   9. positive gamma + SMA bull    → directional_bullish
#  10. positive gamma + SMA bear    → ROC5 tiebreaker:
#        ROC5 < -1% → directional_bearish; ROC5 > +1% → unclear (bounce noted); else unclear
#  11. deltaGex transition signal   → additive bullish signal
#  12. fallback                     → unclear
#
# Additive contextual signals (appended unconditionally; never override bias alone):
#   • Scope guard: low absolute GEX (<$100M) — signals less reliable
#   • Volume surge/light: SMA3 vs SMA20 participation
#   • 0DTE GEX domination (>30%/>50%) — intraday gamma resets
#   • Breadth divergence: RSP/SPY z-score ±1.5σ
#   • DeltaGex transition (GEX recovering toward flip)
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from .hmm_regime import HmmRegimeResult, HmmVolState

_MIN_TOTAL_GEX_USD = 100_000_000  # $100M — scope guard threshold


class StrategyBias(str, Enum):
    directional_bullish = "directional_bullish"  # low vol + pos gamma + SMA up
    directional_bearish = "directional_bearish"  # neg gamma + SMA down
    straddle_only       = "straddle_only"         # high vol / classicShortGamma / regimeShift
    premium_sell        = "premium_sell"          # eventOverPosGamma / stableGamma / VIX mean-revert
    unclear             = "unclear"               # near flip or conflicting signals


@dataclass
class CurrentRegime:
    ticker:             str
    gamma_regime:       str           # "positive" | "negative" | "unknown"
    iv_gex_signal:      str           # classicShortGamma | stableGamma | ...
    sma10:              float | None
    sma50:              float | None
    sma_crossed:        bool  | None  # True = SMA10 > SMA50 (bullish), None = no data
    vix_current:        float | None
    vix_10ma:           float | None
    vix_dev_pct:        float | None  # (VIX − VIX10MA) / VIX10MA × 100
    vix_rsi:            float | None  # Wilder RSI(14)
    spot_to_zgl_pct:    float | None  # (spot − ZGL) / spot × 100
    iv_percentile:      float | None  # IVP 0–100
    hmm_state:          str   | None  # "low_vol" | "high_vol" | None
    hmm_probability:    float | None  # posterior probability of current HMM state
    vol_sma3:                   float | None
    vol_sma20:                  float | None
    delta_gex:                  float | None
    strategy_bias:              StrategyBias
    signals:                    list[str] = field(default_factory=list)
    # Institutional-grade context fields
    vix_term_structure_ratio:   float | None = None
    vvix_current:               float | None = None
    vvix_10ma:                  float | None = None
    spot_to_vt_pct:             float | None = None
    breadth_proxy:              float | None = None
    price_roc5:                 float | None = None
    total_gex:                  float | None = None
    gex_0dte:                   float | None = None
    gex_0dte_pct:               float | None = None


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
    hmm_result:                  HmmRegimeResult | None = None,
    vol_sma3:                    float | None = None,
    vol_sma20:                   float | None = None,
    delta_gex:                   float | None = None,
    vix_term_structure_ratio:    float | None = None,
    vvix_current:                float | None = None,
    vvix_10ma:                   float | None = None,
    spot_to_vt_pct:              float | None = None,
    breadth_proxy:               float | None = None,
    price_roc5:                  float | None = None,
    total_gex:                   float | None = None,
    gex_0dte:                    float | None = None,
    gex_0dte_pct:                float | None = None,
) -> CurrentRegime:
    """Classify the current market regime and return a StrategyBias."""
    signals: list[str] = []

    _ctx = dict(
        vix_term_structure_ratio=vix_term_structure_ratio,
        vvix_current=vvix_current,
        vvix_10ma=vvix_10ma,
        spot_to_vt_pct=spot_to_vt_pct,
        breadth_proxy=breadth_proxy,
        price_roc5=price_roc5,
        total_gex=total_gex,
        gex_0dte=gex_0dte,
        gex_0dte_pct=gex_0dte_pct,
    )

    # ── SMA cross: distinguish bearish (False) from no data (None) ───────────
    if sma10 is not None and sma50 is not None:
        sma_crossed: bool | None = sma10 > sma50
    else:
        sma_crossed = None

    hmm_state = hmm_result.state.value if hmm_result else None
    hmm_prob  = hmm_result.state_probability if hmm_result else None

    # ── Gate 0 flag: VVIX spike while VIX is calm → hidden tail risk ─────────
    # Computed early; checked at every premium_sell return to override it.
    vvix_spike_warning = (
        vvix_current is not None and vvix_10ma is not None
        and vvix_10ma > 0
        and vvix_current > vvix_10ma * 1.15
    )

    # ── Additive contextual signals (unconditional — never override bias) ────
    _append_scope_guard_signal(signals, total_gex)
    _append_volume_signal(signals, vol_sma3, vol_sma20)
    _append_0dte_signal(signals, gex_0dte_pct)
    _append_breadth_signal(signals, breadth_proxy)
    _append_delta_gex_signal(signals, delta_gex, gamma_regime)

    if vvix_spike_warning:
        _vvix_pct = (vvix_current - vvix_10ma) / vvix_10ma * 100  # type: ignore[operator]
        signals.append(
            f"VVIX spike: {vvix_current:.1f} is {_vvix_pct:.0f}% above 10-day MA "
            f"({vvix_10ma:.1f}) — vol-of-vol spiking ahead of VIX; "
            "hidden tail risk building; overrides any premium_sell to straddle_only"
        )

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

        # Sub-case: VIX at extreme high → mean-reversion imminent → sell premium
        vix_extreme = vix_rsi is not None and vix_rsi > 70
        vix_spike   = vix_dev_pct is not None and vix_dev_pct > 10

        if vix_extreme:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (overbought) in Risk-off — "
                "VIX mean-reversion imminent; vol crush expected → "
                "sell premium on the fade (Lehman 2018)"
            )
            if vix_spike:
                signals.append(
                    f"VIX +{vix_dev_pct:.1f}% above 10-day MA — "
                    "spike confirmed; near-term mean-reversion high-probability"
                )
            if vvix_spike_warning:
                signals.append(
                    "VVIX spike overrides mean-reversion fade — "
                    "vol-of-vol still elevated; wait for VVIX to confirm before selling premium"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.straddle_only, signals, **_ctx)
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.premium_sell, signals, **_ctx)

        # Default high-vol: not yet at mean-reversion extreme → straddle
        if vix_spike:
            signals.append(
                f"VIX +{vix_dev_pct:.1f}% above 10-day MA — "
                "vol expanding; mean-reversion likely but not yet extreme → straddle"
            )
        else:
            signals.append(
                "Risk-off vol expanding — straddle; "
                "monitor VIX RSI for mean-reversion entry"
            )

        # ── Gate 1b: backwardation reinforces straddle conviction ────────────
        if vix_term_structure_ratio is not None and vix_term_structure_ratio > 1.0:
            signals.append(
                f"VIX term structure: backwardation ({vix_term_structure_ratio:.3f}) — "
                "near-term stress priced above long-term; straddle_only confirmed"
            )

        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.straddle_only, signals, **_ctx)

    # ── Gate 1b: HMM low-vol state → Risk-on, but flag suppression risk ─────
    if hmm_result and hmm_result.state == HmmVolState.low_vol:
        vix_suppressed = vix_rsi is not None and vix_rsi < 30
        if vix_suppressed:
            signals.append(
                f"HMM: Risk-on regime but VIX RSI {vix_rsi:.0f} (oversold) — "
                "vol suppressed; spike risk elevated → "
                "hedge long exposure, widen stops (Lehman 2018)"
            )

    # ── Gate 2: Near gamma flip zone ─────────────────────────────────────────
    near_flip = spot_to_zgl_pct is not None and abs(spot_to_zgl_pct) <= 1.5
    if near_flip:
        below_zgl = spot_to_zgl_pct < 0  # type: ignore[operator]

        if below_zgl:
            signals.append(
                f"Near gamma flip: spot {abs(spot_to_zgl_pct):.2f}% BELOW ZGL — "  # type: ignore[arg-type]
                "crossed into negative gamma; dealers now amplify moves in both directions"
            )
            # ── Gate 2a: VT–ZGL transition corridor ──────────────────────────
            if spot_to_vt_pct is not None and spot_to_vt_pct > 0:
                signals.append(
                    f"Transition corridor: spot {spot_to_vt_pct:.2f}% above Volatility Trigger "
                    f"but {abs(spot_to_zgl_pct):.2f}% below ZGL — "  # type: ignore[arg-type]
                    "in VT–ZGL zone; dealer hedging asymmetric; directional_bearish pressure elevated"
                )
            if sma_crossed is False:
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) confirms bearish trend — "
                    "directional_bearish at reduced confidence (near ZGL)"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.directional_bearish, signals, **_ctx)
            elif sma_crossed is True:
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) conflicts with "
                    "negative gamma — price trend bullish but structure bearish; no edge"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.unclear, signals, **_ctx)
            else:
                # sma_crossed is None — no SMA data
                signals.append("SMA data unavailable — cannot confirm trend near ZGL")
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.unclear, signals, **_ctx)
        else:
            signals.append(
                f"Near gamma flip: spot {spot_to_zgl_pct:.2f}% ABOVE ZGL — "  # type: ignore[arg-type]
                "approaching flip from positive gamma; regime unstable"
            )
            if sma_crossed is False:
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) — "
                    "price trending toward ZGL crossing; lean bearish, monitor for confirmed flip"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.directional_bearish, signals, **_ctx)
            elif sma_crossed is True:
                signals.append(
                    f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) — "
                    "price may be bouncing away from ZGL; wait for spot to extend "
                    "before committing"
                )
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.unclear, signals, **_ctx)
            else:
                signals.append("SMA data unavailable — cannot confirm trend near ZGL")
                return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                             sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                             spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                             vol_sma3, vol_sma20, delta_gex,
                             StrategyBias.unclear, signals, **_ctx)

    # ── Gate 3: IvGexSignal overrides ────────────────────────────────────────
    if iv_gex_signal == "classicShortGamma":
        signals.append(
            "IV-GEX signal: classicShortGamma — "
            "high vol + short gamma; dealers amplify moves in both directions → "
            "straddle only (both sides benefit from vol expansion)"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.straddle_only, signals, **_ctx)

    if iv_gex_signal == "regimeShift":
        signals.append(
            "IV-GEX signal: regimeShift — "
            "STEALTH DANGER ZONE: negative gamma + suppressed IV. "
            "Structural support absent but IV is underpricing the risk. "
            "Standard models underestimate tail risk → "
            "straddle only with defined-risk structures; avoid naked premium"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.straddle_only, signals, **_ctx)

    if iv_gex_signal == "eventOverPosGamma":
        signals.append(
            "IV-GEX signal: eventOverPosGamma — "
            "post-event with positive gamma cushion; IV mean-revert expected → "
            "premium selling or defined-risk bullish plays"
        )
        if vvix_spike_warning:
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.straddle_only, signals, **_ctx)
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.premium_sell, signals, **_ctx)

    if iv_gex_signal == "stableGamma":
        signals.append(
            "IV-GEX signal: stableGamma — "
            "positive gamma + suppressed IV; optimal for net-short premium. "
            "Dealers stabilising; iron condors and credit spreads thrive → "
            "premium selling"
        )
        # Gate 1b extension: backwardation narrows the premium window
        if vix_term_structure_ratio is not None and vix_term_structure_ratio > 1.0:
            signals.append(
                f"VIX backwardation ({vix_term_structure_ratio:.3f}) — "
                "near-term vol priced above long-term; stable-gamma window narrowing → unclear"
            )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.unclear, signals, **_ctx)
        if vvix_spike_warning:
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.straddle_only, signals, **_ctx)
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.premium_sell, signals, **_ctx)

    # ── Gate 4: VIX RSI extreme signals (additive to directional bias) ───────
    if vix_rsi is not None:
        if vix_rsi > 70:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (overbought) — "
                "vol crush expected; supports premium selling near-term"
            )
        elif vix_rsi < 30:
            signals.append(
                f"VIX RSI {vix_rsi:.0f} (oversold) — "
                "vol suppressed; spike risk → supports puts / hedges"
            )

    # ── Gate 5: Directional bias from gamma regime + SMA cross ───────────────
    if gamma_regime == "negative":
        zgl_str = (
            f"({spot_to_zgl_pct:.1f}% from ZGL)"
            if spot_to_zgl_pct is not None else ""
        )
        signals.append(
            f"Short Gamma regime {zgl_str} — "
            "dealers amplify moves in both directions; volatility expansion expected"
        )
        if sma_crossed is True:
            signals.append(
                f"SMA conflict: SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) "
                "signals bullish momentum — gamma vs price trend conflict"
            )
            # ROC5 tiebreaker: strong 5-day momentum resolves the conflict
            if price_roc5 is not None:
                if price_roc5 > 1.0:
                    signals.append(
                        f"ROC5 +{price_roc5:.1f}% — 5-day momentum confirms bullish; "
                        "resolves gamma/SMA conflict → directional_bullish"
                    )
                    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                                 vol_sma3, vol_sma20, delta_gex,
                                 StrategyBias.directional_bullish, signals, **_ctx)
                elif price_roc5 < -1.0:
                    signals.append(
                        f"ROC5 {price_roc5:.1f}% — 5-day momentum turning bearish; "
                        "overrides bullish SMA → directional_bearish"
                    )
                    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                                 vol_sma3, vol_sma20, delta_gex,
                                 StrategyBias.directional_bearish, signals, **_ctx)
                else:
                    signals.append(f"ROC5 {price_roc5:+.1f}% — momentum inconclusive; conflict unresolved")
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.unclear, signals, **_ctx)
        if sma_crossed is False:
            signals.append(
                f"SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) — "
                "price trend confirms bearish directional bias"
            )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.directional_bearish, signals, **_ctx)
        # sma_crossed is None — no SMA data
        signals.append(
            "SMA data unavailable — negative gamma but cannot confirm trend direction"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.unclear, signals, **_ctx)

    if gamma_regime == "positive":
        zgl_str = (
            f"({spot_to_zgl_pct:.1f}% from ZGL)"
            if spot_to_zgl_pct is not None else ""
        )
        signals.append(
            f"Long Gamma regime {zgl_str} — "
            "dealers dampen volatility; mean-reversion environment "
            "with slight positive return bias"
        )
        if sma_crossed is False:
            signals.append(
                f"SMA conflict: SMA10 ({_fmt(sma10)}) ≤ SMA50 ({_fmt(sma50)}) "
                "signals bearish momentum — gamma vs price trend conflict"
            )
            # ROC5 tiebreaker
            if price_roc5 is not None:
                if price_roc5 < -1.0:
                    signals.append(
                        f"ROC5 {price_roc5:.1f}% — 5-day momentum confirms bearish; "
                        "resolves gamma/SMA conflict → directional_bearish"
                    )
                    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                                 vol_sma3, vol_sma20, delta_gex,
                                 StrategyBias.directional_bearish, signals, **_ctx)
                elif price_roc5 > 1.0:
                    signals.append(
                        f"ROC5 +{price_roc5:.1f}% — near-term bounce in positive gamma; "
                        "SMA bearish context remains"
                    )
                else:
                    signals.append(f"ROC5 {price_roc5:+.1f}% — momentum inconclusive; conflict unresolved")
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.unclear, signals, **_ctx)
        if sma_crossed is True:
            signals.append(
                f"SMA10 ({_fmt(sma10)}) > SMA50 ({_fmt(sma50)}) — "
                "price trend confirms bullish directional bias"
            )
            return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                         sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                         spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                         vol_sma3, vol_sma20, delta_gex,
                         StrategyBias.directional_bullish, signals, **_ctx)
        # sma_crossed is None — no SMA data
        signals.append(
            "SMA data unavailable — positive gamma but cannot confirm trend direction"
        )
        return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                     sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                     spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                     vol_sma3, vol_sma20, delta_gex,
                     StrategyBias.unclear, signals, **_ctx)

    # ── Fallback ─────────────────────────────────────────────────────────────
    signals.append("Insufficient regime data — no strong directional edge")
    return _make(ticker, gamma_regime, iv_gex_signal, sma10, sma50,
                 sma_crossed, vix_current, vix_10ma, vix_dev_pct, vix_rsi,
                 spot_to_zgl_pct, iv_percentile, hmm_state, hmm_prob,
                 vol_sma3, vol_sma20, delta_gex,
                 StrategyBias.unclear, signals, **_ctx)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _append_scope_guard_signal(
    signals: list[str],
    total_gex: float | None,
) -> None:
    if total_gex is not None and abs(total_gex) < _MIN_TOTAL_GEX_USD:
        abs_m = abs(total_gex) / 1_000_000
        signals.append(
            f"Scope guard: low absolute GEX (${abs_m:.0f}M < $100M threshold) — "
            "gamma signals calibrated for large-cap/index; use with caution on this ticker"
        )


def _append_0dte_signal(
    signals: list[str],
    gex_0dte_pct: float | None,
) -> None:
    if gex_0dte_pct is None:
        return
    if gex_0dte_pct > 50:
        signals.append(
            f"0DTE dominance: {gex_0dte_pct:.0f}% of total GEX from same-day expiry — "
            "gamma resets at close; structural support is intraday only"
        )
    elif gex_0dte_pct > 30:
        signals.append(
            f"0DTE elevated: {gex_0dte_pct:.0f}% of total GEX from same-day expiry — "
            "near-term hedging pressure; watch for sharp intraday reversals"
        )


def _append_breadth_signal(
    signals: list[str],
    breadth_proxy: float | None,
) -> None:
    if breadth_proxy is None:
        return
    if breadth_proxy < -1.5:
        signals.append(
            f"Breadth divergence: RSP/SPY z-score {breadth_proxy:.1f} — "
            "equal-weight underperforming; narrow rally, mean-reversion risk elevated"
        )
    elif breadth_proxy > 1.5:
        signals.append(
            f"Breadth confirmation: RSP/SPY z-score {breadth_proxy:.1f} — "
            "broad participation; rally has structural backing"
        )


def _append_volume_signal(
    signals: list[str],
    vol_sma3: float | None,
    vol_sma20: float | None,
) -> None:
    """Append a volume context signal. Called unconditionally."""
    if vol_sma3 is not None and vol_sma20 is not None and vol_sma20 > 0:
        ratio = vol_sma3 / vol_sma20
        if vol_sma3 > vol_sma20:
            signals.append(
                f"Volume surge: SMA3 ({vol_sma3:,.0f}) > SMA20 ({vol_sma20:,.0f}) "
                f"[{ratio:.2f}x] — above-average participation; "
                "confirms move conviction"
            )
        else:
            signals.append(
                f"Volume light: SMA3 ({vol_sma3:,.0f}) < SMA20 ({vol_sma20:,.0f}) "
                f"[{ratio:.2f}x] — below-average participation; "
                "treat directional bias with caution"
            )


def _append_delta_gex_signal(
    signals: list[str],
    delta_gex: float | None,
    gamma_regime: str,
) -> None:
    """
    Append a deltaGex transition signal when GEX is swinging sharply.

    The transition from deep negative GEX to positive is the empirically
    strongest directional long signal in the gamma literature (e.g. Oct 2023
    SPY -$3B GEX → 15% rally). A large positive deltaGex while still in or
    just exiting negative gamma is a high-conviction bottoming indicator.
    """
    if delta_gex is None:
        return

    abs_dgex = abs(delta_gex)
    if abs_dgex < 50:  # below $50M daily change — not significant
        return

    fmt = (
        f"${abs_dgex / 1000:.1f}B" if abs_dgex >= 1000
        else f"${abs_dgex:.0f}M"
    )

    if delta_gex > 0 and gamma_regime == "negative":
        signals.append(
            f"DeltaGex: +{fmt} day-over-day while in negative gamma — "
            "GEX recovering toward flip; potential bottoming signal "
            "(cf. Oct 2023 washout-to-rally pattern)"
        )
    elif delta_gex > 0 and gamma_regime == "positive":
        signals.append(
            f"DeltaGex: +{fmt} day-over-day — "
            "positive gamma deepening; dealer cushion strengthening"
        )
    elif delta_gex < 0 and gamma_regime == "positive":
        signals.append(
            f"DeltaGex: -{fmt} day-over-day — "
            "positive gamma eroding; glide path toward ZGL flip"
        )
    elif delta_gex < 0 and gamma_regime == "negative":
        signals.append(
            f"DeltaGex: -{fmt} day-over-day in negative gamma — "
            "dealers increasingly short gamma; washout risk elevated"
        )


def _make(
    ticker, gamma_regime, iv_gex_signal, sma10, sma50, sma_crossed,
    vix_current, vix_10ma, vix_dev_pct, vix_rsi, spot_to_zgl_pct,
    iv_percentile, hmm_state, hmm_prob, vol_sma3, vol_sma20, delta_gex,
    bias, signals,
    vix_term_structure_ratio=None, vvix_current=None, vvix_10ma=None,
    spot_to_vt_pct=None, breadth_proxy=None, price_roc5=None,
    total_gex=None, gex_0dte=None, gex_0dte_pct=None,
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
        delta_gex=delta_gex,
        strategy_bias=bias,
        signals=signals,
        vix_term_structure_ratio=vix_term_structure_ratio,
        vvix_current=vvix_current,
        vvix_10ma=vvix_10ma,
        spot_to_vt_pct=spot_to_vt_pct,
        breadth_proxy=breadth_proxy,
        price_roc5=price_roc5,
        total_gex=total_gex,
        gex_0dte=gex_0dte,
        gex_0dte_pct=gex_0dte_pct,
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