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

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

import numpy as np

from .regime_ml_trainer import LOOKAHEAD

log = logging.getLogger(__name__)

LIVE_WINDOW_DAYS: int = 60   # rolling window for live metrics
_RELIABILITY_BINS     = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]


# ---------------------------------------------------------------------------
# Prediction logging
# ---------------------------------------------------------------------------

def log_predictions(supabase_client) -> dict:
    """Score all tickers and upsert today's predictions.

    Must run after the day's snapshots are finalized (is_final=true) so the
    logged prediction is based on the same EOD convention used in training.
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
        if t.current_regime not in ("positive", "negative"):
            continue
        rows.append({
            "ticker":           t.ticker,
            "obs_date":         today,
            "current_regime":   t.current_regime,
            "flip_prob":        t.transition_prob,
            "ml_score":         t.ml_score,
            "bucket":           t.bucket,
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

    future_by_ticker = _fetch_final_regimes(
        supabase_client,
        min_date=pending[0]["obs_date"],
        tickers={p["ticker"] for p in pending},
    )

    now_iso    = datetime.now(timezone.utc).isoformat()
    reconciled = 0
    for p in pending:
        future = [
            s["gamma_regime"]
            for s in future_by_ticker.get(p["ticker"], [])
            if s["obs_date"] > p["obs_date"]
            and s.get("gamma_regime") in ("positive", "negative")
        ]
        outcome = _realized_flip(p["current_regime"], future)
        if outcome is None:
            continue  # window still open
        try:
            supabase_client.table("regime_ml_predictions").update({
                "realized_flip": outcome,
                "reconciled_at": now_iso,
            }).eq("id", p["id"]).execute()
            reconciled += 1
        except Exception as exc:
            log.warning("reconcile_update_failed id=%s error=%r", p["id"], exc)

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
    window = future_regimes[:LOOKAHEAD]
    if any(r != current_regime for r in window):
        return True
    if len(window) >= LOOKAHEAD:
        return False
    return None


def _fetch_final_regimes(
    supabase_client, min_date: str, tickers: set
) -> dict[str, list[dict]]:
    """Final snapshots (ticker → date-sorted gamma_regime rows) since min_date."""
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
        if r.get("is_final") is False or r["ticker"] not in tickers:
            continue
        by_ticker.setdefault(r["ticker"], []).append(r)
    return by_ticker


# ---------------------------------------------------------------------------
# Live metrics
# ---------------------------------------------------------------------------

def _recompute_live_metrics(supabase_client) ->Optional[dict]:
    """Compute rolling metrics over reconciled predictions and persist a row."""
    cutoff = (date.today() - timedelta(days=LIVE_WINDOW_DAYS)).isoformat()
    try:
        rows = (
            supabase_client
            .table("regime_ml_predictions")
            .select("flip_prob, realized_flip, scoring_method")
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

    live_auc:Optional[float] = None
    if len(np.unique(y_true)) > 1:
        from sklearn.metrics import roc_auc_score
        live_auc = round(float(roc_auc_score(y_true, y_prob)), 4)

    hit_rate = round(float(((y_prob >= 0.5).astype(int) == y_true).mean()), 4)
    brier    = round(float(((y_prob - y_true) ** 2).mean()), 4)

    reliability = []
    for lo, hi in zip(_RELIABILITY_BINS[:-1], _RELIABILITY_BINS[1:]):
        upper = (y_prob <= hi) if hi >= 1.0 else (y_prob < hi)
        mask  = (y_prob >= lo) & upper
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
