# =============================================================================
# services/regime_ml_service.py
# =============================================================================
# ML-enhanced regime transition analysis.
#
# Scoring hierarchy (best available wins):
#   1. Supervised model  — logistic regression or XGBoost trained on labeled
#      historical regime flips via /regime/train.  Uses predict_proba for
#      flip probability and derives ml_score from that.
#   2. Hand-tuned weights — fallback when no trained model exists yet.
#      Same 6 features, manually weighted.  Score ∈ [-1, +1].
#
# 4 output buckets (same regardless of scoring method):
#   stable_positive   : current=pos AND ml_score ≥  0.15
#   trending_positive : current=neg AND ml_score >  0.10  (recovering)
#   trending_negative : current=pos AND ml_score < -0.10  (at risk)
#   stable_negative   : current=neg AND ml_score ≤  0.10
# =============================================================================

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable

import numpy as np

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Module-level trained model cache
# ---------------------------------------------------------------------------
# Populated by load_trained_model() on API startup or after /regime/train.
# Shape: callable(features: list[float]) -> (flip_prob: float, score: float)
# or None when no trained model is available.
_inference_fn: Callable[[list[float]], tuple[float, float]] | None = None
_model_meta:   dict | None = None   # stored row metadata (auc_roc, trained_at, …)


def load_trained_model(supabase_client) -> bool:
    """Load the latest trained model from Supabase into module-level cache.

    Returns True if a model was successfully loaded.
    Called at API lifespan startup and after /regime/train.
    """
    global _inference_fn, _model_meta
    from .regime_ml_trainer import load_latest_model, make_inference_fn

    stored = load_latest_model(supabase_client)
    if not stored:
        log.info("regime_ml no_trained_model_found — using hand-tuned weights")
        _inference_fn = None
        _model_meta   = None
        return False

    fn = make_inference_fn(stored)
    if fn is None:
        log.warning("regime_ml model_deserialize_failed — using hand-tuned weights")
        _inference_fn = None
        _model_meta   = None
        return False

    _inference_fn = fn
    _model_meta   = {k: v for k, v in stored.items() if k != "model_json"}
    log.info(
        "regime_ml model_loaded type=%s auc=%.3f trained=%s",
        stored.get("model_type"),
        stored.get("auc_roc", 0),
        stored.get("trained_at", ""),
    )
    return True

# ---------------------------------------------------------------------------
# Hand-tuned fallback weights (used when no trained model exists)
# ---------------------------------------------------------------------------
_W_ZGL_LEVEL   = 0.25
_W_ZGL_TREND   = 0.20
_W_SMA         = 0.20
_W_HMM         = 0.15
_W_IVP_TREND   = 0.10
_W_VIX_STRESS  = 0.10

_STABLE_THRESHOLD           = 0.15
_TRENDING_THRESHOLD         = 0.10
_REGIME_DURATION_ALERT_DAYS = 15


@dataclass
class RegimeFeatures:
    spot_to_zgl_pct:  float | None  # latest value
    spot_to_zgl_trend: float | None  # linear slope over last 5 obs (% pts/day)
    ivp:              float | None
    ivp_trend:        float | None  # slope over last 5 obs
    hmm_state:        str   | None  # "low_vol" | "high_vol"
    hmm_probability:  float | None
    sma_aligned:      bool  | None  # True = SMA10 > SMA50
    vix_dev_pct:      float | None
    regime_duration_days: int       # consecutive days in current regime


@dataclass
class TickerRegimeResult:
    ticker:            str
    current_regime:    str
    bucket:            str
    ml_score:          float   # -1 to +1
    transition_prob:   float   # P(regime flips within LOOKAHEAD obs)
    confidence:        float   # 0-1
    features:          RegimeFeatures
    strategy_bias:     str
    signals:           list[str]
    last_updated:      str | None
    scoring_method:    str     # "supervised_lr" | "supervised_xgb" | "heuristic"


@dataclass
class ModelMetadata:
    available:    bool
    model_type:   str | None  # "logistic" | "xgboost"
    trained_at:   str | None
    n_samples:    int
    n_positive:   int
    auc_roc:      float
    accuracy:     float
    precision:    float
    recall:       float


@dataclass
class MarketContext:
    spy_regime:   dict[str, Any] | None
    vix_state:    str | None
    vix_current:  float | None
    vix_dev_pct:  float | None


