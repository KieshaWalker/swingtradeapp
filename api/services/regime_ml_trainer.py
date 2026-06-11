# =============================================================================
# services/regime_ml_trainer.py
# =============================================================================
# Supervised ML trainer for gamma regime flip prediction.
#
# Pipeline:
#   1. Fetch finalized (is_final) regime_snapshots from Supabase.
#   2. Label each snapshot: did gamma_regime change within the next
#      LOOKAHEAD observations for the same ticker? (y=1 = flip, y=0 = stable)
#   3. Engineer the 14 features shared with regime_ml_service.py.
#   4. Walk-forward CV with purge + embargo measured in *dates* (all tickers
#      of one obs_date stay on the same side of every fold boundary).
#   5. Fit Logistic Regression (primary) or XGBoost on a temporal split.
#   6. Fit isotonic calibration on the pooled out-of-sample fold predictions
#      (class_weight='balanced' distorts raw predict_proba).
#   7. Evaluate: AUC-ROC, accuracy, precision, recall.
#   8. Serialize model to JSON and store in Supabase regime_ml_models table.
#      Falls back to module-level in-memory cache if Supabase write fails.
#
# Feature names (must match regime_ml_service.py scoring features):
#   spot_to_zgl_pct          — latest ZGL distance
#   spot_to_zgl_trend        — OLS slope over last 5 obs
#   ivp                      — IV percentile (0–100)
#   ivp_trend                — OLS slope over last 5 obs
#   hmm_state_num            — 1=high_vol, 0=low_vol, 0.5=unknown
#   hmm_probability          — posterior P(current HMM state)
#   sma_aligned_num          — 1=SMA10>SMA50 (bullish), 0=bearish
#   vix_dev_pct              — (VIX − VIX10MA) / VIX10MA × 100
#   regime_duration          — consecutive obs in current gamma_regime
#   vix_term_structure_ratio — VIX/VIX3M; >1=backwardation (Gate 1b/6)
#   spot_to_vt_pct           — distance from Volatility Trigger
#   breadth_proxy            — RSP/SPY return ratio z-score
#   gex_0dte_pct             — pct of total GEX from 0DTE options
#   price_roc5               — 5-day price rate-of-change (%)
# =============================================================================

from __future__ import annotations

import base64
import io
import json
import logging
import math
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional

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
    # gate-derived features added in ML v2 (14-feature set)
    "vix_term_structure_ratio",
    "spot_to_vt_pct",
    "breadth_proxy",
    "gex_0dte_pct",
    "price_roc5",
]

LOOKAHEAD: int        = 5    # flip within next N obs = positive label
MIN_SAMPLES_EARLY: int = 40  # minimum rows to attempt early-mode training
MIN_SAMPLES_FULL:  int = 200 # minimum rows for full walk-forward CV evaluation
# Back-compat alias used elsewhere (e.g. router error message)
MIN_SAMPLES: int = MIN_SAMPLES_FULL
TEST_FRAC: float = 0.20       # temporal hold-out fraction

# Walk-forward cross-validation with purge + embargo.
# All boundaries are measured in distinct obs_dates, NOT pooled sample rows:
# with ~N tickers per date a row-index purge of 5 spans half a trading day and
# same-date correlated samples (shared VIX/breadth features, synchronized
# flips) leak across the train/test boundary.
WF_N_SPLITS:        int   = 5         # number of expanding-window folds
WF_MIN_TRAIN_DATES: int   = 40        # minimum distinct training dates (~2 months)
WF_MIN_TEST_DATES:  int   = 5         # minimum distinct test dates per fold
WF_PURGE:     int   = LOOKAHEAD # dates removed from train end (label window bleed-through)
WF_EMBARGO:   int   = LOOKAHEAD # dates skipped at test start (autocorrelation buffer)
MIN_OOS_AUC:  float = 0.52      # AUC required to accept model (walk-forward or single-split)

