from __future__ import annotations

# =============================================================================
# routers/fetch_dtes.py
# =============================================================================
# User-triggered on-demand chain fetch for a single ticker + selected DTEs.
# Called directly from the Flutter app (no Cloud Scheduler auth required).
# =============================================================================
#
# HOW THIS DIFFERS FROM THE SCHEDULED JOBS
# ----------------------------------------
# Everything under /jobs (routers/scheduler_trigger.py) is machine-triggered by
# Cloud Scheduler, runs across the whole watchlist, and is gated on a shared
# secret. This endpoint is the human path: the user picks ONE ticker and the
# specific expirations they care about, and gets a fresh pull immediately
# instead of waiting for the next scheduled run.
#
# NO SECRET IS REQUIRED HERE, unlike /jobs — deliberately, since the Flutter
# client cannot hold the scheduler secret safely. The exposure is bounded by
# what the endpoint can do: it only ever pulls public option-chain data for a
# validated ticker symbol and writes it to shared snapshot tables. It takes no
# free-form query, and `user_id` is used for attribution on the written rows,
# not for authorization.
#
# WHY strike_count MATTERS
# ------------------------
# The scheduled pulls use a modest strike count to keep the whole watchlist
# within time and quota budgets. A user asking for one ticker can afford a much
# wider chain, and the wings are exactly where a thin chain hurts most — SABR
# and Heston fits, RND extraction and GEX totals all degrade when the surface
# is truncated near the money. That is the main reason to reach for this
# endpoint rather than waiting for the scheduled run.
#
# Everything downstream of the fetch is shared with the scheduled path: the
# same ingesters, the same snapshot tables. See jobs/ticker_dtes_pull.py.
# =============================================================================

import logging
import re
from typing import List

from fastapi import APIRouter
from pydantic import BaseModel, Field, field_validator

from jobs.ticker_dtes_pull import run_ticker_dtes_pull

log    = logging.getLogger(__name__)
router = APIRouter()

# Stricter than the heston router's pattern: letters only, no dots or dashes.
# Anything reaching the Schwab chain endpoint must be a plain equity symbol.
_TICKER_RE = re.compile(r'^[A-Z]{1,6}$')


class FetchDtesRequest(BaseModel):
    ticker:           str
    # Attribution only — stamped onto the rows this pull writes. NOT an
    # authorization check; see the header note.
    user_id:          str
    # "YYYY-MM-DD" strings matching Schwab's expiration dates. min_length=1
    # prevents a no-op request that would still cost an upstream API call.
    expiration_dates: List[str] = Field(..., min_length=1)
    # Strikes per expiration, centred on the money. Default 100 is far wider
    # than the scheduled jobs use — see the header. Capped at 200 because
    # Schwab's response size and this service's request timeout both bite
    # beyond that.
    strike_count:     int       = Field(default=100, ge=10, le=200)

    @field_validator("ticker")
    @classmethod
    def validate_ticker(cls, v: str) -> str:
        """Upper-case and whitelist-validate before the symbol reaches Schwab."""
        v = v.upper().strip()
        if not _TICKER_RE.match(v):
            raise ValueError(f"Invalid ticker format: {v!r}")
        return v


@router.post("/ticker-dtes")
async def fetch_ticker_dtes(req: FetchDtesRequest):
    """Fetch selected expiration dates at high strikeCount for one ticker,
    then run all pipeline ingesters and write to all Supabase snapshot tables.

    Thin wrapper: all the work lives in jobs/ticker_dtes_pull.py, shared with
    the scheduled path so an on-demand pull and a scheduled one produce
    identically-shaped rows.

    Logged before dispatch because this is the one user-triggered write path
    into the snapshot tables — when a row's provenance is in question, this log
    line is what distinguishes a manual pull from a scheduled one.

    The `.upper()` here is redundant (the validator already upper-cased it) but
    harmless. Returns the job's own result dict, so the client sees per-stage
    ingester outcomes rather than a bare acknowledgement.
    """
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
