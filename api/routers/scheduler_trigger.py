# =============================================================================
# routers/scheduler_trigger.py
# =============================================================================
# HTTP endpoints called by Cloud Scheduler.
# These are also the entry points for the Cloud Functions deployment.
# =============================================================================

import logging

from fastapi import APIRouter, Request, HTTPException

from core.config import settings

router = APIRouter()
log = logging.getLogger(__name__)


def _verify_scheduler(request: Request) -> None:
    """Verify request came from Cloud Scheduler (or local dev)."""
    # Cloud Scheduler sets X-CloudScheduler-JobName header
    is_scheduler = request.headers.get("X-CloudScheduler-JobName") is not None
    is_local = request.client and request.client.host in ("127.0.0.1", "::1")
    secret = request.headers.get("X-Job-Secret", "")
    has_secret = secret == settings.python_api_secret and settings.python_api_secret

    if not (is_scheduler or is_local or has_secret):
        raise HTTPException(status_code=403, detail="Unauthorized scheduler call")


@router.post("/schwab-pull")
async def schwab_pull_trigger(request: Request):
    """Legacy monolithic pull — kept for manual testing.
    Prefer the individual job endpoints below for production.
    """
    _verify_scheduler(request)
    from jobs.schwab_pull import run_schwab_pull
    result = await run_schwab_pull()
    log.info("schwab_pull_complete result=%s", result)
    return result


# ── Individual pipeline job endpoints (staggered hourly, Mon–Fri) ─────────────

@router.post("/vol-surface-pull")
async def vol_surface_pull_trigger(request: Request):
    """Job 1 — Fetch chain → vol_surface_snapshots.
    Cron: 0 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.vol_surface_pull import run_vol_surface_pull
    result = await run_vol_surface_pull()
    log.info("vol_surface_pull_complete result=%s", result)
    return result


@router.post("/sabr-pull")
async def sabr_pull_trigger(request: Request):
    """Job 2 — vol_surface_snapshots → sabr_calibrations.
    Cron: 3 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.sabr_pull import run_sabr_pull
    result = await run_sabr_pull()
    log.info("sabr_pull_complete result=%s", result)
    return result


@router.post("/heston-pull")
async def heston_pull_trigger(request: Request):
    """Job 3 — vol_surface_snapshots → heston_calibrations.
    Cron: 6 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.heston_pull import run_heston_pull
    result = await run_heston_pull()
    log.info("heston_pull_complete result=%s", result)
    return result


@router.post("/iv-pull")
async def iv_pull_trigger(request: Request):
    """Job 4 — Fetch chain + sabr history → iv_snapshots.
    Cron: 9 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.iv_pull import run_iv_pull
    result = await run_iv_pull()
    log.info("iv_pull_complete result=%s", result)
    return result


@router.post("/greek-grid-pull")
async def greek_grid_pull_trigger(request: Request):
    """Job 5 — Fetch chain → greek_grid_snapshots.
    Cron: 12 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.greek_grid_pull import run_greek_grid_pull
    result = await run_greek_grid_pull()
    log.info("greek_grid_pull_complete result=%s", result)
    return result


@router.post("/greek-snapshots-pull")
async def greek_snapshots_pull_trigger(request: Request):
    """Job 6 — Fetch chain → greek_snapshots (ATM per DTE bucket).
    Cron: 15 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.greek_snapshots_pull import run_greek_snapshots_pull
    result = await run_greek_snapshots_pull()
    log.info("greek_snapshots_pull_complete result=%s", result)
    return result


@router.post("/regime-pull")
async def regime_pull_trigger(request: Request):
    """Job 7 — iv_snapshots + price history + VIX → regime_snapshots.
    Cron: 18 * * * 1-5
    """
    _verify_scheduler(request)
    from jobs.regime_pull import run_regime_pull
    result = await run_regime_pull()
    log.info("regime_pull_complete result=%s", result)
    return result


@router.post("/regime-train")
def regime_train_trigger(request: Request):
    """Triggered by Cloud Scheduler weekly (recommended: Sunday 00:00 UTC).
    Retrains the regime ML model on the latest 180 days of Supabase history
    and hot-reloads it into the inference cache.

    Cloud Scheduler job config:
      URL:      https://<your-cloud-run-url>/jobs/regime-train
      Method:   POST
      Schedule: 0 0 * * 0   (weekly, Sunday midnight UTC)
      Headers:  X-CloudScheduler-JobName: regime-train-weekly
    """
    _verify_scheduler(request)

    from core.supabase_client import get_supabase
    from services.regime_ml_trainer import train_and_store
    from services.regime_ml_service import load_trained_model

    sb     = get_supabase()
    result = train_and_store(sb, model_type="logistic", history_days=180)

    if result.sufficient_data:
        load_trained_model(sb)
        log.info(
            "regime_train_weekly: trained %s on %d samples (%d flips) "
            "AUC-ROC=%.3f — model hot-reloaded",
            result.model_type, result.n_samples, result.n_positive, result.auc_roc,
        )
    else:
        log.warning(
            "regime_train_weekly: insufficient data (%d samples) — "
            "need ≥80 labeled samples; skipping model update",
            result.n_samples,
        )

    return {
        "model_type":      result.model_type,
        "trained_at":      result.trained_at,
        "n_samples":       result.n_samples,
        "n_positive":      result.n_positive,
        "auc_roc":         result.auc_roc,
        "accuracy":        result.accuracy,
        "sufficient_data": result.sufficient_data,
    }