# Calibration: isotonic regression on pooled walk-forward OOS predictions.
MIN_CALIBRATION_OOS: int = 100  # minimum OOS predictions to fit a calibrator


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

    if len(X) < MIN_SAMPLES_EARLY:
        log.warning(
            "regime_ml_train insufficient_samples n=%d min=%d",
            len(X), MIN_SAMPLES_EARLY,
        )
        return _insufficient(model_type)

    result = _train(X, y, dates, model_type)

    # Persist to Supabase; non-fatal if table missing
    _persist(supabase_client, result)
    return result


def load_latest_model(supabase_client) ->Optional[dict]:
    """Load the most recent trained model JSON from Supabase.

    Returns the raw model_json dict, or None if unavailable.
    """
    try:
        resp = (
            supabase_client
            .table("regime_ml_models")
            .select("model_json, model_type, trained_at, auc_roc, n_samples, n_positive, accuracy, precision, recall")
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
        from core.supabase_client import fetch_all
        cutoff = (datetime.now(timezone.utc) - timedelta(days=history_days)).date().isoformat()
        # Paginate: history_days × n_tickers rows exceeds the Supabase 1000-row
        # response cap, which silently dropped the most recent dates from the
        # training set. Secondary sort on ticker keeps pagination stable.
        rows = fetch_all(
            lambda: (
                supabase_client
                .table("regime_snapshots")
                .select("*")
                .gte("obs_date", cutoff)
                .order("obs_date", desc=False)
                .order("ticker", desc=False)
            )
        )
        # Train on finalized EOD rows only — intraday partials have a different
        # feature distribution. Filter in Python (not .eq) so rows from before
        # the is_final migration (key absent/NULL) still count as final.
        return [r for r in rows if r.get("is_final") is not False]
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


def _extract_features_at(history: list[dict], i: int) ->Optional[list[float]]:
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
    ts_ratio  = _sf(row, "vix_term_structure_ratio")
    vt_pct    = _sf(row, "spot_to_vt_pct")
    breadth   = _sf(row, "breadth_proxy")
    dte0_pct  = _sf(row, "gex_0dte_pct")
    roc5      = _sf(row, "price_roc5")

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
        # gate-derived features (v2; neutral imputation when absent)
        ts_ratio  if ts_ratio  is not None else 1.0,   # 1.0 = contango neutral
        vt_pct    if vt_pct    is not None else 0.0,
        breadth   if breadth   is not None else 0.0,
        dte0_pct  if dte0_pct  is not None else 20.0,  # 20% = typical low-0DTE baseline
        roc5      if roc5      is not None else 0.0,
    ]

    # Reject sample if more than half core features are missing/imputed
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

