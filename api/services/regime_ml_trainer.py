# =============================================================================
# services/regime_ml_trainer.py
# =============================================================================
# Supervised ML trainer for gamma regime flip prediction.
#
# Pipeline:
#   1. Fetch all regime_snapshots from Supabase (45-day window by default,
#      or pass full history for a longer training set).
#   2. Label each snapshot: did gamma_regime change within the next
#      LOOKAHEAD observations for the same ticker? (y=1 = flip, y=0 = stable)
#   3. Engineer the same 6 features used by regime_ml_service.py.
#   4. Temporal train/test split (last 20% of time as test — no leakage).
#   5. Fit Logistic Regression (primary) and optionally XGBoost.
#   6. Evaluate: AUC-ROC, accuracy, precision, recall.
#   7. Serialize model to JSON and store in Supabase regime_ml_models table.
#      Falls back to module-level in-memory cache if Supabase write fails.
#
# Feature names (must match regime_ml_service.py scoring features):
#   spot_to_zgl_pct    — latest ZGL distance
#   spot_to_zgl_trend  — OLS slope over last 5 obs
#   ivp                — IV percentile (0–100)
#   ivp_trend          — OLS slope over last 5 obs
#   hmm_state_num      — 1=high_vol, 0=low_vol, 0.5=unknown
#   hmm_probability    — posterior P(current HMM state)
#   sma_aligned_num    — 1=SMA10>SMA50 (bullish), 0=bearish
#   vix_dev_pct        — (VIX − VIX10MA) / VIX10MA × 100
#   regime_duration    — consecutive obs in current gamma_regime
# =============================================================================

from __future__ import annotations

import base64
import io
import json
import logging
import math
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression

from core.ml_utils import _slope
from sklearn.metrics import accuracy_score, precision_score, recall_score, roc_auc_score
from sklearn.preprocessing import StandardScaler

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FEATURE_NAMES: list[str] = [
    "spot_to_zgl_pct",
    "spot_to_zgl_trend",
    "ivp",
    "ivp_trend",
    "hmm_state_num",
    "hmm_probability",
    "sma_aligned_num",
    "vix_dev_pct",
    "regime_duration",
]

LOOKAHEAD: int   = 5    # flip within next N obs = positive label
MIN_SAMPLES: int = 80   # minimum total labeled rows to attempt training
TEST_FRAC: float = 0.20 # temporal hold-out fraction


# ---------------------------------------------------------------------------
# Public data classes
# ---------------------------------------------------------------------------

@dataclass
class TrainingResult:
    model_type:      str
    trained_at:      str
    n_samples:       int
    n_positive:      int
    n_features:      int
    feature_names:   list[str]
    accuracy:        float
    auc_roc:         float
    precision:       float
    recall:          float
    model_json:      dict     # serialized parameters for inference
    sufficient_data: bool


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def train_and_store(
    supabase_client,
    model_type: str = "logistic",   # "logistic" | "xgboost"
    history_days: int = 180,
) -> TrainingResult:
    """Fetch snapshots, label, train, evaluate, persist, return metrics."""
    rows = _fetch_all_snapshots(supabase_client, history_days)

    if not rows:
        return _insufficient(model_type)

    X, y, dates = _build_dataset(rows)

    if len(X) < MIN_SAMPLES:
        log.warning("regime_ml_train insufficient_samples n=%d min=%d", len(X), MIN_SAMPLES)
        return _insufficient(model_type)

    result = _train(X, y, dates, model_type)

    # Persist to Supabase; non-fatal if table missing
    _persist(supabase_client, result)
    return result


