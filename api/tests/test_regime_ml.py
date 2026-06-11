from __future__ import annotations

# =============================================================================
# tests/test_regime_ml.py
# =============================================================================
# Guards the regime ML pipeline's silent-failure invariants:
#   1. Feature extraction — FEATURE_NAMES order matches the produced vector,
#      training-time and inference-time extraction agree, imputation values
#      and the missing-data rejection rule hold.
#   2. Labeling — a flip within the LOOKAHEAD window labels y=1, outside y=0.
#   3. Walk-forward folds — purge + embargo gaps measured in dates, never
#      letting train and test share or straddle an obs_date.
#   4. Calibration — isotonic fit/serialize/apply round-trip, monotonicity,
#      minimum-sample guard, and application inside make_inference_fn.
#   5. Reconciliation — realized-flip outcome logic for open/closed windows.
# =============================================================================

from datetime import date, timedelta

import numpy as np
import pytest

from services.regime_ml_monitor import _realized_flip
from services.regime_ml_trainer import (
    FEATURE_NAMES,
    LOOKAHEAD,
    MIN_CALIBRATION_OOS,
    WF_EMBARGO,
    WF_MIN_TEST_DATES,
    WF_MIN_TRAIN_DATES,
    WF_PURGE,
    _apply_calibration,
    _build_dataset,
    _date_fold_bounds,
    _extract_features_at,
    _fit_calibration,
    _walk_forward_auc,
    build_feature_vector,
    make_inference_fn,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dates(n: int) -> list[str]:
    start = date(2025, 6, 1)
    return [(start + timedelta(days=i)).isoformat() for i in range(n)]


def _row(obs_date: str, regime: str = "positive", **overrides) -> dict:
    row = {
        "ticker":                   "TST",
        "obs_date":                 obs_date,
        "gamma_regime":             regime,
        "spot_to_zgl_pct":          1.0,
        "iv_percentile":            40.0,
        "hmm_state":                "low_vol",
        "hmm_probability":          0.8,
        "sma10":                    105.0,
        "sma50":                    100.0,
        "vix_dev_pct":              -2.0,
        "vix_term_structure_ratio": 0.92,
        "spot_to_vt_pct":           1.5,
        "breadth_proxy":            0.3,
        "gex_0dte_pct":             25.0,
        "price_roc5":               1.2,
    }
    row.update(overrides)
    return row


def _history(n: int, regime: str = "positive") -> list[dict]:
    return [_row(d, regime) for d in _dates(n)]


def _fidx(name: str) -> int:
    return FEATURE_NAMES.index(name)


# ---------------------------------------------------------------------------
# 1. Feature extraction
# ---------------------------------------------------------------------------

class TestFeatureExtraction:
    def test_vector_length_matches_feature_names(self):
        feats = _extract_features_at(_history(6), 5)
        assert feats is not None
        assert len(feats) == len(FEATURE_NAMES)

    def test_known_values_land_in_named_positions(self):
        history = _history(6)
        feats = _extract_features_at(history, 5)
        assert feats[_fidx("spot_to_zgl_pct")] == pytest.approx(1.0)
        assert feats[_fidx("ivp")]             == pytest.approx(40.0)
        assert feats[_fidx("hmm_state_num")]   == 0.0   # low_vol
        assert feats[_fidx("hmm_probability")] == pytest.approx(0.8)
        assert feats[_fidx("sma_aligned_num")] == 1.0   # 105 > 100
        assert feats[_fidx("vix_dev_pct")]     == pytest.approx(-2.0)
        assert feats[_fidx("regime_duration")] == 6.0   # all 6 obs same regime
        assert feats[_fidx("vix_term_structure_ratio")] == pytest.approx(0.92)
        assert feats[_fidx("gex_0dte_pct")]    == pytest.approx(25.0)

    def test_trend_slope_over_window(self):
        history = [
            _row(d, spot_to_zgl_pct=float(i + 1))
            for i, d in enumerate(_dates(5))
        ]
        feats = _extract_features_at(history, 4)
        assert feats[_fidx("spot_to_zgl_trend")] == pytest.approx(1.0)

    def test_hmm_encoding(self):
        assert _extract_features_at(_history(5), 4)[_fidx("hmm_state_num")] == 0.0
        high = [_row(d, hmm_state="high_vol") for d in _dates(5)]
        assert _extract_features_at(high, 4)[_fidx("hmm_state_num")] == 1.0
        missing = [_row(d, hmm_state=None) for d in _dates(5)]
        assert _extract_features_at(missing, 4)[_fidx("hmm_state_num")] == 0.5

    def test_neutral_imputation_for_missing_values(self):
        history = [
            _row(d, iv_percentile=None, vix_term_structure_ratio=None,
                 gex_0dte_pct=None)
            for d in _dates(5)
        ]
        feats = _extract_features_at(history, 4)
        assert feats is not None
        assert feats[_fidx("ivp")]                      == pytest.approx(50.0)
        assert feats[_fidx("vix_term_structure_ratio")] == pytest.approx(1.0)
        assert feats[_fidx("gex_0dte_pct")]             == pytest.approx(20.0)

    def test_rejects_sample_when_core_features_missing(self):
        history = [
            _row(d, spot_to_zgl_pct=None, iv_percentile=None,
                 hmm_state=None, hmm_probability=None, vix_dev_pct=None)
            for d in _dates(5)
        ]
        assert _extract_features_at(history, 4) is None

    def test_inference_vector_matches_training_extraction(self):
        # build_feature_vector (inference) must equal _extract_features_at on
        # the last row (training) — they feed the same scaler/coefficients.
        history = _history(10)
        history[-1]["spot_to_zgl_pct"] = -3.7
        history[-1]["hmm_state"] = "high_vol"
        assert build_feature_vector(history) == _extract_features_at(history, 9)


# ---------------------------------------------------------------------------
# 2. Labeling
# ---------------------------------------------------------------------------

class TestLabeling:
    def test_flip_within_lookahead_labels_positive(self):
        # Regime positive for obs 0–11, negative from obs 12 on. Samples run
        # i = 4 … n-LOOKAHEAD-1; the flip is "visible" from i=7 (12-5) to i=11.
        n = 20
        rows = [
            _row(d, regime="positive" if i < 12 else "negative")
            for i, d in enumerate(_dates(n))
        ]
        X, y, dates = _build_dataset(rows)

        expected = [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0]   # i = 4 … 14
        assert list(y) == expected
        assert X.shape == (len(expected), len(FEATURE_NAMES))
        assert len(dates) == len(expected)

    def test_short_history_produces_no_samples(self):
        X, y, dates = _build_dataset(_history(5))
        assert len(X) == 0 and len(y) == 0 and dates == []


# ---------------------------------------------------------------------------
# 3. Walk-forward folds
# ---------------------------------------------------------------------------

class TestWalkForward:
    def test_fold_gap_covers_purge_and_embargo(self):
        folds = _date_fold_bounds(130)
        assert folds, "expected folds for 130 dates"
        for train_end, test_start, test_end in folds:
            # Last train date index = train_end-1; first test = test_start.
            # The gap must span the purge and embargo windows entirely.
            assert test_start - train_end == WF_PURGE + WF_EMBARGO
            assert train_end >= WF_MIN_TRAIN_DATES // 2
            assert test_end <= 130
            assert test_end - test_start >= WF_MIN_TEST_DATES

    def test_too_few_dates_yields_no_folds(self):
        min_needed = WF_MIN_TRAIN_DATES + WF_PURGE + WF_EMBARGO + WF_MIN_TEST_DATES
        assert _date_fold_bounds(min_needed - 1) == []
        assert _date_fold_bounds(min_needed) != []

    def test_walk_forward_separates_same_date_samples(self):
        # 3 tickers share every obs_date; a row-based split would put a date
        # on both sides. Predictive synthetic data ⇒ AUC well above chance.
        rng = np.random.RandomState(42)
        n_dates, n_tickers = 130, 3
        dates = [d for d in _dates(n_dates) for _ in range(n_tickers)]
        X = rng.randn(len(dates), len(FEATURE_NAMES))
        y = (X[:, 0] + 0.5 * rng.randn(len(dates)) > 0).astype(int)

        auc, oos_y, oos_p = _walk_forward_auc(X, y, dates, "logistic")

        assert oos_p.size > 0 and oos_p.size == oos_y.size
        assert 0.7 < auc <= 1.0

    def test_walk_forward_sentinel_on_insufficient_dates(self):
        dates = _dates(20)
        X = np.zeros((20, len(FEATURE_NAMES)))
        y = np.array([0, 1] * 10)
        auc, oos_y, oos_p = _walk_forward_auc(X, y, dates, "logistic")
        assert auc == 0.5 and oos_p.size == 0


# ---------------------------------------------------------------------------
# 4. Calibration
# ---------------------------------------------------------------------------

def _biased_predictions(n: int = 400, seed: int = 7):
    """Raw probs systematically above realized frequency (balanced-weight bias)."""
    rng = np.random.RandomState(seed)
    y_true = (rng.rand(n) < 0.25).astype(int)
    y_prob = np.clip(0.45 + 0.25 * y_true + 0.1 * rng.randn(n), 0.01, 0.99)
    return y_true, y_prob


class TestCalibration:
    def test_fit_pulls_probabilities_toward_observed_rate(self):
        y_true, y_prob = _biased_predictions()
        calib = _fit_calibration(y_true, y_prob)
        assert calib is not None and calib["method"] == "isotonic"

        calibrated = np.array([_apply_calibration(calib, p) for p in y_prob])
        # Raw mean (~0.51) overstates the 25% base rate; calibrated must not.
        assert abs(calibrated.mean() - y_true.mean()) < abs(y_prob.mean() - y_true.mean())

    def test_apply_is_monotonic_and_bounded(self):
        y_true, y_prob = _biased_predictions()
        calib = _fit_calibration(y_true, y_prob)
        grid = [_apply_calibration(calib, p) for p in np.linspace(0, 1, 21)]
        assert all(b >= a for a, b in zip(grid, grid[1:]))
        assert all(0.01 <= v <= 0.99 for v in grid)

    def test_fit_requires_minimum_samples_and_both_classes(self):
        y_true, y_prob = _biased_predictions(n=MIN_CALIBRATION_OOS - 1)
        assert _fit_calibration(y_true, y_prob) is None
        ones = np.ones(MIN_CALIBRATION_OOS, dtype=int)
        assert _fit_calibration(ones, np.full(MIN_CALIBRATION_OOS, 0.6)) is None

    def test_apply_without_calibration_is_identity(self):
        assert _apply_calibration(None, 0.37) == 0.37
        assert _apply_calibration({"method": "isotonic", "x": [0.5], "y": [0.5]}, 0.37) == 0.37

    def test_inference_fn_applies_stored_calibration(self):
        n_feat = len(FEATURE_NAMES)
        base_json = {
            "model_type":  "logistic",
            "coef":        [0.0] * n_feat,
            "intercept":   0.0,
            "classes":     [0, 1],
            "scaler_mean": [0.0] * n_feat,
            "scaler_std":  [1.0] * n_feat,
        }
        feats = [0.0] * n_feat

        raw_fn = make_inference_fn({"model_json": dict(base_json)})
        raw_prob, _, _ = raw_fn(feats)
        assert raw_prob == pytest.approx(0.5)

        calibrated_json = dict(base_json)
        calibrated_json["calibration"] = {
            "method": "isotonic", "x": [0.0, 1.0], "y": [0.1, 0.3],
        }
        cal_fn = make_inference_fn({"model_json": calibrated_json})
        cal_prob, _, _ = cal_fn(feats)
        assert cal_prob == pytest.approx(0.2)

    def test_inference_fn_returns_logit_contributions(self):
        # coef [2, -1, 0, …], identity scaler: contribution_i = coef_i · x_i
        # and their sum + intercept must reproduce the predicted logit.
        n_feat = len(FEATURE_NAMES)
        coef = [0.0] * n_feat
        coef[0], coef[1] = 2.0, -1.0
        fn = make_inference_fn({"model_json": {
            "model_type":  "logistic",
            "coef":        coef,
            "intercept":   -0.5,
            "classes":     [0, 1],
            "scaler_mean": [0.0] * n_feat,
            "scaler_std":  [1.0] * n_feat,
        }})

        feats = [0.0] * n_feat
        feats[0], feats[1] = 1.5, 2.0
        prob, _, contribs = fn(feats)

        assert len(contribs) == n_feat
        assert contribs[0] == pytest.approx(3.0)
        assert contribs[1] == pytest.approx(-2.0)
        assert all(c == 0.0 for c in contribs[2:])
        logit = sum(contribs) - 0.5
        assert prob == pytest.approx(1.0 / (1.0 + np.exp(-logit)))


# ---------------------------------------------------------------------------
# 5. Prediction drivers ("why this prediction")
# ---------------------------------------------------------------------------

from services.regime_ml_service import (  # noqa: E402
    RegimeFeatures,
    _build_heuristic_drivers,
    _build_supervised_drivers,
    _compute_score,
)


def _features(**overrides) -> RegimeFeatures:
    base = dict(
        spot_to_zgl_pct=2.0,
        spot_to_zgl_trend=0.2,
        ivp=40.0,
        ivp_trend=-1.0,
        hmm_state="low_vol",
        hmm_probability=0.8,
        sma_aligned=True,
        vix_dev_pct=-3.0,
        regime_duration_days=4,
        vix_term_structure_ratio=0.92,
        spot_to_vt_pct=1.5,
        breadth_proxy=0.3,
        gex_0dte_pct=25.0,
        price_roc5=1.2,
    )
    base.update(overrides)
    return RegimeFeatures(**base)


class TestPredictionDrivers:
    def test_supervised_drivers_ranked_by_contribution(self):
        n_feat = len(FEATURE_NAMES)
        feat_vec = [1.0] * n_feat
        contribs = [0.0] * n_feat
        contribs[_fidx("vix_dev_pct")]     = 0.9    # strongest, toward flip
        contribs[_fidx("spot_to_zgl_pct")] = -0.6   # anchoring
        contribs[_fidx("ivp")]             = 0.1

        drivers = _build_supervised_drivers(feat_vec, contribs)

        assert [d.feature for d in drivers] == ["vix_dev_pct", "spot_to_zgl_pct", "ivp"]
        assert drivers[0].push_flip > 0      # toward flip
        assert drivers[1].push_flip < 0      # anchoring
        assert drivers[0].label == "VIX stress"
        assert drivers[0].value_text == "VIX +1.0% vs 10-MA"

    def test_supervised_drivers_reject_length_mismatch(self):
        assert _build_supervised_drivers([1.0] * 3, [0.5] * 3) == []

    def test_heuristic_drivers_invert_with_regime(self):
        f = _features()
        pos = {d.feature: d.push_flip for d in _build_heuristic_drivers(f, "positive")}
        neg = {d.feature: d.push_flip for d in _build_heuristic_drivers(f, "negative")}

        # Same conviction components, opposite flip direction per regime:
        # bullish signals anchor a positive regime but would flip a negative one.
        shared = set(pos) & set(neg)
        assert shared
        for feature in shared:
            assert pos[feature] == pytest.approx(-neg[feature])

    def test_heuristic_drivers_sum_matches_score(self):
        # Drivers are score contributions in flip-space; with ≤6 kept, the
        # full (untruncated) sum must equal −score for a positive regime.
        f = _features(
            # zero out enough components that all survivors fit in top-6
            ivp_trend=None, breadth_proxy=None, price_roc5=None,
            vix_term_structure_ratio=None, spot_to_vt_pct=None, gex_0dte_pct=None,
        )
        drivers = _build_heuristic_drivers(f, "positive")
        score   = _compute_score(f, "positive")
        assert sum(d.push_flip for d in drivers) == pytest.approx(-score, abs=1e-3)

    def test_heuristic_drivers_unknown_regime_empty(self):
        assert _build_heuristic_drivers(_features(), "unknown") == []


# ---------------------------------------------------------------------------
# 6. Reconciliation outcomes
# ---------------------------------------------------------------------------

class TestRealizedFlip:
    def test_flip_inside_window(self):
        assert _realized_flip("positive", ["positive", "negative"]) is True

    def test_flip_on_first_observation(self):
        assert _realized_flip("positive", ["negative"]) is True

    def test_no_flip_after_full_window(self):
        assert _realized_flip("positive", ["positive"] * LOOKAHEAD) is False

    def test_window_still_open(self):
        assert _realized_flip("positive", ["positive"] * (LOOKAHEAD - 1)) is None
        assert _realized_flip("positive", []) is None

    def test_flip_beyond_window_ignored(self):
        future = ["positive"] * LOOKAHEAD + ["negative"]
        assert _realized_flip("positive", future) is False
