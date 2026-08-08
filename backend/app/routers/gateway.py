import json
import logging
import time

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.dual_write_service import log_ai_request, log_analytics_event
from app.gateway_service import GatewayError, call_llm, call_vision_llm, stream_llm
from app.models.user import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/gateway", tags=["gateway"])


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(..., min_length=1)
    system_prompt: str | None = None
    mode: str | None = None
    context_tier: str | None = None
    explanation_profile: str | None = None
    language: str | None = None


class ChatResponse(BaseModel):
    content: str


@router.post("/chat", response_model=ChatResponse)
async def chat(
    body: ChatRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ChatResponse:
    """Send messages to the AI and receive a response.

    Requires Bearer token authentication. Only active users may access.
    """
    messages = [{"role": m.role, "content": m.content} for m in body.messages]

    start = time.monotonic()

    try:
        content, latency_ms, token_usage, ai_provider, ai_model = await call_llm(
            messages, system_prompt=body.system_prompt,
        )
    except GatewayError as exc:
        latency_ms = int((time.monotonic() - start) * 1000)
        _log_request(
            db, user.id, success=False, latency_ms=latency_ms,
            error_type=exc.error_type, mode=body.mode,
            context_tier=body.context_tier,
            explanation_profile=body.explanation_profile,
            language=body.language,
            ai_provider=settings.AI_ADAPTER, ai_model=None,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="AI service unavailable",
        ) from None

    _log_request(
        db, user.id, success=True, latency_ms=latency_ms, mode=body.mode,
        context_tier=body.context_tier,
        explanation_profile=body.explanation_profile,
        language=body.language,
        prompt_tokens=token_usage.get("prompt_tokens"),
        completion_tokens=token_usage.get("completion_tokens"),
        total_tokens=token_usage.get("total_tokens"),
        prompt_character_count=token_usage.get("prompt_character_count"),
        ai_provider=ai_provider, ai_model=ai_model,
    )

    return ChatResponse(content=content)


@router.post("/chat/stream")
async def chat_stream(
    body: ChatRequest,
    user: User = Depends(get_current_user),
) -> StreamingResponse:
    """Stream AI response tokens via Server-Sent Events.

    Requires Bearer token authentication. Only active users may access.

    SSE event format (Decode-owned, not provider-specific):
        data: {"type":"token","content":"..."}
        data: {"type":"done","usage":{...}}
        data: {"type":"error","message":"..."}
    """
    # Capture user fields as primitives while the DB session is still open.
    # The generator runs after FastAPI's dependency cleanup closes the session,
    # so accessing the ORM object inside the generator raises DetachedInstanceError.
    user_id = user.id

    logger.info("TRACE_STREAM_V2 chat_stream entered user=%s mode=%s", user_id, body.mode)
    messages = [{"role": m.role, "content": m.content} for m in body.messages]

    async def event_generator():
        logger.info("TRACE_STREAM_V2 generator_started user=%s", user_id)
        start = time.monotonic()
        # Resolved provider/model — populated by the "meta" event from
        # stream_llm() before any tokens are yielded.
        ai_provider = settings.AI_ADAPTER  # fallback for pre-meta errors
        ai_model: str | None = None
        token_usage = {}

        # ── DIAG: gateway SSE diagnostics ──
        _diag_first_sse_time = None
        _diag_sse_count = 0

        try:
            async for event_type, data in stream_llm(messages, system_prompt=body.system_prompt):
                if event_type == "meta":
                    # Capture resolved provider/model for logging.
                    ai_provider = data.get("_resolved_provider", ai_provider)
                    ai_model = data.get("_resolved_model", ai_model)
                elif event_type == "token":
                    _diag_sse_count += 1
                    if _diag_first_sse_time is None:
                        _diag_first_sse_time = time.monotonic()
                        logger.info(
                            "DIAG_GATEWAY first_sse_ms=%.0f",
                            (_diag_first_sse_time - start) * 1000,
                        )
                    yield f"data: {json.dumps({'type': 'token', 'content': data})}\n\n"
                elif event_type == "done":
                    token_usage = data if isinstance(data, dict) else {}
                    # Extract resolved values (also attached to done event).
                    ai_provider = token_usage.pop("_resolved_provider", ai_provider)
                    ai_model = token_usage.pop("_resolved_model", ai_model)
                    latency_ms = int((time.monotonic() - start) * 1000)
                    logger.info(
                        "TRACE_STREAM_V2 done_received user=%s sse_events=%d latency_ms=%d",
                        user_id, _diag_sse_count, latency_ms,
                    )
                    # Log BEFORE yielding the done event. Once we yield,
                    # the client may close the connection and the generator
                    # will never resume — so any code after yield is unreachable.
                    _log_request(
                        None, user_id, success=True, latency_ms=latency_ms,
                        mode=body.mode, context_tier=body.context_tier,
                        explanation_profile=body.explanation_profile,
                        language=body.language,
                        prompt_tokens=token_usage.get("prompt_tokens"),
                        completion_tokens=token_usage.get("completion_tokens"),
                        total_tokens=token_usage.get("total_tokens"),
                        prompt_character_count=token_usage.get("prompt_character_count"),
                        ai_provider=ai_provider, ai_model=ai_model,
                    )
                    logger.info("TRACE_STREAM_V2 log_committed user=%s", user_id)
                    yield f"data: {json.dumps({'type': 'done', 'usage': token_usage})}\n\n"

        except GatewayError as exc:
            latency_ms = int((time.monotonic() - start) * 1000)
            logger.info("TRACE_STREAM_V2 GatewayError user=%s error=%s", user_id, exc.error_type)
            _log_request(
                None, user_id, success=False, latency_ms=latency_ms,
                error_type=exc.error_type, mode=body.mode,
                context_tier=body.context_tier,
                explanation_profile=body.explanation_profile,
                language=body.language,
                ai_provider=ai_provider, ai_model=ai_model,
            )
            yield f"data: {json.dumps({'type': 'error', 'message': 'AI service unavailable'})}\n\n"
            return

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ---------------------------------------------------------------------------
# Vision — Enhanced Explanation visual context extraction
# ---------------------------------------------------------------------------

class VisionRequest(BaseModel):
    image_data: str = Field(..., min_length=1, description="Base64-encoded JPEG image")
    prompt: str = Field(..., min_length=1)
    mode: str | None = None


class VisionResponse(BaseModel):
    content: str


@router.post("/vision", response_model=VisionResponse)
async def vision(
    body: VisionRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> VisionResponse:
    """Extract visual context from an image using the configured vision provider.

    Requires Bearer token authentication. Used by the Enhanced Explanation
    feature to extract contextual evidence from screenshots.
    Provider is selected by VISION_PROVIDER env var.
    """
    start = time.monotonic()

    logger.info(
        "VISION_ENDPOINT: image_data_len=%d prompt_len=%d mode=%s provider=%s",
        len(body.image_data), len(body.prompt), body.mode, settings.VISION_PROVIDER,
    )

    try:
        content, latency_ms, token_usage, ai_provider, ai_model = await call_vision_llm(
            image_base64=body.image_data,
            prompt=body.prompt,
        )
    except GatewayError as exc:
        latency_ms = int((time.monotonic() - start) * 1000)
        _log_request(
            db, user.id, success=False, latency_ms=latency_ms,
            error_type=exc.error_type, mode=body.mode,
            ai_provider=settings.VISION_PROVIDER, ai_model=None,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Vision service unavailable",
        ) from None

    _log_request(
        db, user.id, success=True, latency_ms=latency_ms, mode=body.mode,
        ai_provider=ai_provider, ai_model=ai_model,
        prompt_tokens=token_usage.get("prompt_tokens"),
        completion_tokens=token_usage.get("completion_tokens"),
        total_tokens=token_usage.get("total_tokens"),
    )

    return VisionResponse(content=content)


def _log_request(
    db: Session,
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
    """Record a gateway request via dual-write (legacy + v2 tables).

    Delegates to ``log_ai_request`` which writes to both ``request_logs``
    (legacy) and ``ai_requests`` + ``events`` (v2) using independent sessions.
    """
    if not ai_provider:
        logger.warning("ANALYTICS_INTEGRITY ai_provider is empty for user=%s mode=%s", user_id, mode)
    if not ai_model and success:
        logger.warning("ANALYTICS_INTEGRITY ai_model is empty for successful request user=%s mode=%s", user_id, mode)

    log_ai_request(
        user_id,
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


# ---------------------------------------------------------------------------
# Analytics events — lightweight client-reported events (fire-and-forget)
# ---------------------------------------------------------------------------

_ALLOWED_EVENT_TYPES = frozenset({
    "improve_copy",
    "improve_replace",
    "improve_dismiss",
    "improve_no_change",
    "feedback",
})


class AnalyticsEventRequest(BaseModel):
    event_type: str
    mode: str | None = None
    metadata: dict | None = None


@router.post("/analytics/event", status_code=status.HTTP_204_NO_CONTENT)
async def record_analytics_event(
    body: AnalyticsEventRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Record a client-side analytics event."""
    if body.event_type not in _ALLOWED_EVENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown event_type: {body.event_type}",
        )

    log_analytics_event(
        db,
        user.id,
        event_type=body.event_type,
        mode=body.mode,
        metadata=body.metadata,
    )
