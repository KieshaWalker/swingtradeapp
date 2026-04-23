# =============================================================================
# services/macro_score.py
# =============================================================================
# 8-component macro regime score (0–100).
# Fetches time-series data directly from Supabase; returns scored components.
#
# Score weights (total = 100 pts):
#   VIX Level          20   Yield Curve 2s10s  15   Fed Trajectory  15
#   SPY Trend          15   Dollar (DXY)       10   HY Credit OAS   10
#   IG Credit OAS       5   Gold/Copper        10
#
# Z-score normalization (per component, up to 252 obs):
#   Z = (current − μ) / σ  (Bessel-corrected sample std)
#   pct = clamp(Z, −3, 3) + 3) / 6  → [0, 1] → × maxScore
#   Inverted for metrics where high = bad (VIX, spreads, DXY).
#   Falls back to maxScore/2 when < 10 observations exist.
#
# Regimes: Risk-On (≥86) | Neutral-Bullish (≥71) | Neutral (≥45)
#           Caution (≥30) | Crisis (<30)
# =============================================================================
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

from core.supabase_client import get_supabase

_MAX_HISTORY = 252
_MIN_HISTORY = 10


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

    def to_dict(self) -> dict:
        return {
            "total":           round(self.total, 2),
            "regime":          self.regime,
            "has_enough_data": self.has_enough_data,
            "used_z_scores":   self.used_z_scores,
            "components": [
                {
                    "name":        c.name,
                    "description": c.description,
                    "score":       round(c.score, 4),
                    "max_score":   c.max_score,
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


def _z_to_score(z: Optional[float], max_score: float, *, invert: bool = False) -> float:
    if z is None:
        return max_score / 2
    adjusted = -z if invert else z
    pct = min(1.0, max(0.0, (min(3.0, max(-3.0, adjusted)) + 3) / 6))
    return pct * max_score


def _no_data(name: str, max_score: float) -> MacroSubScore:
    return MacroSubScore(
        name=name,
        description="",
        score=max_score / 2,
        max_score=max_score,
        signal="No data — will populate over time",
        detail="Insufficient history in Supabase",
        is_positive=True,
        z_scored=False,
    )


# ── Supabase fetch helpers ─────────────────────────────────────────────────────

def _quote_history(symbol: str) -> list[float]:
    """newest-first price list from economy_quote_snapshots"""
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
    """newest-first value list from economy_indicator_snapshots"""
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


# ── 1. VIX Level — 20 pts ─────────────────────────────────────────────────────

def _vix_component() -> MacroSubScore:
    values = _quote_history("VIXCLS")
    source = "VIX"
    if not values:
        values = _quote_history("VIXY")
        source = "VIXY"
    if not values:
        return _no_data("VIX Level", 20)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, 20, invert=True)

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
        max_score=20,
        signal=f"{source} {current:.2f} — {level} Fear" + (f" · {len(values)}d" if z is not None else ""),
        detail="Vol subdued — supports risk-taking" if score >= 10 else "Elevated vol signals institutional hedging",
        is_positive=score >= 10,
        z_scored=z is not None,
    )


# ── 2. Yield Curve 2s10s — 15 pts ────────────────────────────────────────────

def _yield_curve_component() -> MacroSubScore:
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
        return _no_data("Yield Curve 2s10s", 15)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, 15)

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
        max_score=15,
        signal=f"10Y−2Y: {shape}" + (f" · {len(values)}d" if z is not None else "") + (" · FRED" if from_fred else ""),
        detail="Normal curve — expansion environment" if current > 0 else "Inverted — recession probability elevated",
        is_positive=current > 0,
        z_scored=z is not None,
    )


# ── 3. Fed Trajectory — 15 pts ───────────────────────────────────────────────

def _fed_trajectory_component() -> MacroSubScore:
    values = _indicator_history("fred_dff")
    from_fred = bool(values)
    if not values:
        values = _indicator_history("federalFunds")
    if len(values) < 2:
        return _no_data("Fed Trajectory", 15)

    latest = values[0]
    step = 126 if from_fred else 6
    lookback = min(step - 1, len(values) - 1)
    prior = values[lookback]
    delta = latest - prior

    deltas = [values[i] - values[i + step] for i in range(len(values) - step)]
    z = _z(delta, deltas)
    score = _z_to_score(z, 15, invert=True)

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
        max_score=15,
        signal=f"FFR {latest:.2f}% — {trend}" + (f" · {len(values)}d" if z is not None else "") + (" · FRED" if from_fred else ""),
        detail=detail,
        is_positive=delta <= 0.1,
        z_scored=z is not None,
    )


# ── 4. SPY Trend — 15 pts ────────────────────────────────────────────────────

def _spy_trend_component() -> MacroSubScore:
    prices = _quote_history("SPY")
    if len(prices) < 5:
        return _no_data("SPY Trend", 15)

    deviations: list[float] = []
    for i in range(len(prices) - 30):
        window = prices[i + 1: i + 31]
        ma = sum(window) / len(window)
        deviations.append(((prices[i] - ma) / ma) * 100)

    ma_len = min(30, len(prices) - 1)
    ma30 = sum(prices[1: ma_len + 1]) / ma_len
    current_dev = ((prices[0] - ma30) / ma30) * 100

    z = _z(current_dev, deviations[1:] if deviations else [])
    score = _z_to_score(z, 15)

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
        max_score=15,
        signal=f"SPY ${prices[0]:.2f} — {trend}" + (f" · {len(deviations)}d" if z is not None else ""),
        detail="Above 30d MA — trend intact" if current_dev > 0 else "Below 30d MA — momentum deteriorating",
        is_positive=current_dev > -1,
        z_scored=z is not None,
    )


