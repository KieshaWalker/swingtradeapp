from __future__ import annotations
from typing import Optional

import httpx
from supabase import Client, create_client
from .config import settings

# =============================================================================
# api/core/supabase_client.py
# =============================================================================
# Provides a cached Supabase client for use by routers and services.
# If the Supabase schema changes, update these callers as well:
#   api/routers/fair_value.py      -> reads heston_calibrations
#   api/routers/regime.py          -> reads/writes regime_snapshots and regime_ml_models
#   api/jobs/schwab_pull.py       -> writes chain data and snapshots
#   api/services/*                 -> any Supabase-backed feature implementation
# =============================================================================

_client:Optional[Client] = None


def fetch_all(build_query, page_size: int = 1000) -> list:
    """Fetch every row of a PostgREST query, paginating past the server-side
    max-rows cap (Supabase default: 1000 rows per request, applied silently).

    build_query: zero-arg callable returning a fresh, fully-filtered query
    builder with a deterministic ORDER BY (unique across rows — add secondary
    sort keys if needed) and no .range()/.limit() applied.
    """
    rows: list = []
    offset = 0
    while True:
        page = (
            build_query().range(offset, offset + page_size - 1).execute()
        ).data or []
        rows.extend(page)
        if len(page) < page_size:
            return rows
        offset += page_size


def get_supabase() -> Client:
    global _client
    if _client is None:
        _client = create_client(settings.supabase_url, settings.supabase_service_key)
        # postgrest hardcodes http2=True, which causes "Server disconnected" errors
        # when Supabase's load balancer closes idle HTTP/2 connections. Replace the
        # session with HTTP/1.1 so stale connections are retried transparently.
        old = _client.postgrest.session
        _client.postgrest.session = httpx.Client(
            base_url=str(old.base_url),
            headers=dict(old.headers),
            timeout=old.timeout,
            follow_redirects=True,
            http2=False,
        )
    return _client
