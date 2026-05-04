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

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    supabase_url: str
    supabase_service_key: str
    supabase_anon_key: str = ""
    python_api_secret: str = ""
    port: int = 8000
    log_level: str = "INFO"

    @property
    def edge_function_base(self) -> str:
        return f"{self.supabase_url}/functions/v1"


settings = Settings()