# ── 5. Dollar (DXY) — 10 pts ─────────────────────────────────────────────────

def _dollar_component() -> MacroSubScore:
    prices = _quote_history("$DXY")
    if len(prices) < 5:
        return _no_data("Dollar (DXY)", 10)

    changes: list[float] = []
    for i in range(len(prices) - 30):
        changes.append(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100)

    lookback = min(30, len(prices) - 1)
    current_change = ((prices[0] - prices[lookback]) / prices[lookback]) * 100

    z = _z(current_change, changes[1:] if changes else [])
    score = _z_to_score(z, 10, invert=True)

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
        max_score=10,
        signal=f"DXY {prices[0]:.2f} — {trend}" + (f" · {len(changes)}d" if z is not None else ""),
        detail=("Falling dollar supports global risk assets" if current_change < 0
                else "Dollar stable — neutral for risk" if abs(current_change) <= 1
                else "Rising dollar creates headwinds"),
        is_positive=current_change < 1,
        z_scored=z is not None,
    )


# ── 6. HY Credit OAS — 10 pts ────────────────────────────────────────────────

def _hy_oas_component() -> MacroSubScore:
    values = _indicator_history("fred_bamlh0a0hym2")
    if values:
        current = values[0]
        z = _z(current, values[1:])
        score = _z_to_score(z, 10, invert=True)
        level = ("Tight (<300 bps)" if current < 300 else
                 f"Normal ({current:.0f} bps)" if current < 450 else
                 f"Wide ({current:.0f} bps)" if current < 700 else
                 f"Stressed ({current:.0f} bps)")
        return MacroSubScore(
            name="HY Credit OAS",
            description="ICE BofA HY spread — tighter = risk-on",
            score=score,
            max_score=10,
            signal=f"HY OAS {current:.0f} bps — {level}" + (f" · {len(values)}d · FRED" if z is not None else " · FRED"),
            detail="Credit market healthy — spreads contained" if current < 400 else "Spreads elevated — credit stress building",
            is_positive=current < 500,
            z_scored=z is not None,
        )

    # Fallback: HYG price trend
    prices = _quote_history("HYG")
    if len(prices) < 5:
        return _no_data("HY Credit OAS", 10)

    changes: list[float] = []
    for i in range(len(prices) - 30):
        changes.append(((prices[i] - prices[i + 30]) / prices[i + 30]) * 100)

    lb = min(30, len(prices) - 1)
    current_change = ((prices[0] - prices[lb]) / prices[lb]) * 100
    z = _z(current_change, changes[1:] if changes else [])
    score = _z_to_score(z, 10)

    return MacroSubScore(
        name="HY Credit OAS",
        description="HYG price trend (FRED loading…)",
        score=score,
        max_score=10,
        signal=f"HYG ${prices[0]:.2f} · {'+' if current_change >= 0 else ''}{current_change:.1f}%",
        detail="Credit improving — risk appetite expanding" if current_change > 0 else "Credit weakening — watch for equity lag",
        is_positive=current_change > -0.5,
        z_scored=z is not None,
    )


# ── 7. IG Credit OAS — 5 pts ─────────────────────────────────────────────────

def _ig_oas_component() -> MacroSubScore:
    values = _indicator_history("fred_bamlc0a0cm")
    if not values:
        return _no_data("IG Credit OAS", 5)

    current = values[0]
    z = _z(current, values[1:])
    score = _z_to_score(z, 5, invert=True)

    level = ("Tight (<80 bps)" if current < 80 else
             f"Normal ({current:.0f} bps)" if current < 130 else
             f"Wide ({current:.0f} bps)" if current < 200 else
             f"Stressed ({current:.0f} bps)")

    return MacroSubScore(
        name="IG Credit OAS",
        description="ICE BofA IG spread — tighter = risk-on",
        score=score,
        max_score=5,
        signal=f"IG OAS {current:.0f} bps — {level}" + (f" · {len(values)}d · FRED" if z is not None else " · FRED"),
        detail="IG spreads benign — investment grade healthy" if current < 130 else "IG spreads elevated — broad credit concern",
        is_positive=current < 150,
        z_scored=z is not None,
    )


# ── 8. Gold/Copper — 10 pts ──────────────────────────────────────────────────

def _gold_copper_component() -> MacroSubScore:
    gold_prices = _quote_history("/GC")
    copx_prices = _quote_history("COPX")

    if len(gold_prices) < 5 or len(copx_prices) < 5:
        return _no_data("Gold/Copper", 10)

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
    score = _z_to_score(z, 10)

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
        max_score=10,
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
    components = [
        _vix_component(),
        _yield_curve_component(),
        _fed_trajectory_component(),
        _spy_trend_component(),
        _dollar_component(),
        _hy_oas_component(),
        _ig_oas_component(),
        _gold_copper_component(),
    ]

    z_scored_count = sum(1 for c in components if c.z_scored)
    total = sum(c.score for c in components)

    return MacroScore(
        total=total,
        regime=_regime_for(total),
        components=components,
        has_enough_data=z_scored_count >= 4,
        used_z_scores=z_scored_count >= 5,
    )
