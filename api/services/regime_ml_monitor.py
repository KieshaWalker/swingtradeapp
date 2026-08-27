# =============================================================================
# services/regime_ml_monitor.py
# =============================================================================
# Post-deployment monitoring for the regime flip model.
#
# Training metrics say the model *was* good on history; these functions measure
# whether it still is, on data it has never seen:
#
#   log_predictions       — called by the close-capture regime_pull run; scores
#                           every ticker off finalized EOD snapshots and upserts
#                           one row per ticker into regime_ml_predictions.
#   reconcile_predictions — resolves pending predictions whose LOOKAHEAD-obs
#                           outcome window has closed (realized_flip), then
#                           recomputes rolling live metrics (AUC, hit rate,
#                           base rate, Brier, reliability bins) into
#                           regime_ml_live_metrics.
#
# Heuristic predictions are logged too — scoring_method distinguishes them, so
# the by_method breakdown gives a live supervised-vs-heuristic comparison.
# =============================================================================
#
# WHY THIS EXISTS AT ALL. A model can be overfitted into excellent training
# metrics and still be worthless live. The only honest test is to record what it
# forecast BEFORE the outcome was known, then grade it afterwards — which is
# exactly the two-phase design here:
#
#   log_predictions()       writes today's forecast, outcome unknown.
#   reconcile_predictions() grades forecasts whose window has since closed.
#
# Nothing can leak backwards: a prediction row is written once and only its
# outcome fields are filled in later.
#
# THE FOUR LIVE METRICS AND WHAT EACH CATCHES:
#   live_auc     RANKING quality — does a higher forecast probability actually
#                correspond to a higher chance of a flip? Insensitive to
#                calibration, so a systematically over-confident model can still
#                score well.
#   hit_rate     accuracy at a 0.5 threshold. MEANINGLESS WITHOUT base_rate.
#   base_rate    how often flips actually happen. If flips occur 30% of the
#                time, always predicting "no flip" scores a 70% hit rate while
#                being useless — this is the number that makes hit_rate readable.
#   brier        CALIBRATION — mean squared error of the probabilities. Lower is
#                better. Unlike AUC it punishes a model that ranks perfectly but
#                always says "80%".
#   reliability  the calibration curve, binned. Shows WHERE the miscalibration
#                is rather than just that it exists.
#
# HEURISTIC PREDICTIONS ARE LOGGED TOO, tagged by scoring_method, which turns
# the by_method breakdown into a live A/B test: is the trained model actually
# beating the hand-tuned fallback on data neither has seen?

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

import numpy as np

from .regime_ml_trainer import LOOKAHEAD

log = logging.getLogger(__name__)

# Rolling window for the live metrics. A tradeoff: long enough to accumulate
# enough resolved predictions for the numbers to mean anything, short enough
# that a model degrading in a new regime shows up rather than being averaged
# away by months of stale good performance.
LIVE_WINDOW_DAYS: int = 60   # rolling window for live metrics
# Calibration-curve buckets. Five wide bins rather than ten narrow ones — with a
# limited number of resolved predictions, narrow bins would each hold too few
# observations for their flip rate to be informative.
_RELIABILITY_BINS     = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]


# ---------------------------------------------------------------------------
# Prediction logging
# ---------------------------------------------------------------------------