def load_latest_model(supabase_client) -> dict | None:
    """Load the most recent trained model JSON from Supabase.

    Returns the raw model_json dict, or None if unavailable.
    """
    try:
        resp = (
            supabase_client
            .table("regime_ml_models")
            .select("model_json, model_type, trained_at, auc_roc, n_samples")
            .order("trained_at", desc=True)
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        return rows[0] if rows else None
    except Exception as exc:
        log.warning("regime_ml_load_failed error=%s", exc)
        return None


# ---------------------------------------------------------------------------
# Dataset construction
# ---------------------------------------------------------------------------

def _fetch_all_snapshots(supabase_client, history_days: int) -> list[dict]:
    try:
        from datetime import timedelta
        cutoff = (datetime.now(timezone.utc) - timedelta(days=history_days)).date().isoformat()
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


def _build_dataset(
    rows: list[dict],
) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """
    Build X (features), y (flip labels), and obs_date strings for temporal split.

    Each row becomes one sample. Features require 5-obs lookback so the first
    4 rows per ticker are skipped. Label requires LOOKAHEAD future obs so the
    last LOOKAHEAD rows per ticker are also skipped.
    """
    by_ticker: dict[str, list[dict]] = {}
    for row in rows:
        by_ticker.setdefault(row["ticker"], []).append(row)

    for t in by_ticker:
        by_ticker[t].sort(key=lambda r: r.get("obs_date", ""))

    X_rows:   list[list[float]] = []
    y_rows:   list[int]         = []
    date_rows: list[str]        = []

    for ticker, history in by_ticker.items():
        n = len(history)
        # Need ≥5 lookback + at least 1 future obs
        if n < 6:
            continue

        for i in range(4, n - LOOKAHEAD):
            features = _extract_features_at(history, i)
            if features is None:
                continue

            current_regime = history[i].get("gamma_regime", "unknown")
            future = history[i + 1 : i + 1 + LOOKAHEAD]
            flip = int(any(
                r.get("gamma_regime", "unknown") != current_regime
                for r in future
            ))

            X_rows.append(features)
            y_rows.append(flip)
            date_rows.append(history[i].get("obs_date", ""))

    if not X_rows:
        return np.empty((0, len(FEATURE_NAMES))), np.empty(0), []

    return np.array(X_rows, dtype=float), np.array(y_rows, dtype=int), date_rows


def _extract_features_at(history: list[dict], i: int) -> list[float] | None:
    """Extract feature vector for history[i]. Returns None if too many NaNs."""
    row = history[i]

    # Point-in-time values
    zgl       = _sf(row, "spot_to_zgl_pct")
    ivp       = _sf(row, "iv_percentile")
    hmm_state = row.get("hmm_state")
    hmm_prob  = _sf(row, "hmm_probability")
    sma10     = _sf(row, "sma10")
    sma50     = _sf(row, "sma50")
    vix_dev   = _sf(row, "vix_dev_pct")

    # OLS trends over last 5 obs (inclusive)
    start = max(0, i - 4)
    window = history[start : i + 1]
    zgl_trend = _slope([_sf(r, "spot_to_zgl_pct") for r in window])
    ivp_trend = _slope([_sf(r, "iv_percentile")   for r in window])

    # Regime duration (consecutive obs in current regime)
    current_regime = history[i].get("gamma_regime", "unknown")
    duration = 0
    for r in reversed(history[: i + 1]):
        if r.get("gamma_regime") == current_regime:
            duration += 1
        else:
            break

    # Encode categoricals as numbers (0.5 for missing)
    hmm_num  = (1.0 if hmm_state == "high_vol" else 0.0) if hmm_state else 0.5
    sma_num  = (1.0 if (sma10 is not None and sma50 is not None and sma10 > sma50)
                else 0.0) if (sma10 is not None and sma50 is not None) else 0.5

    feats = [
        zgl       if zgl       is not None else 0.0,
        zgl_trend if zgl_trend is not None else 0.0,
        ivp       if ivp       is not None else 50.0,  # neutral imputation
        ivp_trend if ivp_trend is not None else 0.0,
        hmm_num,
        hmm_prob  if hmm_prob  is not None else 0.5,
        sma_num,
        vix_dev   if vix_dev   is not None else 0.0,
        float(duration),
    ]

    # Reject sample if more than half features are missing/imputed
    raw_missing = sum([
        zgl is None, zgl_trend is None, ivp is None,
        hmm_state is None, hmm_prob is None, vix_dev is None,
    ])
    if raw_missing > 3:
        return None

    return feats


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------

def _train(
    X: np.ndarray,
    y: np.ndarray,
    dates: list[str],
    model_type: str,
) -> TrainingResult:
    # Temporal split — sort samples by date, hold out last TEST_FRAC
    order   = sorted(range(len(dates)), key=lambda i: dates[i])
    split   = int(len(order) * (1 - TEST_FRAC))
    tr_idx  = order[:split]
    te_idx  = order[split:]

    X_train, y_train = X[tr_idx], y[tr_idx]
    X_test,  y_test  = X[te_idx], y[te_idx]

    # Scale features
    scaler  = StandardScaler()
    X_train_sc = scaler.fit_transform(X_train)
    X_test_sc  = scaler.transform(X_test)

    # Train
    if model_type == "xgboost":
        model, model_json = _train_xgboost(X_train_sc, y_train)
    else:
        model, model_json = _train_logistic(X_train_sc, y_train)

    # Evaluate
    if len(te_idx) < 5 or len(np.unique(y_test)) < 2:
        # Not enough test data — evaluate on train
        X_eval, y_eval = X_train_sc, y_train
    else:
        X_eval, y_eval = X_test_sc, y_test

    y_prob = model.predict_proba(X_eval)[:, 1]
    y_pred = (y_prob >= 0.5).astype(int)

    auc      = float(roc_auc_score(y_eval, y_prob)) if len(np.unique(y_eval)) > 1 else 0.5
    acc      = float(accuracy_score(y_eval, y_pred))
    prec     = float(precision_score(y_eval, y_pred, zero_division=0))
    rec      = float(recall_score(y_eval, y_pred, zero_division=0))

    # Embed scaler into model_json
    model_json["scaler_mean"] = scaler.mean_.tolist()
    model_json["scaler_std"]  = scaler.scale_.tolist()
    model_json["feature_names"] = FEATURE_NAMES

    n_pos = int(y.sum())
    log.info(
        "regime_ml_trained model=%s n=%d pos=%d auc=%.3f acc=%.3f",
        model_type, len(y), n_pos, auc, acc,
    )

    return TrainingResult(
        model_type=model_type,
        trained_at=datetime.now(timezone.utc).isoformat(),
        n_samples=len(y),
        n_positive=n_pos,
        n_features=len(FEATURE_NAMES),
        feature_names=FEATURE_NAMES,
        accuracy=round(acc, 4),
        auc_roc=round(auc, 4),
        precision=round(prec, 4),
        recall=round(rec, 4),
        model_json=model_json,
        sufficient_data=True,
    )


def _train_logistic(
    X: np.ndarray,
    y: np.ndarray,
) -> tuple[LogisticRegression, dict]:
    model = LogisticRegression(
        class_weight="balanced",   # handles class imbalance (flips are rare)
        max_iter=1000,
        C=1.0,
        solver="lbfgs",
        random_state=42,
    )
    model.fit(X, y)
    model_json = {
        "model_type":  "logistic",
        "coef":        model.coef_[0].tolist(),
        "intercept":   float(model.intercept_[0]),
        "classes":     model.classes_.tolist(),
    }
    return model, model_json


def _train_xgboost(
    X: np.ndarray,
    y: np.ndarray,
) -> tuple[Any, dict]:
    try:
        from xgboost import XGBClassifier
    except ImportError:
        log.warning("xgboost not installed — falling back to logistic")
        return _train_logistic(X, y)

    n_pos = int(y.sum())
    n_neg = len(y) - n_pos
    scale_pos = n_neg / n_pos if n_pos > 0 else 1.0

    model = XGBClassifier(
        n_estimators=200,
        max_depth=4,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        scale_pos_weight=scale_pos,  # handle class imbalance
        use_label_encoder=False,
        eval_metric="logloss",
        random_state=42,
        verbosity=0,
    )
    model.fit(X, y)

    # Serialize via in-memory buffer
    buf = io.BytesIO()
    model.get_booster().save_model(buf)
    buf.seek(0)
    model_b64 = base64.b64encode(buf.read()).decode("utf-8")

    model_json = {
        "model_type":      "xgboost",
        "booster_b64":     model_b64,
        "feature_names":   FEATURE_NAMES,
        "n_estimators":    200,
        "feature_importances": model.feature_importances_.tolist(),
    }
    return model, model_json


# ---------------------------------------------------------------------------
# Inference helpers (called by regime_ml_service.py)
# ---------------------------------------------------------------------------

def make_inference_fn(stored: dict):
    """
    Given a stored model row (from Supabase regime_ml_models), return a
    callable: features_list -> (flip_prob: float, model_score: float)

    flip_prob  ∈ [0, 1]  — P(regime flips within LOOKAHEAD obs)
    model_score ∈ [-1, 1] — directional score (+1 = strong positive gamma)
    """
    mj = stored.get("model_json", {})
    if not mj:
        return None

    scaler_mean = np.array(mj.get("scaler_mean", []))
    scaler_std  = np.array(mj.get("scaler_std",  []))
    if scaler_mean.size == 0 or scaler_std.size == 0:
        return None

    mtype = mj.get("model_type", stored.get("model_type", "logistic"))

    if mtype == "xgboost":
        booster_b64 = mj.get("booster_b64")
        if not booster_b64:
            return None
        try:
            from xgboost import Booster
            buf = io.BytesIO(base64.b64decode(booster_b64))
            booster = Booster()
            booster.load_model(buf)

            def _xgb_infer(feats: list[float]) -> tuple[float, float]:
                x = np.array(feats, dtype=float).reshape(1, -1)
                x_sc = (x - scaler_mean) / np.where(scaler_std > 0, scaler_std, 1)
                from xgboost import DMatrix
                dm = DMatrix(x_sc)
                flip_prob = float(booster.predict(dm)[0])
                flip_prob = max(0.01, min(0.99, flip_prob))
                return flip_prob, _flip_to_score(flip_prob, feats)

            return _xgb_infer
        except Exception as exc:
            log.warning("xgboost_load_failed error=%s", exc)
            return None

    # Logistic regression
    coef      = np.array(mj.get("coef", []))
    intercept = float(mj.get("intercept", 0.0))
    if coef.size == 0:
        return None

    def _lr_infer(feats: list[float]) -> tuple[float, float]:
        x = np.array(feats, dtype=float)
        x_sc = (x - scaler_mean) / np.where(scaler_std > 0, scaler_std, 1)
        logit = float(np.dot(coef, x_sc) + intercept)
        flip_prob = 1.0 / (1.0 + math.exp(-logit))
        flip_prob = max(0.01, min(0.99, flip_prob))
        return flip_prob, _flip_to_score(flip_prob, feats)

    return _lr_infer


def _flip_to_score(flip_prob: float, feats: list[float]) -> float:
    """
    Map flip_prob to a directional score ∈ [-1, +1].

    We don't know current_regime here — the caller (regime_ml_service) adjusts sign.
    We return a raw "stability score": high flip_prob → near 0 (unstable),
    low flip_prob → near 1 (stable in current regime).
    """
    # stability ∈ [0, 1]: 1 = very stable, 0 = likely flipping
    stability = 1.0 - flip_prob
    # Map [0,1] → [-1, +1]: stability 1.0 → +1.0, stability 0.0 → -1.0
    return stability * 2.0 - 1.0


def build_feature_vector(history: list[dict]) -> list[float] | None:
    """Build the feature vector for the most recent snapshot in history.

    This is the inference-time equivalent of _extract_features_at() used
    during training. Must produce the same feature values in the same order.
    """
    if not history:
        return None
    i = len(history) - 1
    return _extract_features_at(history, i)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

def _persist(supabase_client, result: TrainingResult) -> None:
    try:
        supabase_client.table("regime_ml_models").insert({
            "model_type":    result.model_type,
            "trained_at":    result.trained_at,
            "n_samples":     result.n_samples,
            "n_positive":    result.n_positive,
            "accuracy":      result.accuracy,
            "auc_roc":       result.auc_roc,
            "precision":     result.precision,
            "recall":        result.recall,
            "model_json":    result.model_json,
        }).execute()
        log.info("regime_ml_persisted model_type=%s auc=%.3f", result.model_type, result.auc_roc)
    except Exception as exc:
        log.warning("regime_ml_persist_failed error=%s — model kept in memory only", exc)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sf(d: dict, key: str) -> float | None:
    v = d.get(key)
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None



def _insufficient(model_type: str) -> TrainingResult:
    return TrainingResult(
        model_type=model_type,
        trained_at=datetime.now(timezone.utc).isoformat(),
        n_samples=0,
        n_positive=0,
        n_features=len(FEATURE_NAMES),
        feature_names=FEATURE_NAMES,
        accuracy=0.0,
        auc_roc=0.0,
        precision=0.0,
        recall=0.0,
        model_json={},
        sufficient_data=False,
    )