@dataclass
class MlAnalysisResult:
    as_of:          str
    market_context: MarketContext
    model_metadata: ModelMetadata
    tickers:        list[TickerRegimeResult]


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def analyze_all_tickers(supabase_client) -> MlAnalysisResult:
    """Fetch historical snapshots and score every tracked ticker.

    Uses the supervised model if loaded (via load_trained_model), else falls
    back to hand-tuned feature weights.
    """
    rows = _fetch_snapshots(supabase_client)

    by_ticker: dict[str, list[dict]] = {}
    for row in rows:
        t = row.get("ticker", "")
        by_ticker.setdefault(t, []).append(row)

    for t in by_ticker:
        by_ticker[t].sort(key=lambda r: r.get("obs_date", ""))

    results: list[TickerRegimeResult] = []
    spy_row: dict | None = None

    for ticker, history in by_ticker.items():
        result = _score_ticker(ticker, history, _inference_fn)
        results.append(result)
        if ticker.upper() == "SPY":
            spy_row = history[-1] if history else None

    market_ctx    = _build_market_context(spy_row)
    model_meta    = _build_model_metadata()

    return MlAnalysisResult(
        as_of=datetime.now(timezone.utc).isoformat(),
        market_context=market_ctx,
        model_metadata=model_meta,
        tickers=results,
    )


def _build_model_metadata() -> ModelMetadata:
    if _model_meta is None or _inference_fn is None:
        return ModelMetadata(
            available=False,
            model_type=None, trained_at=None,
            n_samples=0, n_positive=0,
            auc_roc=0.0, accuracy=0.0, precision=0.0, recall=0.0,
        )
    return ModelMetadata(
        available=True,
        model_type=_model_meta.get("model_type"),
        trained_at=_model_meta.get("trained_at"),
        n_samples=int(_model_meta.get("n_samples", 0)),
        n_positive=int(_model_meta.get("n_positive", 0) or 0),
        auc_roc=float(_model_meta.get("auc_roc", 0) or 0),
        accuracy=float(_model_meta.get("accuracy", 0) or 0),
        precision=float(_model_meta.get("precision", 0) or 0),
        recall=float(_model_meta.get("recall", 0) or 0),
    )


# ---------------------------------------------------------------------------
# Supabase fetch
# ---------------------------------------------------------------------------

def _fetch_snapshots(supabase_client) -> list[dict]:
    try:
        from datetime import timedelta
        cutoff = (datetime.now(timezone.utc) - timedelta(days=45)).date().isoformat()
        resp = (
            supabase_client
            .table("regime_snapshots")
            .select("*")
            .gte("obs_date", cutoff)
            .order("obs_date", desc=False)
            .execute()
        )
        return resp.data or []
    except Exception as exc:
        log.warning("regime_snapshots_fetch_failed error=%s", exc)
        return []


# ---------------------------------------------------------------------------
# Per-ticker scoring
# ---------------------------------------------------------------------------

def _score_ticker(
    ticker: str,
    history: list[dict],
    inference_fn: Callable | None,
) -> TickerRegimeResult:
    if not history:
        return _unknown_result(ticker)

    latest         = history[-1]
    current_regime = latest.get("gamma_regime", "unknown")
    strategy_bias  = latest.get("strategy_bias", "unclear")
    signals        = list(latest.get("signals") or [])
    last_updated   = latest.get("obs_date")

    features = _extract_features(history, current_regime)

    # ── Use supervised model if available ─────────────────────────────────
    if inference_fn is not None:
        from .regime_ml_trainer import build_feature_vector
        feat_vec = build_feature_vector(history)
        if feat_vec is not None:
            flip_prob, raw_stability = inference_fn(feat_vec)
            # Flip raw_stability sign based on current regime so that:
            #   pos regime + high flip_prob → negative score (at risk)
            #   neg regime + high flip_prob → positive score (recovering)
            if current_regime == "positive":
                ml_score = raw_stability        # high stability → positive score
            elif current_regime == "negative":
                ml_score = -raw_stability       # high stability → negative score
            else:
                ml_score = 0.0
            transition_prob  = flip_prob
            confidence       = abs(flip_prob - 0.5) * 2   # margin from decision boundary
            mt               = _model_meta.get("model_type", "logistic") if _model_meta else "logistic"
            scoring_method   = f"supervised_{mt}"
        else:
            ml_score, transition_prob, confidence, scoring_method = (
                *_heuristic_score(features, current_regime, len(history)), "heuristic"
            )
    else:
        ml_score, transition_prob, confidence, scoring_method = (
            *_heuristic_score(features, current_regime, len(history)), "heuristic"
        )

    bucket     = _classify_bucket(current_regime, ml_score)
    ml_signals = _ml_signals(features, ml_score, bucket, scoring_method)

    return TickerRegimeResult(
        ticker=ticker,
        current_regime=current_regime,
        bucket=bucket,
        ml_score=round(ml_score, 3),
        transition_prob=round(transition_prob, 3),
        confidence=round(confidence, 3),
        features=features,
        strategy_bias=strategy_bias,
        signals=signals + ml_signals,
        last_updated=last_updated,
        scoring_method=scoring_method,
    )