def log_predictions(supabase_client) -> dict:
    """Score all tickers and upsert today's predictions.

    Must run after the day's snapshots are finalized (is_final=true) so the
    logged prediction is based on the same EOD convention used in training.

    THE is_final REQUIREMENT IS NOT A DETAIL. Training labels are built from
    finalized EOD rows, so a prediction logged off an intraday snapshot would be
    scored against features from a different distribution than the model learned
    on — training/serving skew, and the resulting live metrics would understate
    the model without anyone being able to see why. jobs/regime_pull.py calls
    this only on the close-capture cycle for exactly this reason.

    Upserts on (ticker, obs_date), so re-running the same day overwrites rather
    than duplicating.
    """
    from .regime_ml_service import analyze_all_tickers

    result = analyze_all_tickers(supabase_client)
    today  = date.today().isoformat()
    trained_at = (
        result.model_metadata.trained_at if result.model_metadata.available else None
    )

    rows: list[dict] = []
    for t in result.tickers:
        # Only predictions about a known regime can be reconciled later.
        # A flip is defined as "the regime changed from what it was", which is
        # undefined when the starting regime is unknown. Logging such a row would
        # leave it permanently pending, so it is skipped at write time.
        if t.current_regime not in ("positive", "negative"):
            continue
        rows.append({
            "ticker":           t.ticker,
            "obs_date":         today,
            "current_regime":   t.current_regime,
            # transition_prob is the probability being GRADED; ml_score and
            # bucket are stored alongside for diagnosis but are not scored.
            "flip_prob":        t.transition_prob,
            "ml_score":         t.ml_score,
            "bucket":           t.bucket,
            # scoring_method is what makes the supervised-vs-heuristic
            # comparison possible; model_trained_at pins which model version
            # produced this forecast, so a retrain does not silently blur two
            # models' live records together.
            "scoring_method":   t.scoring_method,
            "model_trained_at": trained_at,
        })

    if rows:
        try:
            supabase_client.table("regime_ml_predictions").upsert(
                rows, on_conflict="ticker,obs_date"
            ).execute()
        except Exception as exc:
            log.error("prediction_log_failed error=%r", exc)
            return {"logged": 0, "error": repr(exc)}

    log.info("regime_ml_predictions_logged n=%d date=%s", len(rows), today)
    return {"logged": len(rows)}


# ---------------------------------------------------------------------------
# Reconciliation
# ---------------------------------------------------------------------------

def reconcile_predictions(supabase_client) -> dict:
    """Resolve pending predictions and refresh rolling live metrics.

    A prediction resolves to realized_flip=True the moment a flip appears in
    its forward window, or to False once LOOKAHEAD final observations have
    passed without one. Predictions with open windows stay pending.

    THE ASYMMETRY IS DELIBERATE: a flip resolves the prediction IMMEDIATELY
    (there is nothing more to learn), while a non-flip must wait out the full
    window (a flip could still arrive). That is what makes the label match
    training's definition exactly.

    Every step is wrapped so a monitoring failure cannot break the pipeline that
    calls it — see jobs/regime_pull.py.
    """
    try:
        pending = (
            supabase_client
            .table("regime_ml_predictions")
            .select("id, ticker, obs_date, current_regime")
            .is_("reconciled_at", "null")
            .order("obs_date", desc=False)
            .execute()
        ).data or []
    except Exception as exc:
        log.warning("reconcile_fetch_pending_failed error=%r", exc)
        return {"reconciled": 0, "pending": 0, "error": repr(exc)}

    if not pending:
        return {"reconciled": 0, "pending": 0}

    # ONE batched fetch covering every pending prediction, rather than a query
    # per row. pending is sorted ascending, so [0] is the oldest date and bounds
    # the whole window.
    future_by_ticker = _fetch_final_regimes(
        supabase_client,
        min_date=pending[0]["obs_date"],
        tickers={p["ticker"] for p in pending},
    )

    now_iso    = datetime.now(timezone.utc).isoformat()
    reconciled = 0
    for p in pending:
        # STRICTLY AFTER the prediction date — a prediction is never graded
        # against the observation it was made from.
        future = [
            s["gamma_regime"]
            for s in future_by_ticker.get(p["ticker"], [])
            if s["obs_date"] > p["obs_date"]
            and s.get("gamma_regime") in ("positive", "negative")
        ]
        outcome = _realized_flip(p["current_regime"], future)
        if outcome is None:
            continue  # window still open
            # Left pending and retried on a later run — no row is ever lost,
            # and no partial window is ever graded.
        try:
            supabase_client.table("regime_ml_predictions").update({
                "realized_flip": outcome,
                "reconciled_at": now_iso,
            }).eq("id", p["id"]).execute()
            reconciled += 1
        except Exception as exc:
            log.warning("reconcile_update_failed id=%s error=%r", p["id"], exc)

    # Metrics are recomputed only when something actually resolved — a run that
    # grades nothing leaves the previous metrics row standing rather than
    # inserting a duplicate.
    metrics_row = None
    if reconciled:
        metrics_row = _recompute_live_metrics(supabase_client)

    log.info(
        "regime_ml_reconciled n=%d still_pending=%d metrics=%s",
        reconciled, len(pending) - reconciled,
        "updated" if metrics_row else "unchanged",
    )
    return {"reconciled": reconciled, "pending": len(pending) - reconciled}


