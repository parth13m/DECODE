"""Dual-write service for analytics v2 migration.

Writes to both legacy tables (request_logs, analytics_events) and new
v2 tables (ai_requests, events) simultaneously.  The legacy write is
the primary — if it succeeds and the v2 write fails, we log the error
but do not roll back the legacy write.

Mode decomposition: the legacy ``mode`` column stores compound strings
like ``selection_followup`` or ``session_improve``.  The v2 schema
splits this into orthogonal ``origin_mode`` and ``request_type`` fields.
"""

import logging

from sqlalchemy.orm import Session

from app.models.ai_request import AIRequest
from app.models.analytics_event import AnalyticsEvent
from app.models.event import Event
from app.models.request_log import RequestLog
from app.pricing import estimate_cost as _estimate_cost

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Mode decomposition
# ---------------------------------------------------------------------------

# Maps compound mode strings to (origin_mode, request_type).
_COMPOUND_MODE_MAP: dict[str, tuple[str, str]] = {
    "selection": ("selection", "explain"),
    "screenshot": ("screenshot", "explain"),
    "session": ("session", "explain"),
    "selection_followup": ("selection", "followup"),
    "session_followup": ("session", "followup"),
    "screenshot_followup": ("screenshot", "followup"),
    "selection_improve": ("selection", "improve"),
    "session_improve": ("session", "improve"),
}


def decompose_mode(compound_mode: str | None) -> tuple[str | None, str]:
    """Split a compound mode string into (origin_mode, request_type).

    Returns (None, "unknown") for unrecognised modes.
    """
    if not compound_mode:
        return (None, "unknown")

    result = _COMPOUND_MODE_MAP.get(compound_mode)
    if result:
        return result

    # Vision requests use mode="selection" or similar but request_type is "vision"
    if compound_mode == "vision":
        return (None, "vision")

    # Enrichment background requests
    if compound_mode == "enrichment":
        return (None, "enrichment")

    # Unknown — preserve the raw value as origin_mode
    return (compound_mode, "unknown")


# ---------------------------------------------------------------------------
# Dual-write: AI requests
# ---------------------------------------------------------------------------

def log_ai_request(
    user_id: str,
    *,
    success: bool,
    latency_ms: int,
    error_type: str | None = None,
    mode: str | None = None,
    ai_provider: str | None = None,
    ai_model: str | None = None,
    context_tier: str | None = None,
    explanation_profile: str | None = None,
    language: str | None = None,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
    total_tokens: int | None = None,
    prompt_character_count: int | None = None,
) -> None:
    """Write an AI request to both legacy and v2 tables.

    Uses independent sessions so failures in one table don't affect the other.
    """
    from app.database import SessionLocal

    legacy_id: str | None = None

    # ── Legacy write (primary) ──
    legacy_db = SessionLocal()
    try:
        log = RequestLog(
            user_id=user_id,
            success=success,
            latency_ms=latency_ms,
            error_type=error_type,
            mode=mode,
            ai_provider=ai_provider,
            ai_model=ai_model,
            context_tier=context_tier,
            explanation_profile=explanation_profile,
            language=language,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
            prompt_character_count=prompt_character_count,
        )
        legacy_db.add(log)
        legacy_db.commit()
        legacy_id = log.id
    except Exception:
        logger.exception("DUAL_WRITE legacy request_log write failed user=%s", user_id)
        legacy_db.rollback()
    finally:
        legacy_db.close()

    # ── V2 write ──
    origin_mode, request_type = decompose_mode(mode)
    estimated_cost = _estimate_cost(ai_model, prompt_tokens, completion_tokens)

    v2_db = SessionLocal()
    try:
        ai_req = AIRequest(
            user_id=user_id,
            origin_mode=origin_mode,
            request_type=request_type,
            explanation_profile=explanation_profile,
            language=language,
            ai_provider=ai_provider or "unknown",
            ai_model=ai_model or "unknown",
            success=success,
            error_type=error_type,
            latency_ms=latency_ms,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
            prompt_character_count=prompt_character_count,
            estimated_cost_usd=estimated_cost,
            legacy_request_log_id=legacy_id,
        )
        v2_db.add(ai_req)

        # Also write an event for the AI request
        event = Event(
            user_id=user_id,
            event_type="ai_request",
            origin_mode=origin_mode,
            request_type=request_type,
            metadata_={
                "success": success,
                "latency_ms": latency_ms,
                "ai_provider": ai_provider,
                "ai_model": ai_model,
            },
        )
        v2_db.add(event)
        v2_db.commit()
    except Exception:
        logger.exception("DUAL_WRITE v2 ai_request write failed user=%s", user_id)
        v2_db.rollback()
    finally:
        v2_db.close()


# ---------------------------------------------------------------------------
# Dual-write: Analytics events
# ---------------------------------------------------------------------------

def log_analytics_event(
    db: Session,
    user_id: str,
    *,
    event_type: str,
    mode: str | None = None,
    metadata: dict | None = None,
) -> None:
    """Write a product analytics event to both legacy and v2 tables.

    The legacy write uses the caller-provided ``db`` session (committed
    by FastAPI's ``get_db`` dependency).  The v2 write uses an independent
    session.
    """
    # ── Legacy write (uses caller's session) ──
    legacy_event = AnalyticsEvent(
        user_id=user_id,
        event_type=event_type,
        mode=mode,
        metadata_=metadata,
    )
    db.add(legacy_event)
    # Caller's session commits via get_db dependency

    # ── V2 write ──
    from app.database import SessionLocal

    origin_mode, request_type = decompose_mode(mode)

    v2_db = SessionLocal()
    try:
        event = Event(
            user_id=user_id,
            event_type=event_type,
            origin_mode=origin_mode,
            request_type=request_type,
            metadata_=metadata,
        )
        v2_db.add(event)
        v2_db.commit()
    except Exception:
        logger.exception("DUAL_WRITE v2 event write failed user=%s type=%s", user_id, event_type)
        v2_db.rollback()
    finally:
        v2_db.close()
