from __future__ import annotations

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

_client: Client | None = None


def get_supabase() -> Client:
    global _client
    if _client is None:
        _client = create_client(settings.supabase_url, settings.supabase_service_key)
    return _client