def _realized_flip(current_regime: str, future_regimes: list[str]) ->Optional[bool]:
    """Outcome of one prediction given the forward regime sequence.

    True  — a flip occurred within the first LOOKAHEAD future observations.
    False — LOOKAHEAD observations passed with no flip.
    None  — window still open (fewer than LOOKAHEAD obs, none flipped).
    """
    # Counted in OBSERVATIONS, not calendar days — a missed pipeline run
    # stretches the wall-clock window but not the observation count, keeping the
    # label definition identical to training's.
    window = future_regimes[:LOOKAHEAD]
    # Any change from the starting regime counts as a flip.
    if any(r != current_regime for r in window):
        return True
    # Full window elapsed with no flip: a confirmed negative.
    if len(window) >= LOOKAHEAD:
        return False
    # Fewer than LOOKAHEAD observations and none flipped — undecided.
    return None


def _fetch_final_regimes(
    supabase_client, min_date: str, tickers: set
) -> dict[str, list[dict]]:
    """Final snapshots (ticker → date-sorted gamma_regime rows) since min_date.

    Paginated via fetch_all, because a multi-ticker window easily exceeds
    PostgREST's silent 1000-row cap — and a truncated fetch would resolve
    predictions against a partial future, producing wrong labels rather than an
    error.

    Returns {} on failure, which leaves every prediction pending rather than
    grading any of them incorrectly.
    """
    try:
        from core.supabase_client import fetch_all
        rows = fetch_all(
            lambda: (
                supabase_client
                .table("regime_snapshots")
                .select("ticker, obs_date, gamma_regime, is_final")
                .gte("obs_date", min_date)
                .order("obs_date", desc=False)
                .order("ticker", desc=False)
            )
        )
    except Exception as exc:
        log.warning("reconcile_fetch_snapshots_failed error=%r", exc)
        return {}

    by_ticker: dict[str, list[dict]] = {}
    for r in rows:
        # Outcomes must use the same finalized rows the labels were built from.
        # Note the test is `is False`, not falsy — a NULL is_final (rows written
        # before the column existed, or by the legacy schwab_pull path) is KEPT.
        # Deliberately permissive: excluding them would discard usable history.
        if r.get("is_final") is False or r["ticker"] not in tickers:
            continue
        by_ticker.setdefault(r["ticker"], []).append(r)
    return by_ticker


# ---------------------------------------------------------------------------
# Live metrics
# ---------------------------------------------------------------------------

