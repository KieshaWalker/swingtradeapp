# =============================================================================
# services/hmm_regime.py
# =============================================================================
# Hidden Markov Model regime classifier for VIX closes.
#
# 2-state GaussianHMM:
#   State 0 / State 1 → identified post-fit by mean VIX level.
#   Low-vol state:  dealers are long gamma, vol compressed → directional trades.
#   High-vol state: dealers are short gamma, vol expanding → straddle or puts only.
#
# Requires hmmlearn (pip install hmmlearn).
# =============================================================================

from __future__ import annotations

import math
from typing import Optional
import logging
from dataclasses import dataclass
from enum import Enum

import numpy as np

log = logging.getLogger(__name__)

_N_STATES = 2
_MIN_OBSERVATIONS = 30


class HmmVolState(str, Enum):
    low_vol  = "low_vol"    # compressed vol regime — directional trades
    high_vol = "high_vol"   # expanding vol regime  — straddles / puts


@dataclass
class HmmRegimeResult:
    state:            HmmVolState
    state_probability: float      # posterior probability for current state (0–1)
    low_vol_mean:     float        # fitted mean VIX for the low-vol state
    high_vol_mean:    float        # fitted mean VIX for the high-vol state
    n_observations:   int
    sufficient_data:  bool


def classify_vix_regime(vix_closes: list[float]) ->Optional[HmmRegimeResult]:
    """Fit a 2-state GaussianHMM on VIX closes and return the current regime.

    Returns None if hmmlearn is unavailable or there is insufficient data.
    """
    # Strip None and NaN before any numeric work
    clean = [v for v in vix_closes if v is not None and not math.isnan(float(v))]
    if len(clean) < _MIN_OBSERVATIONS:
        return None

    try:
        from hmmlearn.hmm import GaussianHMM
    except ImportError:
        log.warning("hmmlearn not installed — HMM regime disabled")
        return None

    try:
        closes = np.array(clean, dtype=float)

        # Features: [log-return, level] — log-returns capture regime transitions;
        # level anchors the state to absolute VIX magnitude.
        log_returns = np.diff(np.log(np.maximum(closes, 1e-6)))
        levels      = closes[1:]   # align with log-returns (drop first close)

        # Standardize before fitting — log-returns (~0.02) and VIX levels (~15–80)
        # differ by ~1000x; without scaling the emission model is dominated by the
        # level feature and log-returns carry no signal.
        lr_mean, lr_std = float(np.mean(log_returns)), float(np.std(log_returns))
        lv_mean, lv_std = float(np.mean(levels)),     float(np.std(levels))
        lr_scale = lr_std if lr_std > 1e-8 else 1.0
        lv_scale = lv_std if lv_std > 1e-8 else 1.0

        X = np.column_stack([
            (log_returns - lr_mean) / lr_scale,
            (levels      - lv_mean) / lv_scale,
        ])

        model = GaussianHMM(
            n_components=_N_STATES,
            covariance_type="diag",
            n_iter=200,
            random_state=42,
        )
        model.fit(X)

        if hasattr(model, "monitor_") and not model.monitor_.converged:
            log.warning("hmm_not_converged n_iter=%d — regime result may be unreliable", model.n_iter)

        # Identify which state is "high vol" by unscaling the level means back to
        # original VIX units (scaled_mean * std + mean).
        means_scaled = model.means_[:, 1]
        means_level  = means_scaled * lv_scale + lv_mean
        high_state_idx = int(np.argmax(means_level))
        low_state_idx  = 1 - high_state_idx

        # Decode current state — use most recent observation
        _, state_seq = model.decode(X, algorithm="viterbi")
        current_state_idx = int(state_seq[-1])

        # Posterior probability for current state at last observation
        posteriors = model.predict_proba(X)
        current_prob = float(posteriors[-1, current_state_idx])

        state = (
            HmmVolState.high_vol if current_state_idx == high_state_idx
            else HmmVolState.low_vol
        )

        return HmmRegimeResult(
            state=state,
            state_probability=current_prob,
            low_vol_mean=float(means_level[low_state_idx]),
            high_vol_mean=float(means_level[high_state_idx]),
            n_observations=len(closes),
            sufficient_data=True,
        )

    except Exception as exc:
        log.warning("hmm_fit_failed error=%s", exc)
        return None
