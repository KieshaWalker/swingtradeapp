# =============================================================================
# services/macro_score.py
# =============================================================================
# 8-component macro regime score (0–100).
# Fetches time-series data directly from Supabase; returns scored components.
#
# Component weights are derived from Spearman Information Coefficients (IC):
#   IC_k = corr(rolling_z_score_k, SPY_21d_forward_return)  over available history
#   weight_k = (|IC_k| / Σ|IC|) × (100 − floor_total) + floor_per_component
#
# Falls back to equal weights (12.5 each) when data is insufficient.
#
# Z-score normalization (per component, up to 252 obs):
#   Z = (current − μ) / σ  (Bessel-corrected sample std)
#   pct = clamp(Z, −3, 3) + 3) / 6  → [0, 1] → × weight
#   Inverted for metrics where high = bad (VIX, spreads, DXY, high FFR).
#   Falls back to weight/2 when < 10 observations exist.
#
# Regimes: Risk-On (≥86) | Neutral-Bullish (≥71) | Neutral (≥45)
#           Caution (≥30) | Crisis (<30)
# =============================================================================
from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from typing import Optional

from core.supabase_client import get_supabase

log = logging.getLogger(__name__)

_MAX_HISTORY = 252
_MIN_HISTORY = 10

# ---------------------------------------------------------------------------
# IC-based weight calibration parameters
# ---------------------------------------------------------------------------

_IC_FORWARD_WINDOW     = 21    # SPY trading days for IC lookforward
_MIN_IC_OBS            = 40    # minimum paired (z, fwd_return) observations
_MIN_COMPONENT_WEIGHT  = 2.0   # per-component floor (prevents zeroing any signal)

_EQUAL_WEIGHTS: dict[str, float] = {
    "vix":          12.5,
    "yield_curve":  12.5,
    "fed":          12.5,
    "spy_trend":    12.5,
    "dxy":          12.5,
    "hy_oas":       12.5,
    "ig_oas":       12.5,
    "gold_copper":  12.5,
}

_calibrated_weights: dict[str, float] | None = None


# ── Models ────────────────────────────────────────────────────────────────────

@dataclass
class MacroSubScore:
    name: str
    description: str
    score: float
    max_score: float
    signal: str
    detail: str
    is_positive: bool
    z_scored: bool = False


@dataclass
class MacroScore:
    total: float
    regime: str               # "Risk-On" | "Neutral-Bullish" | "Neutral" | "Caution" | "Crisis"
    components: list[MacroSubScore]
    has_enough_data: bool
    used_z_scores: bool
    weights_source: str       # "ic_calibrated" | "equal"

    def to_dict(self) -> dict:
        return {
            "total":           round(self.total, 2),
            "regime":          self.regime,
            "has_enough_data": self.has_enough_data,
            "used_z_scores":   self.used_z_scores,
            "weights_source":  self.weights_source,
            "components": [
                {
                    "name":        c.name,
                    "description": c.description,
                    "score":       round(c.score, 4),
                    "max_score":   round(c.max_score, 4),
                    "signal":      c.signal,
                    "detail":      c.detail,
                    "is_positive": c.is_positive,
                    "z_scored":    c.z_scored,
                }
                for c in self.components
            ],
        }


# ── Z-score helpers ───────────────────────────────────────────────────────────

def _z(current: float, history: list[float]) -> Optional[float]:
    if len(history) < _MIN_HISTORY:
        return None
    n = len(history)
    mean = sum(history) / n
    variance = sum((x - mean) ** 2 for x in history) / (n - 1)
    std = math.sqrt(variance)
    if std < 0.0001:
        return 0.0
    return (current - mean) / std


def _z_to_score(z: Optional[float], weight: float, *, invert: bool = False) -> float:
    if z is None:
        return weight / 2
    adjusted = -z if invert else z
    pct = min(1.0, max(0.0, (min(3.0, max(-3.0, adjusted)) + 3) / 6))
    return pct * weight


def _no_data(name: str, weight: float) -> MacroSubScore:
    return MacroSubScore(
        name=name,
        description="",
        score=weight / 2,
        max_score=weight,
        signal="No data — will populate over time",
        detail="Insufficient history in Supabase",
        is_positive=True,
        z_scored=False,
    )


# ── IC calibration helpers ────────────────────────────────────────────────────

