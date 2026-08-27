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
#
# WHY AN HMM RATHER THAN A VIX THRESHOLD. A fixed cut ("VIX above 20 = high
# vol") is wrong in both directions: 20 was elevated in 2017 and calm in 2022.
# A hidden Markov model instead infers TWO LATENT STATES from the data itself
# and reports which one the market is currently in, so the boundary adapts to
# whatever regime the sample contains.
#
# It also yields something a threshold cannot: a POSTERIOR PROBABILITY. "85%
# likely in the high-vol state" is a materially different signal from "51%
# likely", and both would read identically under a hard cut.
#
# WHERE THE OUTPUT GOES: hmm_state is Gate 1 of the decision table in
# regime_service — the highest-priority rule after the VVIX override — so a
# high-vol classification forces `straddle_only` regardless of gamma
# positioning. It is also a feature in the regime ML model.
#
# THE STATE LABELS ARE ASSIGNED POST-FIT, not learned. An HMM has no idea which
# of its two states is the "high vol" one — the numbering is arbitrary and can
# swap between fits. The code below identifies them by comparing fitted mean VIX
# levels, which is what makes the output stable across runs.
#
# FAILS SOFT, ALWAYS. Every failure path — hmmlearn missing, too little data, a
# fit that raises — returns None, and callers simply skip the rules that need a
# state. The regime classifier is designed to degrade rather than break.

from __future__ import annotations

import math
from typing import Optional
import logging
from dataclasses import dataclass
from enum import Enum

import numpy as np

log = logging.getLogger(__name__)

# Two states, not three or more. A low/high split is the distinction the
# strategy actually acts on, and more states would need far more data to
# identify stably while producing a label nothing downstream consumes.
_N_STATES = 2
# Floor on observations. Fitting a 2-state Gaussian HMM means estimating means,
# variances and transition probabilities — below ~30 points those are noise, and
# the model will still happily converge to something meaningless.
# NOTE jobs/regime_pull.py deliberately supplies ~500 observations (two years),
# far above this floor, because stable state identification needs to have SEEN
# both regimes in the sample.
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
    # Strip None and NaN before any numeric work — a single NaN propagates
    # through the whole fit and silently poisons every parameter.
    # NOTE this DROPS bad points rather than gapping the series, so the model
    # treats the surrounding days as adjacent. Acceptable for a regime read.
    # Strip None and NaN before any numeric work
    clean = [v for v in vix_closes if v is not None and not math.isnan(float(v))]
    if len(clean) < _MIN_OBSERVATIONS:
        return None

    # Imported lazily, inside the function, so hmmlearn is an OPTIONAL
    # dependency: the whole service still boots and every other endpoint works
    # if it is absent. Only the HMM gate goes dark.
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

        # covariance_type="diag" assumes the two features are uncorrelated
        # WITHIN a state. Not strictly true — big moves cluster at high levels —
        # but a full covariance matrix doubles the parameters to estimate and
        # destabilizes the fit on this sample size.
        #
        # random_state=42 pins the EM initialization. Essential rather than
        # cosmetic: EM converges to a local optimum, so an unseeded fit could
        # return a different regime for the same input on consecutive runs, and
        # the classification would flicker between hourly pipeline passes.
        model = GaussianHMM(
            n_components=_N_STATES,
            covariance_type="diag",
            n_iter=200,
            random_state=42,
        )
        model.fit(X)

        # Non-convergence is logged but NOT fatal — a fit that ran out of
        # iterations is usually still informative, and refusing to classify
        # would disable the highest-priority gate in the decision table.
        if hasattr(model, "monitor_") and not model.monitor_.converged:
            log.warning("hmm_not_converged n_iter=%d — regime result may be unreliable", model.n_iter)

        # Identify which state is "high vol" by unscaling the level means back to
        # original VIX units (scaled_mean * std + mean).
        # STATE IDENTIFICATION — see the header. The model's own state numbering
        # is arbitrary, so the level-feature means are unscaled back to real VIX
        # units and the higher one is declared the high-vol state. Without this
        # step the returned label would be meaningless.
        means_scaled = model.means_[:, 1]
        means_level  = means_scaled * lv_scale + lv_mean
        high_state_idx = int(np.argmax(means_level))
        low_state_idx  = 1 - high_state_idx

        # Decode current state — use most recent observation
        # Viterbi finds the single most likely STATE SEQUENCE over the whole
        # series, so the last element is the current state in the context of
        # everything before it — more stable than classifying today alone.
        _, state_seq = model.decode(X, algorithm="viterbi")
        current_state_idx = int(state_seq[-1])

        # Posterior probability for current state at last observation
        # Posterior confidence in the decoded state. Note predict_proba is a
        # per-observation forward-backward result while the state above came
        # from Viterbi, so on rare ambiguous days the most probable single-point
        # state can differ from the sequence-optimal one — in which case this
        # probability will be near 0.5, correctly signalling low confidence.
        posteriors = model.predict_proba(X)
        current_prob = float(posteriors[-1, current_state_idx])

        state = (
            HmmVolState.high_vol if current_state_idx == high_state_idx
            else HmmVolState.low_vol
        )

        # The two fitted means are returned so a caller can see WHERE the model
        # drew the line — e.g. "low ≈ 14, high ≈ 28" makes the classification
        # interpretable rather than a bare label.
        return HmmRegimeResult(
            state=state,
            state_probability=current_prob,
            low_vol_mean=float(means_level[low_state_idx]),
            high_vol_mean=float(means_level[high_state_idx]),
            n_observations=len(closes),
            sufficient_data=True,
        )

    # Broad catch: a singular covariance matrix, a degenerate sample, or a
    # hmmlearn version difference must all degrade to "no HMM signal" rather
    # than taking down the regime pipeline for every ticker.
    except Exception as exc:
        log.warning("hmm_fit_failed error=%s", exc)
        return None
