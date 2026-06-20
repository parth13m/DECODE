from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application configuration loaded from environment variables.

    Reads from a .env file in the backend/ directory when present.
    All values can be overridden by actual environment variables.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
    )

    DATABASE_URL: str
    APP_ENV: str = "development"
    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    ADMIN_TOKEN: str = ""
    # --- Provider-agnostic AI configuration ---
    # AI_ADAPTER: "openai_compat" | "anthropic" | "gemini"
    AI_ADAPTER: str = "openai_compat"
    AI_API_KEY: str = ""
    AI_MODEL: str = "llama-3.3-70b-versatile"
    # Optional: override the default API URL for the adapter.
    # When empty, a built-in default is used based on AI_ADAPTER.
    AI_API_URL: str = ""

    # Legacy — kept for backward compatibility during migration.
    # If AI_API_KEY is empty, falls back to GROQ_API_KEY.
    GROQ_API_KEY: str = ""

    @property
    def is_production(self) -> bool:
        return self.APP_ENV == "production"


settings = Settings()