def _pearson(xs: list[float], ys: list[float]) -> float:
    n = len(xs)
    if n < 2:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sx  = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy  = math.sqrt(sum((y - my) ** 2 for y in ys))
    if sx < 1e-9 or sy < 1e-9:
        return 0.0
    return cov / (sx * sy)


def _spearman(xs: list[float], ys: list[float]) -> float:
    """Rank-based correlation — more robust than Pearson for fat-tailed financial data."""
    def _ranks(vals: list[float]) -> list[float]:
        order = sorted(range(len(vals)), key=lambda i: vals[i])
        r = [0.0] * len(vals)
        for rank, orig in enumerate(order):
            r[orig] = float(rank)
        return r
    return _pearson(_ranks(xs), _ranks(ys))


def _ic_for_series(
    signal: list[float],
    spy: list[float],
    *,
    invert: bool,
) -> float:
    """
    Compute Spearman IC between the rolling Z-score of `signal` and the
    SPY 21-day forward return.  Both lists are newest-first.

    At index k (k days ago), the rolling Z-score is computed from
    signal[k] vs signal[k+1:] (older history), and the forward return is
    (spy[k - fw] - spy[k]) / spy[k]  where k - fw is a more-recent index.
    Valid only for k ≥ fw so the forward return exists.
    """
    fw = _IC_FORWARD_WINDOW
    n  = min(len(signal), len(spy))
    xs: list[float] = []
    ys: list[float] = []

    for k in range(fw, n - 1):
        z = _z(signal[k], signal[k + 1:])
        if z is None:
            continue
        if spy[k] == 0:
            continue
        fwd = (spy[k - fw] - spy[k]) / spy[k]
        xs.append(-z if invert else z)
        ys.append(fwd)

    if len(xs) < _MIN_IC_OBS:
        return 0.0
    return _spearman(xs, ys)


def calibrate_macro_weights() -> dict[str, float]:
    """
    Derive component weights from Spearman IC vs SPY 21-day forward returns.

    For each component we reconstruct the same rolling Z-score signal used at
    score time, then correlate it with SPY forward returns over the available
    history.  Weights are proportional to |IC|, normalized to sum to 100 with
    a per-component floor of _MIN_COMPONENT_WEIGHT (prevents any signal from
    being zeroed out during data-sparse periods).

    Falls back to equal weights when SPY history is too short.
    Caches result in module-level _calibrated_weights.
    """
    global _calibrated_weights

    spy = _quote_history("SPY")
    if len(spy) < _IC_FORWARD_WINDOW + _MIN_IC_OBS:
        log.warning("macro_calibrate insufficient_spy_history n=%d — using equal weights", len(spy))
        _calibrated_weights = None
        return dict(_EQUAL_WEIGHTS)

    ics: dict[str, float] = {}

    # VIX
    vix = _quote_history("VIXCLS") or _quote_history("VIXY")
    ics["vix"] = (
        _ic_for_series(vix, spy, invert=True)
        if len(vix) >= _MIN_IC_OBS + 2 else 0.0
    )

    # Yield Curve 2s10s: positive spread = good → invert=False
    yc = _indicator_history("fred_t10y2y")
    ics["yield_curve"] = (
        _ic_for_series(yc, spy, invert=False)
        if len(yc) >= _MIN_IC_OBS + 2 else 0.0
    )

    # Fed: higher FFR level = tighter conditions = bad → invert=True
    fed = _indicator_history("fred_dff") or _indicator_history("federalFunds")
    ics["fed"] = (
        _ic_for_series(fed, spy, invert=True)
        if len(fed) >= _MIN_IC_OBS + 2 else 0.0
    )

    # SPY Trend: deviation from 30d MA (same signal as scoring function)
    if len(spy) >= _MIN_IC_OBS + _IC_FORWARD_WINDOW + 30:
        spy_dev = [
            ((spy[i] - sum(spy[i + 1: i + 31]) / 30) / (sum(spy[i + 1: i + 31]) / 30)) * 100
            for i in range(len(spy) - 30)
        ]
        ics["spy_trend"] = _ic_for_series(spy_dev, spy, invert=False)
    else:
        ics["spy_trend"] = 0.0

    # DXY: rising dollar = bad for global risk → invert=True; use 30d change series
    dxy = _quote_history("$DXY")
    if len(dxy) >= _MIN_IC_OBS + _IC_FORWARD_WINDOW + 30:
        dxy_ch = [
            ((dxy[i] - dxy[i + 30]) / dxy[i + 30]) * 100
            for i in range(len(dxy) - 30)
        ]
        ics["dxy"] = _ic_for_series(dxy_ch, spy, invert=True)
    else:
        ics["dxy"] = 0.0

    # HY OAS: wide spreads = bad → invert=True
    hy = _indicator_history("fred_bamlh0a0hym2")
    ics["hy_oas"] = (
        _ic_for_series(hy, spy, invert=True)
        if len(hy) >= _MIN_IC_OBS + 2 else 0.0
    )

    # IG OAS: wide spreads = bad → invert=True
    ig = _indicator_history("fred_bamlc0a0cm")
    ics["ig_oas"] = (
        _ic_for_series(ig, spy, invert=True)
        if len(ig) >= _MIN_IC_OBS + 2 else 0.0
    )

    # Gold/Copper differential: copper outperforming = growth signal → invert=False
    gold = _quote_history("/GC")
    copx = _quote_history("COPX")
    if (len(gold) >= _MIN_IC_OBS + _IC_FORWARD_WINDOW + 30
            and len(copx) >= _MIN_IC_OBS + _IC_FORWARD_WINDOW + 30):
        n = min(len(gold), len(copx))
        gc_diff = [
            (((copx[i] - copx[i + 30]) / copx[i + 30])
             - ((gold[i] - gold[i + 30]) / gold[i + 30])) * 100
            for i in range(n - 30)
        ]
        ics["gold_copper"] = _ic_for_series(gc_diff, spy, invert=False)
    else:
        ics["gold_copper"] = 0.0

    # Normalize abs(IC) → weights with per-component floor
    abs_ics   = {k: abs(v) for k, v in ics.items()}
    total_ic  = sum(abs_ics.values())

    if total_ic < 1e-6:
        log.warning("macro_calibrate all_ics_near_zero — using equal weights")
        _calibrated_weights = None
        return dict(_EQUAL_WEIGHTS)

    n_comp        = len(ics)
    floor_budget  = _MIN_COMPONENT_WEIGHT * n_comp
    distributable = 100.0 - floor_budget

    weights = {
        k: _MIN_COMPONENT_WEIGHT + (abs_ics[k] / total_ic) * distributable
        for k in ics
    }
    _calibrated_weights = weights

    log.info(
        "macro_calibrate ic=[%s] weights=[%s]",
        " ".join(f"{k}:{v:.2f}" for k, v in ics.items()),
        " ".join(f"{k}:{v:.1f}" for k, v in weights.items()),
    )
    return weights


