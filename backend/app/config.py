from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application configuration loaded from environment variables.

    Reads from a .env file in the backend/ directory when present.
    All values can be overridden by actual environment variables.

    ## AI Provider Configuration

    Each provider has explicit environment variables:
        ANTHROPIC_API_KEY   — Anthropic API key (required for production)
        ANTHROPIC_MODEL     — Anthropic model (default: claude-haiku-4-5-20251001)
        GROQ_API_KEY        — Groq API key (optional, for knowledge generation)
        GROQ_MODEL          — Groq model (default: llama-3.3-70b-versatile)

    Legacy variables (AI_ADAPTER, AI_API_KEY, AI_MODEL) are supported
    for backward compatibility but should be migrated to explicit
    provider variables.
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

    # --- Explicit provider configuration (preferred) ---
    ANTHROPIC_API_KEY: str = ""
    ANTHROPIC_MODEL: str = "claude-haiku-4-5-20251001"
    GROQ_API_KEY: str = ""
    GROQ_MODEL: str = "llama-3.3-70b-versatile"
    GROQ_VISION_MODEL: str = "qwen/qwen3.6-27b"

    # --- Legacy single-provider configuration (deprecated) ---
    # These are preserved for backward compatibility. New deployments
    # should use the explicit provider variables above.
    # AI_ADAPTER selects the backend adapter: "anthropic" | "openai_compat" | "gemini"
    AI_ADAPTER: str = "anthropic"
    AI_API_KEY: str = ""
    AI_MODEL: str = ""
    AI_API_URL: str = ""

    @property
    def is_production(self) -> bool:
        return self.APP_ENV == "production"

    def resolve_anthropic_key(self) -> str:
        """Return the effective Anthropic API key.

        Prefers ANTHROPIC_API_KEY. Falls back to AI_API_KEY when
        AI_ADAPTER is 'anthropic' (legacy configuration).
        """
        if self.ANTHROPIC_API_KEY:
            return self.ANTHROPIC_API_KEY
        if self.AI_API_KEY and self.AI_ADAPTER == "anthropic":
            return self.AI_API_KEY
        return ""

    def resolve_anthropic_model(self) -> str:
        """Return the effective Anthropic model.

        Prefers ANTHROPIC_MODEL. Falls back to AI_MODEL when
        AI_ADAPTER is 'anthropic' (legacy configuration).
        """
        if self.ANTHROPIC_MODEL != "claude-haiku-4-5-20251001":
            return self.ANTHROPIC_MODEL
        if self.AI_MODEL and self.AI_ADAPTER == "anthropic":
            return self.AI_MODEL
        return self.ANTHROPIC_MODEL

    def resolve_groq_key(self) -> str:
        """Return the effective Groq API key.

        Prefers GROQ_API_KEY. Falls back to AI_API_KEY when
        AI_ADAPTER is a Groq-compatible value (legacy configuration).
        """
        if self.GROQ_API_KEY:
            return self.GROQ_API_KEY
        if self.AI_API_KEY and self.AI_ADAPTER in ("groq", "openai_compat"):
            return self.AI_API_KEY
        return ""

    def resolve_groq_model(self) -> str:
        """Return the effective Groq model.

        Prefers GROQ_MODEL. Falls back to AI_MODEL when
        AI_ADAPTER is a Groq-compatible value (legacy configuration).
        """
        if self.GROQ_MODEL != "llama-3.3-70b-versatile":
            return self.GROQ_MODEL
        if self.AI_MODEL and self.AI_ADAPTER in ("groq", "openai_compat"):
            return self.AI_MODEL
        return self.GROQ_MODEL


settings = Settings()
