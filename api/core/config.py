from pydantic_settings import BaseSettings, SettingsConfigDict


# =============================================================================
# api/core/config.py
# =============================================================================
# This module centralizes FastAPI environment configuration for the backend.
# When a schema or environment requirement changes, update the files that
# consume these values and the relevant `.env` entries.
#
# References:
#   api/core/supabase_client.py  -> uses supabase_url and supabase_service_key
#   api/jobs/schwab_pull.py     -> uses edge_function_base and supabase_service_key
#   api/routers/scheduler_trigger.py -> validates python_api_secret
#   lib/services/python_api/python_api_client.dart -> must reflect API routes if request/response models change
# =============================================================================
#
# HOW SETTINGS ARE RESOLVED
# -------------------------
# pydantic-settings reads each field from the environment first (case-insensitive,
# so SUPABASE_URL fills `supabase_url`), then from the .env file, then from the
# default declared below. Environment beats .env, which is what makes Cloud Run
# deployment work: no .env file ships with the image, and every value arrives as
# an env var or a mounted secret.
#
# FIELDS WITH NO DEFAULT ARE REQUIRED. supabase_url and supabase_service_key
# have none, so a missing value raises at IMPORT time, not at first use — the
# process fails to start rather than serving requests that will fail later.
# That is deliberate: a backend that cannot reach its database has nothing
# useful to do.
#
# The `settings` singleton at the bottom is constructed at import, so this
# fail-fast happens the moment anything imports core.config.
# =============================================================================

class Settings(BaseSettings):
    # extra="ignore" means unrelated environment variables (of which Cloud Run
    # sets many) are silently skipped rather than raising a validation error.
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # ── Required ─────────────────────────────────────────────────────────────
    supabase_url: str
    # SERVICE key — bypasses Row Level Security entirely. This is why endpoints
    # handling per-user data (watched contracts, positions) take the rows from
    # the client rather than querying them here: with this key there is no
    # database-side ownership check to fall back on.
    supabase_service_key: str

    # ── Optional ─────────────────────────────────────────────────────────────
    supabase_anon_key: str = ""
    # Shared secret for the /jobs/* scheduler endpoints. EMPTY MEANS DEV MODE:
    # _verify_scheduler then falls back to accepting localhost or a Cloud
    # Scheduler header, both of which are forgeable. Always set this in any
    # deployed environment.
    python_api_secret: str = ""
    fred_api_key: str = ""      # https://fred.stlouisfed.org/docs/api/api_key.html
    port: int = 8000
    log_level: str = "INFO"
    # Write-amplification guard for /iv/snapshot: how recently the shared
    # iv_snapshots row must have been written for a new request to skip
    # persisting. See routers/iv_analytics.py.
    iv_snapshot_staleness_minutes: int = 5

    @property
    def edge_function_base(self) -> str:
        """Base URL for Supabase Edge Functions.

        The broker proxy lives there — Schwab OAuth tokens are held by the edge
        functions, never by this service, so all price-history and chain fetches
        go through this base rather than to Schwab directly.
        """
        return f"{self.supabase_url}/functions/v1"


# Module-level singleton. Constructed at import time, so a missing required
# setting crashes startup rather than the first request that needs it.
settings = Settings()