def _get_weights() -> tuple[dict[str, float], str]:
    """Return (weights_dict, source_label).  Calibrates lazily on first call."""
    global _calibrated_weights
    if _calibrated_weights is None:
        try:
            calibrate_macro_weights()
        except Exception as exc:
            log.warning("macro_calibrate_failed error=%s — using equal weights", exc)
    if _calibrated_weights is not None:
        return _calibrated_weights, "ic_calibrated"
    return dict(_EQUAL_WEIGHTS), "equal"


# ── Supabase fetch helpers ─────────────────────────────────────────────────────

def _quote_history(symbol: str) -> list[float]:
    """Newest-first price list from economy_quote_snapshots."""
    db = get_supabase()
    rows = (
        db.table("economy_quote_snapshots")
        .select("price")
        .eq("symbol", symbol)
        .order("date", desc=True)
        .limit(_MAX_HISTORY)
        .execute()
    )
    return [float(r["price"]) for r in (rows.data or []) if r.get("price") is not None]


def _indicator_history(identifier: str) -> list[float]:
    """Newest-first value list from economy_indicator_snapshots."""
    db = get_supabase()
    rows = (
        db.table("economy_indicator_snapshots")
        .select("value")
        .eq("identifier", identifier)
        .order("date", desc=True)
        .limit(_MAX_HISTORY)
        .execute()
    )
    return [float(r["value"]) for r in (rows.data or []) if r.get("value") is not None]


# ── 1. VIX Level ──────────────────────────────────────────────────────────────

def _vix_component(weight: float) -> MacroSubScore:
    values = _quote_history("VIXCLS")
    source = "VIX"
    if not values:
        values = _quote_history("VIXY")
        source = "VIXY"
    if not values:
        return _no_data("VIX Level", weight)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, weight, invert=True)

    if source == "VIX":
        level = ("Very Low" if current < 12 else "Low" if current < 17 else
                 "Elevated" if current < 22 else "High" if current < 30 else "Extreme")
    else:
        level = ("Very Low" if current < 10 else "Low" if current < 14 else
                 "Elevated" if current < 18 else "High" if current < 24 else "Extreme")

    return MacroSubScore(
        name="VIX Level",
        description="Fear gauge — lower = more bullish",
        score=score,
        max_score=weight,
        signal=f"{source} {current:.2f} — {level} Fear" + (f" · {len(values)}d" if z is not None else ""),
        detail="Vol subdued — supports risk-taking" if score >= weight / 2 else "Elevated vol signals institutional hedging",
        is_positive=score >= weight / 2,
        z_scored=z is not None,
    )


