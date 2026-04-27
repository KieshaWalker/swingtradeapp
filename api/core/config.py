from pydantic_settings import BaseSettings, SettingsConfigDict


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