def _date_fold_bounds(n_dates: int) -> list[tuple[int, int, int]]:
    """Expanding-window fold boundaries in date-index units.

    Returns (train_end, test_start, test_end) tuples: train uses date indices
    [0, train_end), test uses [test_start, test_end). Between them sit the
    purge (WF_PURGE dates removed from the train end, whose labels look
    forward into the test window) and the embargo (WF_EMBARGO dates skipped
    at the test start, whose feature lookback overlaps training data).
    """
    folds: list[tuple[int, int, int]] = []
    # The embargo eats the start of each test fold, so a fold needs
    # WF_EMBARGO + WF_MIN_TEST_DATES dates for WF_MIN_TEST_DATES to survive.
    min_fold   = WF_EMBARGO + WF_MIN_TEST_DATES
    min_needed = WF_MIN_TRAIN_DATES + WF_PURGE + min_fold
    if n_dates < min_needed:
        return folds

    available = n_dates - WF_MIN_TRAIN_DATES
    fold_size = max(available // (WF_N_SPLITS + 1), min_fold)

    for k in range(WF_N_SPLITS):
        test_start_raw = WF_MIN_TRAIN_DATES + k * fold_size
        test_end       = min(test_start_raw + fold_size, n_dates)

        if test_end - test_start_raw < min_fold:
            break

        train_end  = test_start_raw - WF_PURGE
        test_start = test_start_raw + WF_EMBARGO
        if train_end < WF_MIN_TRAIN_DATES // 2:
            continue
        if test_start >= test_end:
            continue

        folds.append((train_end, test_start, test_end))

    return folds


def _walk_forward_auc(
    X: np.ndarray,
    y: np.ndarray,
    dates: list[str],
    model_type: str,
) -> tuple[float, np.ndarray, np.ndarray]:
    """Expanding-window walk-forward CV with date-based purge + embargo.

    Fold boundaries cut on distinct obs_dates so all tickers of one date stay
    on the same side — same-date samples share market-wide features and flip
    together, so a row-based split lets correlated samples leak across it.

    Returns (mean OOS AUC, pooled OOS y_true, pooled OOS y_prob). The pooled
    predictions feed isotonic calibration. AUC falls back to the 0.5 sentinel
    (with empty arrays) when fewer than 2 folds run.
    """
    unique_dates = sorted(set(dates))
    date_index   = {d: i for i, d in enumerate(unique_dates)}
    sample_d     = np.array([date_index[d] for d in dates])
    no_result    = (0.5, np.empty(0), np.empty(0))

    folds = _date_fold_bounds(len(unique_dates))
    if not folds:
        log.warning(
            "walk_forward_cv skipped n_dates=%d min_needed=%d",
            len(unique_dates),
            WF_MIN_TRAIN_DATES + WF_PURGE + WF_EMBARGO + WF_MIN_TEST_DATES,
        )
        return no_result

    auc_scores: list[float] = []
    oos_true:   list[np.ndarray] = []
    oos_prob:   list[np.ndarray] = []

    for k, (train_end, test_start, test_end) in enumerate(folds):
        train_mask = sample_d < train_end
        test_mask  = (sample_d >= test_start) & (sample_d < test_end)

        X_tr, y_tr = X[train_mask], y[train_mask]
        X_te, y_te = X[test_mask],  y[test_mask]

        if len(np.unique(y_te)) < 2 or len(np.unique(y_tr)) < 2:
            continue

        try:
            scaler    = StandardScaler()
            X_tr_sc   = scaler.fit_transform(X_tr)
            X_te_sc   = scaler.transform(X_te)
            if model_type == "xgboost":
                model, _ = _train_xgboost(X_tr_sc, y_tr)
            else:
                model, _ = _train_logistic(X_tr_sc, y_tr)
            y_prob = model.predict_proba(X_te_sc)[:, 1]
            auc_scores.append(float(roc_auc_score(y_te, y_prob)))
            oos_true.append(y_te)
            oos_prob.append(y_prob)
        except Exception as exc:
            log.debug("wf_cv_fold_failed fold=%d error=%s", k, exc)

    if len(auc_scores) < 2:
        log.warning("walk_forward_cv too_few_valid_folds n_valid=%d", len(auc_scores))
        return no_result

    mean_auc = float(np.mean(auc_scores))
    log.info(
        "walk_forward_cv folds=%d aucs=[%s] mean=%.3f",
        len(auc_scores),
        ", ".join(f"{a:.3f}" for a in auc_scores),
        mean_auc,
    )
    return mean_auc, np.concatenate(oos_true), np.concatenate(oos_prob)


# ---------------------------------------------------------------------------
# Probability calibration
# ---------------------------------------------------------------------------

def _fit_calibration(y_true: np.ndarray, y_prob: np.ndarray) ->Optional[dict]:
    """Fit isotonic regression on pooled walk-forward OOS predictions.

    class_weight='balanced' / scale_pos_weight deliberately distort the base
    rate, so raw predict_proba systematically over-states flip probability.
    Isotonic maps raw scores back to observed OOS frequencies, preserving the
    ranking (AUC unchanged) while making the displayed probability honest.
    """
    if len(y_true) < MIN_CALIBRATION_OOS or len(np.unique(y_true)) < 2:
        return None
    try:
        from sklearn.isotonic import IsotonicRegression
        iso = IsotonicRegression(y_min=0.01, y_max=0.99, out_of_bounds="clip")
        iso.fit(y_prob, y_true)
        return {
            "method": "isotonic",
            "x": [float(v) for v in iso.X_thresholds_],
            "y": [float(v) for v in iso.y_thresholds_],
        }
    except Exception as exc:
        log.warning("calibration_fit_failed error=%s", exc)
        return None


def _apply_calibration(calib:Optional[dict], p: float) -> float:
    """Map a raw probability through a stored isotonic curve (no-op if absent)."""
    if not calib or calib.get("method") != "isotonic":
        return p
    xs = calib.get("x") or []
    ys = calib.get("y") or []
    if len(xs) < 2 or len(xs) != len(ys):
        return p
    return float(np.interp(p, xs, ys))


def _train(
    X: np.ndarray,
    y: np.ndarray,
    dates: list[str],
    model_type: str,
) -> TrainingResult:
    # Sort all samples chronologically — required for walk-forward and split.
    order        = sorted(range(len(dates)), key=lambda i: dates[i])
    X_sorted     = X[order]
    y_sorted     = y[order]
    dates_sorted = [dates[i] for i in order]

    # ── Walk-forward OOS AUC (honest, leakage-free evaluation) ────────────
    # Returns the 0.5 sentinel (empty OOS arrays) when there is not enough
    # data to run CV folds.
    oos_auc, oos_y, oos_p = _walk_forward_auc(X_sorted, y_sorted, dates_sorted, model_type)
    wf_ran    = oos_p.size > 0  # True = walk-forward produced a meaningful estimate
    is_early  = not wf_ran      # early mode: too few distinct dates

    # Calibration from pooled OOS fold predictions (full mode only — early
    # mode has no out-of-sample pool to fit on).
    calibration = _fit_calibration(oos_y, oos_p) if wf_ran else None

    # ── Final train/test split (date-based, same units as walk-forward) ─────
    # Full mode: apply purge + embargo to match the walk-forward protocol.
    # Early mode: skip purge/embargo — too few dates to sacrifice any rows.
    unique_dates = sorted(set(dates_sorted))
    date_index   = {d: i for i, d in enumerate(unique_dates)}
    sample_d     = np.array([date_index[d] for d in dates_sorted])
    split_d      = int(len(unique_dates) * (1 - TEST_FRAC))
    if is_early:
        train_end_d, test_start_d = split_d, split_d
    else:
        train_end_d  = split_d - WF_PURGE   # purge boundary
        test_start_d = split_d + WF_EMBARGO # embargo boundary

    train_mask = sample_d < train_end_d
    test_mask  = sample_d >= test_start_d
    X_train, y_train = X_sorted[train_mask], y_sorted[train_mask]
    X_test,  y_test  = X_sorted[test_mask],  y_sorted[test_mask]

    # Scale features (fit on train only — no leakage)
    scaler     = StandardScaler()
    X_train_sc = scaler.fit_transform(X_train)
    X_test_sc  = scaler.transform(X_test)

    # Early mode uses stronger L2 regularization to avoid overfitting on small samples.
    if model_type == "xgboost":
        model, model_json = _train_xgboost(X_train_sc, y_train)
    else:
        C = 1.0 if not is_early else 0.1
        model, model_json = _train_logistic(X_train_sc, y_train, C=C)

    # Evaluate on the held-out test set; fall back to train only if too small.
    # Track the fallback so we can reject acceptance based on inflated train AUC.
    is_eval_fallback = len(X_test) < 5 or len(np.unique(y_test)) < 2
    if is_eval_fallback:
        X_eval, y_eval = X_train_sc, y_train
        log.warning(
            "regime_ml_eval_fallback mode=%s — metrics computed on training data (inflated); "
            "model will not be accepted for production use",
            "early" if is_early else "full",
        )
    else:
        X_eval, y_eval = X_test_sc, y_test

    # Evaluate with calibration applied — matches what inference will serve.
    y_prob = model.predict_proba(X_eval)[:, 1]
    if calibration is not None:
        y_prob = np.array([_apply_calibration(calibration, p) for p in y_prob])
    y_pred = (y_prob >= 0.5).astype(int)

    test_auc = float(roc_auc_score(y_eval, y_prob)) if len(np.unique(y_eval)) > 1 else 0.5
    acc      = float(accuracy_score(y_eval, y_pred))
    prec     = float(precision_score(y_eval, y_pred, zero_division=0))
    rec      = float(recall_score(y_eval, y_pred, zero_division=0))

    # Best available AUC for the acceptance gate:
    #   Full mode  → walk-forward OOS AUC (leakage-free across multiple folds)
    #   Early mode, has test set → single-split test AUC
    #   Early mode, no test set → metrics on training data; reject regardless of AUC
    best_auc = oos_auc if wf_ran else test_auc

    # Embed scaler + calibration + AUC metrics + training mode into model_json
    model_json["scaler_mean"]   = scaler.mean_.tolist()
    model_json["scaler_std"]    = scaler.scale_.tolist()
    model_json["feature_names"] = FEATURE_NAMES
    model_json["oos_auc"]       = round(oos_auc, 4)   # walk-forward AUC (0.5 if not run)
    model_json["test_auc"]      = round(test_auc, 4)  # single-split AUC
    model_json["training_mode"] = "early" if is_early else "full"
    if calibration is not None:
        model_json["calibration"] = calibration       # isotonic curve from OOS preds

    # Reject when eval was forced onto training data — AUC is inflated and unreliable.
    model_accepted = (best_auc >= MIN_OOS_AUC) and (wf_ran or not is_eval_fallback)

    n_pos = int(y_sorted.sum())
    log.info(
        "regime_ml_trained model=%s mode=%s n=%d pos=%d best_auc=%.3f "
        "(oos=%.3f test=%.3f) calibrated=%s accepted=%s",
        model_type, "early" if is_early else "full",
        len(y_sorted), n_pos, best_auc, oos_auc, test_auc,
        calibration is not None, model_accepted,
    )

    return TrainingResult(
        model_type=model_type,
        trained_at=datetime.now(timezone.utc).isoformat(),
        n_samples=len(y_sorted),
        n_positive=n_pos,
        n_features=len(FEATURE_NAMES),
        feature_names=FEATURE_NAMES,
        accuracy=round(acc, 4),
        auc_roc=round(best_auc, 4),  # best available AUC (walk-forward or single-split)
        precision=round(prec, 4),
        recall=round(rec, 4),
        model_json=model_json,
        sufficient_data=model_accepted,
    )


def _train_logistic(
    X: np.ndarray,
    y: np.ndarray,
    C: float = 1.0,
) -> tuple[LogisticRegression, dict]:
    model = LogisticRegression(
        class_weight="balanced",   # handles class imbalance (flips are rare)
        max_iter=1000,
        C=C,
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
    callable: features_list -> (flip_prob, model_score, contributions)

    flip_prob     ∈ [0, 1]  — calibrated P(regime flips within LOOKAHEAD obs)
    model_score   ∈ [-1, 1] — directional score (+1 = strong positive gamma)
    contributions — per-feature pull on the *raw* prediction in logit/margin
                    space, aligned with FEATURE_NAMES; positive = pushes
                    toward a flip. LR: coef × scaled value. XGB: SHAP values
                    via pred_contribs. Powers the "why this prediction" UI.
    """
    mj = stored.get("model_json", {})
    if not mj:
        return None

    scaler_mean = np.array(mj.get("scaler_mean", []))
    scaler_std  = np.array(mj.get("scaler_std",  []))
    if scaler_mean.size == 0 or scaler_std.size == 0:
        return None
    # Reject models trained on a different feature set — prevents shape mismatch at inference.
    if scaler_mean.size != len(FEATURE_NAMES):
        log.warning(
            "make_inference_fn feature_mismatch stored=%d current=%d — model retired, retrain needed",
            scaler_mean.size, len(FEATURE_NAMES),
        )
        return None

    mtype = mj.get("model_type", stored.get("model_type", "logistic"))
    calib = mj.get("calibration")  # isotonic curve fitted on OOS fold predictions

    if mtype == "xgboost":
        booster_b64 = mj.get("booster_b64")
        if not booster_b64:
            return None
        try:
            from xgboost import Booster
            buf = io.BytesIO(base64.b64decode(booster_b64))
            booster = Booster()
            booster.load_model(buf)

            def _xgb_infer(feats: list[float]) -> tuple[float, float, list[float]]:
                x = np.array(feats, dtype=float).reshape(1, -1)
                x_sc = (x - scaler_mean) / np.where(scaler_std > 0, scaler_std, 1)
                from xgboost import DMatrix
                dm = DMatrix(x_sc)
                flip_prob = float(booster.predict(dm)[0])
                flip_prob = _apply_calibration(calib, flip_prob)
                flip_prob = max(0.01, min(0.99, flip_prob))
                # SHAP-style margin-space contributions; last column is bias.
                try:
                    contribs = booster.predict(dm, pred_contribs=True)[0][:-1].tolist()
                except Exception as contrib_exc:
                    log.debug("xgb_pred_contribs_failed error=%s", contrib_exc)
                    contribs = [0.0] * len(FEATURE_NAMES)
                return flip_prob, _flip_to_score(flip_prob, feats), contribs

            return _xgb_infer
        except Exception as exc:
            log.warning("xgboost_load_failed error=%s", exc)
            return None

    # Logistic regression
    coef      = np.array(mj.get("coef", []))
    intercept = float(mj.get("intercept", 0.0))
    if coef.size == 0:
        return None

    def _lr_infer(feats: list[float]) -> tuple[float, float, list[float]]:
        x = np.array(feats, dtype=float)
        x_sc = (x - scaler_mean) / np.where(scaler_std > 0, scaler_std, 1)
        contribs = coef * x_sc   # per-feature logit contributions
        logit = float(contribs.sum() + intercept)
        flip_prob = 1.0 / (1.0 + math.exp(-logit))
        flip_prob = _apply_calibration(calib, flip_prob)
        flip_prob = max(0.01, min(0.99, flip_prob))
        return flip_prob, _flip_to_score(flip_prob, feats), contribs.tolist()

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


def build_feature_vector(history: list[dict]) ->Optional[list[float]]:
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

_KEEP_MODELS = 5  # how many historical model rows to retain per model_type

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

        # Prune old rows — keep only the most recent _KEEP_MODELS per model_type
        try:
            keep_resp = (
                supabase_client.table("regime_ml_models")
                .select("id")
                .eq("model_type", result.model_type)
                .order("trained_at", desc=True)
                .limit(_KEEP_MODELS)
                .execute()
            )
            keep_ids = [r["id"] for r in (keep_resp.data or [])]
            if keep_ids:
                supabase_client.table("regime_ml_models").delete().eq(
                    "model_type", result.model_type
                ).not_.in_("id", keep_ids).execute()
        except Exception as prune_exc:
            log.warning("regime_ml_prune_failed error=%s", prune_exc)

    except Exception as exc:
        log.warning("regime_ml_persist_failed error=%s — model kept in memory only", exc)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sf(d: dict, key: str) ->Optional[float]:
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