# ---------------------------------------------------------------------------
# Feature extraction
# ---------------------------------------------------------------------------

def _extract_features(history: list[dict], current_regime: str) -> RegimeFeatures:
    latest = history[-1]

    spot_to_zgl_pct  = _safe_float(latest, "spot_to_zgl_pct")
    ivp              = _safe_float(latest, "iv_percentile")
    hmm_state        = latest.get("hmm_state")
    hmm_prob         = _safe_float(latest, "hmm_probability")
    sma10            = _safe_float(latest, "sma10")
    sma50            = _safe_float(latest, "sma50")
    vix_dev_pct      = _safe_float(latest, "vix_dev_pct")
    sma_aligned      = (sma10 is not None and sma50 is not None and sma10 > sma50) or None

    # Trend slopes (linear regression over last 5 obs)
    zgl_values = [_safe_float(r, "spot_to_zgl_pct") for r in history[-5:]]
    ivp_values = [_safe_float(r, "iv_percentile")   for r in history[-5:]]
    zgl_trend  = _slope(zgl_values)
    ivp_trend  = _slope(ivp_values)

    # Regime duration: consecutive obs in current_regime
    duration = 0
    for row in reversed(history):
        if row.get("gamma_regime") == current_regime:
            duration += 1
        else:
            break

    return RegimeFeatures(
        spot_to_zgl_pct=spot_to_zgl_pct,
        spot_to_zgl_trend=zgl_trend,
        ivp=ivp,
        ivp_trend=ivp_trend,
        hmm_state=hmm_state,
        hmm_probability=hmm_prob,
        sma_aligned=sma_aligned,
        vix_dev_pct=vix_dev_pct,
        regime_duration_days=duration,
    )


# ---------------------------------------------------------------------------
# Score computation
# ---------------------------------------------------------------------------

def _heuristic_score(
    f: RegimeFeatures, current_regime: str, n_obs: int = 0
) -> tuple[float, float, float]:
    """Hand-tuned fallback. Returns (ml_score, transition_prob, confidence)."""
    score      = _compute_score(f, current_regime)
    trans_prob = _transition_prob_from_score(current_regime, score)
    conf       = _confidence(f, n_obs)
    return score, trans_prob, conf


def _compute_score(f: RegimeFeatures, current_regime: str) -> float:
    """
    Returns a score in [-1, +1] where +1 = strong positive-gamma conviction.
    Each component is normalised to [-1, +1] before weighting.
    """
    components: dict[str, float] = {}

    # 1. ZGL level — spot above ZGL is bullish (+)
    if f.spot_to_zgl_pct is not None:
        components["zgl_level"] = _clamp(f.spot_to_zgl_pct / 5.0, -1, 1)

    # 2. ZGL trend — rising (positive slope) = moving away from zero-gamma (bullish)
    if f.spot_to_zgl_trend is not None:
        components["zgl_trend"] = _clamp(f.spot_to_zgl_trend / 0.5, -1, 1)

    # 3. SMA alignment
    if f.sma_aligned is not None:
        components["sma"] = 1.0 if f.sma_aligned else -1.0

    # 4. HMM — low_vol regime supports positive gamma
    if f.hmm_state is not None and f.hmm_probability is not None:
        direction = 1.0 if f.hmm_state == "low_vol" else -1.0
        components["hmm"] = direction * f.hmm_probability

    # 5. IVP trend — rising IVP means stress building (bearish for pos gamma)
    if f.ivp_trend is not None:
        components["ivp_trend"] = _clamp(-f.ivp_trend / 5.0, -1, 1)

    # 6. VIX stress — large positive deviation signals regime pressure
    if f.vix_dev_pct is not None:
        components["vix_stress"] = _clamp(-f.vix_dev_pct / 15.0, -1, 1)

    if not components:
        return 0.0

    weights = {
        "zgl_level":  _W_ZGL_LEVEL,
        "zgl_trend":  _W_ZGL_TREND,
        "sma":        _W_SMA,
        "hmm":        _W_HMM,
        "ivp_trend":  _W_IVP_TREND,
        "vix_stress": _W_VIX_STRESS,
    }

    total_w = sum(weights[k] for k in components)
    if total_w == 0:
        return 0.0

    weighted = sum(components[k] * weights[k] for k in components)
    return _clamp(weighted / total_w, -1.0, 1.0)


def _classify_bucket(current_regime: str, ml_score: float) -> str:
    if current_regime == "positive":
        if ml_score >= _STABLE_THRESHOLD:
            return "stable_positive"
        return "trending_negative"  # pos regime but score deteriorating
    if current_regime == "negative":
        if ml_score > _TRENDING_THRESHOLD:
            return "trending_positive"  # neg regime but score improving
        return "stable_negative"
    return "unknown"