# ── 2. Yield Curve 2s10s ──────────────────────────────────────────────────────

def _yield_curve_component(weight: float) -> MacroSubScore:
    values = _indicator_history("fred_t10y2y")
    from_fred = bool(values)

    if not from_fred:
        db = get_supabase()
        rows = (
            db.table("economy_treasury_snapshots")
            .select("year2,year10")
            .order("date", desc=True)
            .limit(_MAX_HISTORY)
            .execute()
        )
        values = [
            float(r["year10"]) - float(r["year2"])
            for r in (rows.data or [])
            if r.get("year2") is not None and r.get("year10") is not None
        ]

    if not values:
        return _no_data("Yield Curve 2s10s", weight)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, weight)

    if current > 1.5:
        shape = f"Steep (+{current:.2f}%)"
    elif current > 0.5:
        shape = f"Positive (+{current:.2f}%)"
    elif current > 0:
        shape = f"Flat (+{current:.2f}%)"
    elif current > -0.5:
        shape = f"Inverted ({current:.2f}%)"
    else:
        shape = f"Deeply Inverted ({current:.2f}%)"

    return MacroSubScore(
        name="Yield Curve 2s10s",
        description="10Y minus 2Y treasury spread",
        score=score,
        max_score=weight,
        signal=f"10Y−2Y: {shape}" + (f" · {len(values)}d" if z is not None else "") + (" · FRED" if from_fred else ""),
        detail="Normal curve — expansion environment" if current > 0 else "Inverted — recession probability elevated",
        is_positive=current > 0,
        z_scored=z is not None,
    )


# ── 3. Fed Trajectory ─────────────────────────────────────────────────────────

def _fed_trajectory_component(weight: float) -> MacroSubScore:
    values = _indicator_history("fred_dff")
    from_fred = bool(values)
    if not values:
        values = _indicator_history("federalFunds")
    if len(values) < 2:
        return _no_data("Fed Trajectory", weight)

    latest = values[0]
    step = 126 if from_fred else 6
    lookback = min(step - 1, len(values) - 1)
    prior = values[lookback]
    delta = latest - prior

    deltas = [values[i] - values[i + step] for i in range(len(values) - step)]
    z = _z(delta, deltas)
    score = _z_to_score(z, weight, invert=True)

    if delta < -0.5:
        trend = f"Easing (−{abs(delta):.2f}%)"
    elif delta < 0:
        trend = f"Slightly Easing (−{abs(delta):.2f}%)"
    elif abs(delta) < 0.1:
        trend = f"Holding ({latest:.2f}%)"
    elif delta < 0.5:
        trend = f"Tightening (+{delta:.2f}%)"
    else:
        trend = f"Aggressive Hike (+{delta:.2f}%)"

    if delta < 0:
        detail = "Easing cycle supports equity valuations"
    elif abs(delta) < 0.1:
        detail = "Fed on hold — neutral for markets"
    else:
        detail = "Tightening cycle pressures risk assets"

    return MacroSubScore(
        name="Fed Trajectory",
        description="Fed funds 6-month trend",
        score=score,
        max_score=weight,
        signal=f"FFR {latest:.2f}% — {trend}" + (f" · {len(values)}d" if z is not None else "") + (" · FRED" if from_fred else ""),
        detail=detail,
        is_positive=delta <= 0.1,
        z_scored=z is not None,
    )


# ── 4. SPY Trend ──────────────────────────────────────────────────────────────