def _recompute_live_metrics(supabase_client) ->Optional[dict]:
    """Compute rolling metrics over reconciled predictions and persist a row."""
    # Rolling window, so the metrics describe RECENT performance rather than the
    # model's lifetime average.
    cutoff = (date.today() - timedelta(days=LIVE_WINDOW_DAYS)).isoformat()
    try:
        rows = (
            supabase_client
            .table("regime_ml_predictions")
            .select("flip_prob, realized_flip, scoring_method")
            # Only RESOLVED predictions — pending ones have no outcome to score.
            .not_.is_("reconciled_at", "null")
            .gte("obs_date", cutoff)
            .execute()
        ).data or []
    except Exception as exc:
        log.warning("live_metrics_fetch_failed error=%r", exc)
        return None

    if not rows:
        return None

    metrics = _compute_metrics(rows)
    metrics["window_days"] = LIVE_WINDOW_DAYS

    by_method: dict[str, dict] = {}
    for method in sorted({r["scoring_method"] for r in rows}):
        subset = [r for r in rows if r["scoring_method"] == method]
        m = _compute_metrics(subset)
        by_method[method] = {
            "n":        m["n_predictions"],
            "live_auc": m["live_auc"],
            "hit_rate": m["hit_rate"],
        }
    metrics["by_method"] = by_method

    # INSERT, not upsert: each recomputation appends a new row, so the metrics
    # table is a time series of model performance rather than a single current
    # value. That history is what makes gradual degradation visible.
    try:
        supabase_client.table("regime_ml_live_metrics").insert(metrics).execute()
    except Exception as exc:
        log.warning("live_metrics_persist_failed error=%r", exc)
        return None

    log.info(
        "regime_ml_live_metrics n=%d flips=%d auc=%s hit=%s brier=%s",
        metrics["n_predictions"], metrics["n_flips"],
        metrics["live_auc"], metrics["hit_rate"], metrics["brier"],
    )
    return metrics


def _compute_metrics(rows: list[dict]) -> dict:
    y_true = np.array([1 if r["realized_flip"] else 0 for r in rows], dtype=int)
    y_prob = np.array([float(r["flip_prob"]) for r in rows], dtype=float)
    n      = len(rows)
    n_flip = int(y_true.sum())

    # AUC is UNDEFINED when every outcome is the same class — common early on,
    # when flips are rare and a short window may contain none. None is returned
    # rather than a misleading 0.5.
    live_auc:Optional[float] = None
    if len(np.unique(y_true)) > 1:
        from sklearn.metrics import roc_auc_score
        live_auc = round(float(roc_auc_score(y_true, y_prob)), 4)

    # Accuracy at a fixed 0.5 threshold. ALWAYS read against base_rate below —
    # with rare flips, predicting "never" scores a high hit rate and is useless.
    hit_rate = round(float(((y_prob >= 0.5).astype(int) == y_true).mean()), 4)
    # Brier score: mean squared error of the probabilities, so it grades
    # CALIBRATION rather than ranking. Lower is better; 0.25 is what a constant
    # 0.5 forecast scores.
    brier    = round(float(((y_prob - y_true) ** 2).mean()), 4)

    # THE CALIBRATION CURVE. For each probability bucket, compare the mean
    # FORECAST against the actual flip rate. A well-calibrated model has
    # mean_pred ≈ flip_rate in every bin; a systematic gap shows exactly where
    # it is over- or under-confident, which the single Brier number cannot.
    reliability = []
    for lo, hi in zip(_RELIABILITY_BINS[:-1], _RELIABILITY_BINS[1:]):
        # Half-open bins [lo, hi) so a value on a boundary lands in exactly one
        # bucket, with the final bin closed at 1.0 so a probability of exactly
        # 1.0 is not dropped.
        upper = (y_prob <= hi) if hi >= 1.0 else (y_prob < hi)
        mask  = (y_prob >= lo) & upper
        # Empty bins are omitted rather than reported with n=0, so `n` on each
        # returned bin is always meaningful — and a bin with a small n should be
        # read as noise.
        if not mask.any():
            continue
        reliability.append({
            "lo":        lo,
            "hi":        hi,
            "n":         int(mask.sum()),
            "mean_pred": round(float(y_prob[mask].mean()), 4),
            "flip_rate": round(float(y_true[mask].mean()), 4),
        })

    return {
        "n_predictions": n,
        "n_flips":       n_flip,
        "live_auc":      live_auc,
        "hit_rate":      hit_rate,
        "base_rate":     round(n_flip / n, 4) if n else None,
        "brier":         brier,
        "reliability":   reliability,
    }
