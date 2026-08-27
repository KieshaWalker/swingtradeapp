from __future__ import annotations
from typing import Optional

# =============================================================================
# core/ml_utils.py
# =============================================================================
# Small numeric helpers shared by the regime ML feature pipeline.
#
# Kept in core/ rather than inside services/regime_ml_service.py because the
# trainer and the inference service must compute features IDENTICALLY. A
# feature engineered one way at training time and another way at inference is
# the classic silent model-quality bug — training/serving skew — and it shows
# up as a model that validates well and performs badly live. One shared
# implementation makes that impossible by construction.
# =============================================================================

import numpy as np


def _slope(values:Optional[list[float]]) ->Optional[float]:
    """OLS slope of non-None values over their indices.

    Turns a level series into a TREND feature — the "_trend" half of the
    feature pairs in RegimeFeatures (spot_to_zgl_trend, ivp_trend). Direction of
    travel carries information the level does not: sitting 2% above the gamma
    flip while falling toward it is a different state from sitting 2% above it
    while rising away.

    Missing observations are DROPPED, not interpolated or zero-filled, and the
    surviving points keep their ORIGINAL indices as the x-axis. So a gap in the
    series widens the x-spacing rather than compressing the trend — a value 5
    days later is treated as 5 days later even if the 4 days between are
    missing. Zero-filling instead would invent a violent move toward zero and
    back; dropping is the honest handling of a stale-data gap.

    Returns None rather than 0.0 when fewer than two points survive. That
    distinction matters downstream: None means "unknown", which the confidence
    score counts as a missing feature, whereas 0.0 would assert a genuinely
    flat trend.

    Implementation note: `xs -= xs.mean()` centres the x values, which makes
    the OLS slope reduce to the single dot-product ratio below — no intercept
    term is needed because a centred x has zero mean by construction. The
    `denom` guard catches the degenerate case where every surviving point sits
    at the same index, which cannot happen with enumerate() but costs nothing
    to defend against.
    """
    pts = [(i, v) for i, v in enumerate(values) if v is not None]
    if len(pts) < 2:
        return None
    xs = np.array([p[0] for p in pts], dtype=float)
    ys = np.array([p[1] for p in pts], dtype=float)
    xs -= xs.mean()
    denom = float(np.dot(xs, xs))
    return float(np.dot(xs, ys) / denom) if denom else None