def _spy_trend_component(weight: float) -> MacroSubScore:
    prices = _quote_history("SPY")
    if len(prices) < 5:
        return _no_data("SPY Trend", weight)

    deviations: list[float] = []
    for i in range(len(prices) - 30):
        window = prices[i + 1: i + 31]
        ma = sum(window) / len(window)
        deviations.append(((prices[i] - ma) / ma) * 100)

    ma_len = min(30, len(prices) - 1)
    ma30 = sum(prices[1: ma_len + 1]) / ma_len
    current_dev = ((prices[0] - ma30) / ma30) * 100

    z = _z(current_dev, deviations[1:] if deviations else [])
    score = _z_to_score(z, weight)

    if current_dev > 3:
        trend = f"Strong Uptrend (+{current_dev:.1f}%)"
    elif current_dev > 1:
        trend = f"Above MA (+{current_dev:.1f}%)"
    elif current_dev > -1:
        trend = f"Near MA ({current_dev:.1f}%)"
    elif current_dev > -3:
        trend = f"Below MA ({current_dev:.1f}%)"
    else:
        trend = f"Downtrend ({current_dev:.1f}%)"

    return MacroSubScore(
        name="SPY Trend",
        description="Price vs 30-day moving average",
        score=score,
        max_score=weight,
        signal=f"SPY ${prices[0]:.2f} — {trend}" + (f" · {len(deviations)}d" if z is not None else ""),
        detail="Above 30d MA — trend intact" if current_dev > 0 else "Below 30d MA — momentum deteriorating",
        is_positive=current_dev > -1,
        z_scored=z is not None,
    )


# ── 5. Dollar (DXY) ───────────────────────────────────────────────────────────

def _dollar_component(weight: float) -> MacroSubScore:
    prices = _quote_history("$DXY")
    if len(prices) < 5:
        return _no_data("Dollar (DXY)", weight)

    changes: list[float] = []
    for i in range(len(prices) - 30):
        changes.append(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100)

    lookback = min(30, len(prices) - 1)
    current_change = ((prices[0] - prices[lookback]) / prices[lookback]) * 100

    z = _z(current_change, changes[1:] if changes else [])
    score = _z_to_score(z, weight, invert=True)

    if current_change < -3:
        trend = f"Falling ({current_change:.1f}%)"
    elif current_change < -1:
        trend = f"Weakening ({current_change:.1f}%)"
    elif abs(current_change) <= 1:
        trend = f"Stable ({current_change:.1f}%)"
    elif current_change < 3:
        trend = f"Strengthening (+{current_change:.1f}%)"
    else:
        trend = f"Strong Rally (+{current_change:.1f}%)"

    return MacroSubScore(
        name="Dollar (DXY)",
        description="DXY 30-day trend — weak dollar = risk-on",
        score=score,
        max_score=weight,
        signal=f"DXY {prices[0]:.2f} — {trend}" + (f" · {len(changes)}d" if z is not None else ""),
        detail=("Falling dollar supports global risk assets" if current_change < 0
                else "Dollar stable — neutral for risk" if abs(current_change) <= 1
                else "Rising dollar creates headwinds"),
        is_positive=current_change < 1,
        z_scored=z is not None,
    )


# ── 6. HY Credit OAS ──────────────────────────────────────────────────────────

def _hy_oas_component(weight: float) -> MacroSubScore:
    values = _indicator_history("fred_bamlh0a0hym2")
    if values:
        current = values[0]
        z = _z(current, values[1:])
        score = _z_to_score(z, weight, invert=True)
        level = ("Tight (<300 bps)" if current < 300 else
                 f"Normal ({current:.0f} bps)" if current < 450 else
                 f"Wide ({current:.0f} bps)" if current < 700 else
                 f"Stressed ({current:.0f} bps)")
        return MacroSubScore(
            name="HY Credit OAS",
            description="ICE BofA HY spread — tighter = risk-on",
            score=score,
            max_score=weight,
            signal=f"HY OAS {current:.0f} bps — {level}" + (f" · {len(values)}d · FRED" if z is not None else " · FRED"),
            detail="Credit market healthy — spreads contained" if current < 400 else "Spreads elevated — credit stress building",
            is_positive=current < 500,
            z_scored=z is not None,
        )

    # Fallback: HYG price trend
    prices = _quote_history("HYG")
    if len(prices) < 5:
        return _no_data("HY Credit OAS", weight)

    changes: list[float] = []
    for i in range(len(prices) - 30):
        changes.append(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100)

    lb = min(30, len(prices) - 1)
    current_change = ((prices[0] - prices[lb]) / prices[lb]) * 100
    z = _z(current_change, changes[1:] if changes else [])
    score = _z_to_score(z, weight)

    return MacroSubScore(
        name="HY Credit OAS",
        description="HYG price trend (FRED loading…)",
        score=score,
        max_score=weight,
        signal=f"HYG ${prices[0]:.2f} · {'+' if current_change >= 0 else ''}{current_change:.1f}%",
        detail="Credit improving — risk appetite expanding" if current_change > 0 else "Credit weakening — watch for equity lag",
        is_positive=current_change > -0.5,
        z_scored=z is not None,
    )


