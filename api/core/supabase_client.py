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
#
# TWO NON-OBVIOUS THINGS LIVE HERE, both workarounds for PostgREST behaviour
# that fails SILENTLY rather than loudly. Read both before writing a query.
#
#   1. THE 1000-ROW CAP (see fetch_all)
#      Supabase caps every response at 1000 rows by default and does NOT
#      signal truncation. A query over 3 years of daily snapshots returns
#      exactly 1000 rows and looks like a complete answer.
#
#   2. HTTP/2 CONNECTION REUSE (see get_supabase)
#      postgrest-py hardcodes http2=True, which breaks against Supabase's load
#      balancer when it closes idle connections.
#
# QUERY RULES THAT FOLLOW FROM (1):
#   * "Latest N rows"   -> .order(col, desc=True).limit(N), then REVERSE in
#                          Python. Ordering ascending with a limit gives you
#                          the OLDEST N, which is almost never what was meant.
#   * "Full history"    -> fetch_all(), never a bare .execute().
#   * Any unbounded read that could exceed 1000 rows -> fetch_all().
# =============================================================================

_client:Optional[Client] = None


def fetch_all(build_query, page_size: int = 1000) -> list:
    """Fetch every row of a PostgREST query, paginating past the server-side
    max-rows cap (Supabase default: 1000 rows per request, applied silently).

    build_query: zero-arg callable returning a fresh, fully-filtered query
    builder with a deterministic ORDER BY (unique across rows — add secondary
    sort keys if needed) and no .range()/.limit() applied.

    WHY A CALLABLE, NOT A QUERY OBJECT: PostgREST builders are single-use —
    applying .range() mutates the builder, so reusing one across pages would
    stack range clauses and return garbage. Calling build_query() per page
    guarantees a clean builder every time.

    WHY THE ORDER BY MUST BE UNIQUE: pagination here is offset-based. If two
    rows compare equal under the sort key, Postgres may order them differently
    between page requests, which silently duplicates one row and drops another.
    Add a tiebreaker (id is the usual choice) to any ordering that is not
    already unique.

    TERMINATION: a short page means the last page was reached. A full page
    triggers another request, so a table whose size is an exact multiple of
    page_size costs one extra round trip returning zero rows — cheap, and it
    keeps the loop correct without a separate count query.

    This is NOT a snapshot read. Rows inserted between pages can be missed or
    seen twice; fine for the append-mostly snapshot tables it is used on.
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
    """Return the process-wide Supabase client, constructing it on first use.

    Lazy singleton rather than a module-level constant so that importing this
    module does not open a connection — which matters for the lazily-imported
    job modules in routers/scheduler_trigger.py, and for tests that import
    services without any Supabase credentials present.

    NOT thread-safe: two threads racing the first call can both construct a
    client, and one is discarded. Harmless — the clients are equivalent and the
    loser is garbage-collected — so no lock is used.

    One client is shared by every request. Because the whole service runs on the
    SERVICE key with no per-user auth, there is no user context to leak between
    requests through the shared client.
    """
    global _client
    if _client is None:
        _client = create_client(settings.supabase_url, settings.supabase_service_key)
        # postgrest hardcodes http2=True, which causes "Server disconnected" errors
        # when Supabase's load balancer closes idle HTTP/2 connections. Replace the
        # session with HTTP/1.1 so stale connections are retried transparently.
        #
        # The mechanism: httpx cannot always tell a closed-but-pooled HTTP/2
        # connection from a live one, and a request written into a dead stream
        # fails without being safely retryable. HTTP/1.1's connection handling
        # detects the close and transparently reopens. This bites hardest on the
        # scheduled jobs, which sit idle between hourly runs and then issue a
        # burst of queries against a pool full of stale connections.
        #
        # Copying base_url/headers/timeout off the old session preserves the auth
        # headers and URL that create_client configured; only the transport
        # changes. follow_redirects mirrors postgrest-py's own default.
        old = _client.postgrest.session
        _client.postgrest.session = httpx.Client(
            base_url=str(old.base_url),
            headers=dict(old.headers),
            timeout=old.timeout,
            follow_redirects=True,
            http2=False,
        )
    return _client
