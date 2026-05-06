from __future__ import annotations

# =============================================================================
# jobs/sofr_pull.py
# =============================================================================
# Job — Fetch the latest SOFR rate from FRED and refresh the in-process cache.
# Cron: 30 13 * * 1-5  (8:30 AM ET, Mon–Fri — after NY Fed publishes)
#
# FRED series SOFR is published by the NY Fed each business day by ~8 AM ET.
# Running at 8:30 AM ET ensures we catch the day's rate before any pricing runs.
# =============================================================================

import logging

from services.rate_service import refresh_sofr

log = logging.getLogger(__name__)


async def run_sofr_pull() -> dict:
    result = await refresh_sofr()
    log.info("sofr_pull_complete status=%s rate=%.4f", result.get("status"), result.get("rate", 0))
    return result
