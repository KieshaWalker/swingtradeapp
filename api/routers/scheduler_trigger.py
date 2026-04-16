# =============================================================================
# routers/scheduler_trigger.py
# =============================================================================
# HTTP endpoints called by Cloud Scheduler.
# These are also the entry points for the Cloud Functions deployment.
# =============================================================================

import asyncio
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
    """Triggered by Cloud Scheduler every 8 hours.
    Pulls Schwab data for all watched tickers and runs the full pipeline.
    """
    _verify_scheduler(request)
    from jobs.schwab_pull import run_schwab_pull
    result = await run_schwab_pull()
    return result