# ── 7. IG Credit OAS ──────────────────────────────────────────────────────────

def _ig_oas_component(weight: float) -> MacroSubScore:
    values = _indicator_history("fred_bamlc0a0cm")
    if not values:
        return _no_data("IG Credit OAS", weight)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, weight, invert=True)

    level = ("Tight (<80 bps)" if current < 80 else
             f"Normal ({current:.0f} bps)" if current < 130 else
             f"Wide ({current:.0f} bps)" if current < 200 else
             f"Stressed ({current:.0f} bps)")

    return MacroSubScore(
        name="IG Credit OAS",
        description="ICE BofA IG spread — tighter = risk-on",
        score=score,
        max_score=weight,
        signal=f"IG OAS {current:.0f} bps — {level}" + (f" · {len(values)}d · FRED" if z is not None else " · FRED"),
        detail="IG spreads benign — investment grade healthy" if current < 130 else "IG spreads elevated — broad credit concern",
        is_positive=current < 150,
        z_scored=z is not None,
    )


# ── 8. Gold/Copper ────────────────────────────────────────────────────────────

def _gold_copper_component(weight: float) -> MacroSubScore:
    gold_prices = _quote_history("/GC")
    copx_prices = _quote_history("COPX")

    if len(gold_prices) < 5 or len(copx_prices) < 5:
        return _no_data("Gold/Copper", weight)

    def _pct_change(prices: list[float]) -> float:
        lb = min(30, len(prices) - 1)
        return ((prices[0] - prices[lb]) / prices[lb]) * 100

    gold_change = _pct_change(gold_prices)
    copx_change = _pct_change(copx_prices)
    differential = copx_change - gold_change

    min_len = min(len(gold_prices), len(copx_prices))
    diffs: list[float] = []
    for i in range(min_len - 30):
        c = ((copx_prices[i] - copx_prices[i + 30]) / copx_prices[i + 30]) * 100
        g = ((gold_prices[i] - gold_prices[i + 30]) / gold_prices[i + 30]) * 100
        diffs.append(c - g)

    z = _z(differential, diffs[1:] if diffs else [])
    score = _z_to_score(z, weight)

    if differential > 5:
        trend = f"Copper Leading (+{differential:.1f}%)"
    elif differential > 1:
        trend = f"Copper Outperforming (+{differential:.1f}%)"
    elif abs(differential) <= 1:
        trend = f"Neutral ({differential:.1f}%)"
    elif differential > -5:
        trend = f"Gold Outperforming ({differential:.1f}%)"
    else:
        trend = f"Gold Dominant ({differential:.1f}%)"

    return MacroSubScore(
        name="Gold/Copper",
        description="COPX vs gold — copper outperformance = growth",
        score=score,
        max_score=weight,
        signal=f"Cu−Au spread: {trend} · /GC" + (f" · {len(diffs)}d" if z is not None else ""),
        detail="Copper leading gold — industrial demand intact" if differential > 0 else "Gold leading copper — risk-off / growth concern",
        is_positive=differential > -1,
        z_scored=z is not None,
    )


# ── Regime label ──────────────────────────────────────────────────────────────

def _regime_for(total: float) -> str:
    if total >= 86: return "Risk-On"
    if total >= 71: return "Neutral-Bullish"
    if total >= 45: return "Neutral"
    if total >= 30: return "Caution"
    return "Crisis"


# ── Public entry point ────────────────────────────────────────────────────────

def compute_macro_score() -> MacroScore:
    w, w_source = _get_weights()

    components = [
        _vix_component(w["vix"]),
        _yield_curve_component(w["yield_curve"]),
        _fed_trajectory_component(w["fed"]),
        _spy_trend_component(w["spy_trend"]),
        _dollar_component(w["dxy"]),
        _hy_oas_component(w["hy_oas"]),
        _ig_oas_component(w["ig_oas"]),
        _gold_copper_component(w["gold_copper"]),
    ]

    z_scored_count = sum(1 for c in components if c.z_scored)
    total = sum(c.score for c in components)

    return MacroScore(
        total=total,
        regime=_regime_for(total),
        components=components,
        has_enough_data=z_scored_count >= 4,
        used_z_scores=z_scored_count >= 5,
        weights_source=w_source,
    )