def _transition_prob_from_score(current_regime: str, ml_score: float) -> float:
    """Heuristic flip probability derived from hand-tuned score."""
    if current_regime == "positive":
        raw = (1.0 - ml_score) / 2.0
    elif current_regime == "negative":
        raw = (1.0 + ml_score) / 2.0
    else:
        raw = 0.5
    return _clamp(raw, 0.01, 0.99)


def _confidence(f: RegimeFeatures, n_obs: int) -> float:
    """Confidence 0-1: based on data richness and feature availability."""
    feature_count = sum([
        f.spot_to_zgl_pct is not None,
        f.spot_to_zgl_trend is not None,
        f.hmm_state is not None,
        f.sma_aligned is not None,
        f.ivp is not None,
        f.vix_dev_pct is not None,
    ])
    data_conf    = min(n_obs / 20.0, 1.0)
    feature_conf = feature_count / 6.0
    return round((data_conf * 0.5 + feature_conf * 0.5), 2)


# ---------------------------------------------------------------------------
# ML signal annotations
# ---------------------------------------------------------------------------

def _ml_signals(
    f: RegimeFeatures, score: float, bucket: str, scoring_method: str
) -> list[str]:
    out: list[str] = []

    method_tag = {
        "supervised_logistic": "Supervised LR",
        "supervised_xgboost":  "Supervised XGB",
        "heuristic":           "Heuristic",
    }.get(scoring_method, scoring_method)

    label = {
        "stable_positive":   "Strong positive-gamma conviction",
        "trending_positive":  "Recovering — signals improving toward positive gamma",
        "trending_negative":  "At risk — signals deteriorating from positive gamma",
        "stable_negative":   "Strong negative-gamma conviction",
    }.get(bucket, "Insufficient data for classification")
    out.append(f"ML [{method_tag}]: {label} (score {score:+.2f})")

    if f.spot_to_zgl_trend is not None:
        direction = "rising (bullish)" if f.spot_to_zgl_trend > 0 else "falling (bearish)"
        out.append(f"ZGL distance trend: {direction} ({f.spot_to_zgl_trend:+.2f}%/obs)")

    if f.regime_duration_days >= _REGIME_DURATION_ALERT_DAYS:
        out.append(
            f"Regime tenure: {f.regime_duration_days} days — "
            "extended tenure increases mean-reversion pressure"
        )

    if f.ivp is not None and f.ivp_trend is not None:
        if f.ivp > 70 and f.ivp_trend > 0:
            out.append(f"IVP {f.ivp:.0f} and rising — elevated stress, watch for vol spike")
        elif f.ivp < 25:
            out.append(f"IVP {f.ivp:.0f} (compressed) — vol expansion risk elevated")

    return out


# ---------------------------------------------------------------------------
# Market context
# ---------------------------------------------------------------------------

def _build_market_context(spy_row: dict | None) -> MarketContext:
    if not spy_row:
        return MarketContext(
            spy_regime=None,
            vix_state=None,
            vix_current=None,
            vix_dev_pct=None,
        )
    return MarketContext(
        spy_regime=spy_row,
        vix_state=spy_row.get("hmm_state"),
        vix_current=_safe_float(spy_row, "vix_current"),
        vix_dev_pct=_safe_float(spy_row, "vix_dev_pct"),
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _safe_float(d: dict, key: str) -> float | None:
    v = d.get(key)
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _slope(values: list[float | None]) -> float | None:
    """OLS slope of non-None values over their indices."""
    pts = [(i, v) for i, v in enumerate(values) if v is not None]
    if len(pts) < 2:
        return None
    xs = np.array([p[0] for p in pts], dtype=float)
    ys = np.array([p[1] for p in pts], dtype=float)
    xs -= xs.mean()
    denom = float(np.dot(xs, xs))
    return float(np.dot(xs, ys) / denom) if denom else None


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _unknown_result(ticker: str) -> TickerRegimeResult:
    return TickerRegimeResult(
        ticker=ticker,
        current_regime="unknown",
        bucket="unknown",
        ml_score=0.0,
        transition_prob=0.5,
        confidence=0.0,
        features=RegimeFeatures(
            spot_to_zgl_pct=None,
            spot_to_zgl_trend=None,
            ivp=None,
            ivp_trend=None,
            hmm_state=None,
            hmm_probability=None,
            sma_aligned=None,
            vix_dev_pct=None,
            regime_duration_days=0,
        ),
        strategy_bias="unclear",
        signals=["Insufficient historical data for ML analysis"],
        last_updated=None,
    )
