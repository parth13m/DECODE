import logging
from contextlib import asynccontextmanager
from collections.abc import AsyncGenerator
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.routers import admin, analytics_v2, auth, gateway

logger = logging.getLogger(__name__)
_STATIC_DIR = Path(__file__).parent / "static"


def _validate_config() -> None:
    """Log warnings for missing environment variables at startup.

    Does not crash — allows Railway health checks to pass while making
    misconfiguration immediately visible in logs.
    """
    missing: list[str] = []

    if not settings.ADMIN_TOKEN:
        missing.append("ADMIN_TOKEN")
    if not (settings.AI_API_KEY or settings.GROQ_API_KEY):
        missing.append("AI_API_KEY")

    if missing:
        logger.warning(
            "MISSING CONFIGURATION: The following environment variables are not set: %s. "
            "Some features will be unavailable until they are configured.",
            ", ".join(missing),
        )
    else:
        logger.info("All required environment variables are configured")

    logger.info(
        "Startup config: APP_ENV=%s, AI_ADAPTER=%s, AI_MODEL=%s",
        settings.APP_ENV,
        settings.AI_ADAPTER,
        settings.AI_MODEL,
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan handler for startup/shutdown hooks."""
    _validate_config()
    yield


app = FastAPI(
    title="Decode Platform",
    version="0.1.0",
    docs_url="/docs" if not settings.is_production else None,
    redoc_url=None,
    lifespan=lifespan,
)

app.include_router(auth.router)
app.include_router(gateway.router)
app.include_router(admin.router)
app.include_router(analytics_v2.router)


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/admin")
def admin_dashboard() -> FileResponse:
    """Serve the founder admin dashboard."""
    return FileResponse(_STATIC_DIR / "admin.html")


@app.get("/admin/v2")
def admin_dashboard_v2() -> FileResponse:
    """Serve the v2 operational intelligence dashboard."""
    return FileResponse(_STATIC_DIR / "v2" / "index.html")


# Serve v2 static assets (CSS, JS) under /static/v2/
app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")
