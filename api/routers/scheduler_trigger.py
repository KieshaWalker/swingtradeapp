# =============================================================================
# routers/scheduler_trigger.py
# =============================================================================
# HTTP endpoints called by Cloud Scheduler.
# These are also the entry points for the Cloud Functions deployment.
# =============================================================================

import asyncio
import logging

from fastapi import APIRouter, BackgroundTasks, Request, HTTPException

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
async def schwab_pull_trigger(request: Request, background_tasks: BackgroundTasks):
    """Triggered by Cloud Scheduler every 8 hours.
    Returns 200 immediately so Cloud Scheduler doesn't timeout; the pipeline
    runs in a background task that Cloud Run keeps alive until completion.
    """
    _verify_scheduler(request)

    async def _run() -> None:
        from jobs.schwab_pull import run_schwab_pull
        try:
            result = await run_schwab_pull()
            log.info("schwab_pull_complete result=%s", result)
        except Exception as exc:
            log.error("schwab_pull_error error=%s", exc)

    background_tasks.add_task(_run)
    return {"status": "accepted"}


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
