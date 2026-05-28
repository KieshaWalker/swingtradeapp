from __future__ import annotations

# =============================================================================
# routers/fetch_dtes.py
# =============================================================================
# User-triggered on-demand chain fetch for a single ticker + selected DTEs.
# Called directly from the Flutter app (no Cloud Scheduler auth required).
# =============================================================================

import logging
import re
from typing import List

from fastapi import APIRouter
from pydantic import BaseModel, Field, field_validator

from jobs.ticker_dtes_pull import run_ticker_dtes_pull

log    = logging.getLogger(__name__)
router = APIRouter()

_TICKER_RE = re.compile(r'^[A-Z]{1,6}$')


class FetchDtesRequest(BaseModel):
    ticker:           str
    user_id:          str
    expiration_dates: List[str] = Field(..., min_length=1)
    strike_count:     int       = Field(default=100, ge=10, le=200)

    @field_validator("ticker")
    @classmethod
    def validate_ticker(cls, v: str) -> str:
        v = v.upper().strip()
        if not _TICKER_RE.match(v):
            raise ValueError(f"Invalid ticker format: {v!r}")
        return v


@router.post("/ticker-dtes")
async def fetch_ticker_dtes(req: FetchDtesRequest):
    """Fetch selected expiration dates at high strikeCount for one ticker,
    then run all pipeline ingesters and write to all Supabase snapshot tables."""
    log.info(
        "fetch_ticker_dtes ticker=%s exps=%s strike_count=%d",
        req.ticker, req.expiration_dates, req.strike_count,
    )
    return await run_ticker_dtes_pull(
        ticker           = req.ticker.upper(),
        user_id          = req.user_id,
        expiration_dates = req.expiration_dates,
        strike_count     = req.strike_count,
    )
