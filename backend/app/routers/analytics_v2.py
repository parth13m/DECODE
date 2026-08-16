"""Analytics API v2 — structured endpoints for the Founder Dashboard.

All endpoints require ADMIN_TOKEN authentication (same as /api/admin).
Data is read from the new v2 tables (``ai_requests``, ``events``,
``daily_summaries``) with automatic fallback to legacy ``request_logs``
when v2 data is insufficient.
"""

import logging
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import Date, and_, case, cast, func as sa_func
from sqlalchemy.orm import Session

from app.auth import require_admin
from app.database import get_db
from app.models.ai_request import AIRequest
from app.models.analytics_event import AnalyticsEvent
from app.models.daily_summary import DailySummary
from app.models.event import Event
from app.models.request_log import RequestLog
from app.models.user import User, UserStatus

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/v2/analytics",
    tags=["analytics-v2"],
    dependencies=[Depends(require_admin)],
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_date_range(
    days: int | None,
    start: date | None,
    end: date | None,
) -> tuple[date, date]:
    """Resolve date range from query params.

    Accepts any combination:
    - ``start`` + ``end``: explicit range
    - ``start`` only: start to today
    - ``end`` only: end - days (default 30) to end
    - ``days`` only: last N days ending today
    - nothing: last 30 days ending today
    """
    if start and end:
        return start, end
    d = days or 30
    if start and not end:
        return start, date.today()
    if end and not start:
        return end - timedelta(days=d), end
    end_date = date.today()
    return end_date - timedelta(days=d), end_date


def _date_filter(model, start_date: date, end_date: date):
    """Return a date-range filter for a model with created_at column."""
    return (
        cast(model.created_at, Date) >= start_date,
        cast(model.created_at, Date) <= end_date,
    )


def _data_source(db: Session, start_date: date, end_date: date) -> str:
    """Determine whether v2 data exists for the given range."""
    v2_count = db.query(sa_func.count(AIRequest.id)).filter(
        *_date_filter(AIRequest, start_date, end_date)
    ).scalar() or 0
    return "v2" if v2_count > 0 else "legacy"


def _format_request(r) -> dict:
    """Serialise an AIRequest row into a consistent dict shape.

    Used by every endpoint that returns a list of individual requests
    so the response shape is identical everywhere.
    """
    return {
        "id": r.id,
        "created_at": str(r.created_at),
        "user_id": r.user_id,
        "origin_mode": r.origin_mode,
        "request_type": r.request_type,
        "ai_provider": r.ai_provider,
        "ai_model": r.ai_model,
        "success": r.success,
        "error_type": r.error_type,
        "latency_ms": r.latency_ms,
        "prompt_tokens": r.prompt_tokens,
        "completion_tokens": r.completion_tokens,
        "total_tokens": r.total_tokens,
        "estimated_cost_usd": r.estimated_cost_usd,
    }


# ---------------------------------------------------------------------------
# Executive Summary
# ---------------------------------------------------------------------------

@router.get("/executive")
def get_executive_summary(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """High-level KPIs for the founder: total requests, users, cost, reliability."""
    start_date, end_date = _parse_date_range(days, start, end)
    source = _data_source(db, start_date, end_date)

    if source == "v2":
        result = _executive_from_v2(db, start_date, end_date)
    else:
        result = _executive_from_legacy(db, start_date, end_date)

    result["_source"] = source
    return result


def _executive_from_v2(db: Session, start_date: date, end_date: date) -> dict:
    filters = _date_filter(AIRequest, start_date, end_date)

    total = db.query(sa_func.count(AIRequest.id)).filter(*filters).scalar() or 0
    successful = db.query(sa_func.count(AIRequest.id)).filter(
        *filters, AIRequest.success.is_(True)
    ).scalar() or 0
    unique_users = db.query(
        sa_func.count(sa_func.distinct(AIRequest.user_id))
    ).filter(*filters).scalar() or 0
    total_cost = db.query(
        sa_func.sum(AIRequest.estimated_cost_usd)
    ).filter(*filters).scalar()
    avg_latency = db.query(
        sa_func.avg(AIRequest.latency_ms)
    ).filter(*filters, AIRequest.success.is_(True)).scalar()

    daily = db.query(
        cast(AIRequest.created_at, Date).label("day"),
        sa_func.count().label("requests"),
        sa_func.count(sa_func.distinct(AIRequest.user_id)).label("users"),
    ).filter(*filters).group_by("day").order_by("day").all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "total_requests": total,
        "successful_requests": successful,
        "failed_requests": total - successful,
        "success_rate": round(successful / total * 100, 1) if total else 0,
        "unique_users": unique_users,
        "total_cost_usd": round(total_cost, 4) if total_cost else 0,
        "avg_latency_ms": round(avg_latency) if avg_latency else 0,
        "daily_trend": [
            {"date": str(r.day), "requests": r.requests, "users": r.users}
            for r in daily
        ],
    }


def _executive_from_legacy(db: Session, start_date: date, end_date: date) -> dict:
    filters = _date_filter(RequestLog, start_date, end_date)

    total = db.query(sa_func.count(RequestLog.id)).filter(*filters).scalar() or 0
    successful = db.query(sa_func.count(RequestLog.id)).filter(
        *filters, RequestLog.success.is_(True)
    ).scalar() or 0
    unique_users = db.query(
        sa_func.count(sa_func.distinct(RequestLog.user_id))
    ).filter(*filters).scalar() or 0
    avg_latency = db.query(
        sa_func.avg(RequestLog.latency_ms)
    ).filter(*filters, RequestLog.success.is_(True)).scalar()

    daily = db.query(
        cast(RequestLog.created_at, Date).label("day"),
        sa_func.count().label("requests"),
        sa_func.count(sa_func.distinct(RequestLog.user_id)).label("users"),
    ).filter(*filters).group_by("day").order_by("day").all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "total_requests": total,
        "successful_requests": successful,
        "failed_requests": total - successful,
        "success_rate": round(successful / total * 100, 1) if total else 0,
        "unique_users": unique_users,
        "total_cost_usd": 0,
        "avg_latency_ms": round(avg_latency) if avg_latency else 0,
        "daily_trend": [
            {"date": str(r.day), "requests": r.requests, "users": r.users}
            for r in daily
        ],
    }


# ---------------------------------------------------------------------------
# Product Analytics
# ---------------------------------------------------------------------------

@router.get("/product")
def get_product_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Product usage breakdown: modes, request types, profiles."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    _effective_mode = case(
        (AIRequest.origin_mode.isnot(None), AIRequest.origin_mode),
        else_=sa_func.coalesce(AIRequest.request_type, "other"),
    ).label("mode")
    mode_rows = db.query(
        _effective_mode,
        sa_func.count().label("count"),
        sa_func.count(sa_func.distinct(AIRequest.user_id)).label("users"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*filters).group_by("mode").all()

    type_rows = db.query(
        AIRequest.request_type.label("type"),
        sa_func.count().label("count"),
        sa_func.count(sa_func.distinct(AIRequest.user_id)).label("users"),
    ).filter(*filters).group_by("type").all()

    profile_rows = db.query(
        sa_func.coalesce(AIRequest.explanation_profile, "none").label("profile"),
        sa_func.count().label("count"),
    ).filter(*filters).group_by("profile").all()

    lang_rows = db.query(
        sa_func.coalesce(AIRequest.language, "unspecified").label("language"),
        sa_func.count().label("count"),
    ).filter(*filters).group_by("language").order_by(sa_func.count().desc()).limit(20).all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "by_mode": [
            {
                "mode": r.mode,
                "count": r.count,
                "users": r.users,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
            }
            for r in mode_rows
        ],
        "by_request_type": [
            {"request_type": r.type, "count": r.count, "users": r.users}
            for r in type_rows
        ],
        "by_profile": [
            {"profile": r.profile, "count": r.count}
            for r in profile_rows
        ],
        "by_language": [
            {"language": r.language, "count": r.count}
            for r in lang_rows
        ],
    }


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@router.get("/users")
def get_users_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    """Per-user usage summary with pagination."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    # Total count for pagination
    total_count = db.query(
        sa_func.count(sa_func.distinct(AIRequest.user_id))
    ).filter(*filters).scalar() or 0

    rows = db.query(
        AIRequest.user_id,
        sa_func.count().label("total_requests"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("total_cost"),
        sa_func.max(AIRequest.created_at).label("last_active"),
    ).filter(*filters).group_by(AIRequest.user_id).order_by(
        sa_func.count().desc()
    ).offset(offset).limit(limit).all()

    # Fetch user names
    user_ids = [r.user_id for r in rows]
    users_by_id = {}
    if user_ids:
        user_records = db.query(User.id, User.name, User.email).filter(
            User.id.in_(user_ids)
        ).all()
        users_by_id = {str(u.id): (u.name, u.email) for u in user_records}

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "total_count": total_count,
        "limit": limit,
        "offset": offset,
        "users": [
            {
                "user_id": r.user_id,
                "name": users_by_id.get(r.user_id, (None, None))[0],
                "email": users_by_id.get(r.user_id, (None, None))[1],
                "total_requests": r.total_requests,
                "successful_requests": r.successful,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
                "total_cost_usd": round(r.total_cost, 4) if r.total_cost else 0,
                "last_active": str(r.last_active) if r.last_active else None,
            }
            for r in rows
        ],
    }


# ---------------------------------------------------------------------------
# User Detail — helpers
# ---------------------------------------------------------------------------


def _v2_user_improve_breakdown(
    db: Session, user_id: str, start_date: date, end_date: date,
) -> dict | None:
    """Per-user Improve Code outcome analytics from analytics_events."""
    improve_types = ["improve_copy", "improve_replace", "improve_dismiss", "improve_no_change"]
    date_filters = _date_filter(AnalyticsEvent, start_date, end_date)

    counts = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(
            *date_filters,
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type.in_(improve_types),
        )
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    copy_count = counts.get("improve_copy", 0)
    replace_count = counts.get("improve_replace", 0)
    dismiss_count = counts.get("improve_dismiss", 0)
    no_change_count = counts.get("improve_no_change", 0)
    total = copy_count + replace_count + dismiss_count + no_change_count

    if total == 0:
        return None

    # Improve AI requests for this user
    req_date_filters = _date_filter(AIRequest, start_date, end_date)
    improve_requests = (
        db.query(sa_func.count(AIRequest.id))
        .filter(*req_date_filters, AIRequest.user_id == user_id, AIRequest.request_type == "improve")
        .scalar()
    ) or 0

    improvable = total - no_change_count
    accepted = copy_count + replace_count

    return {
        "improve_requests": improve_requests,
        "copy_count": copy_count,
        "replace_count": replace_count,
        "dismiss_count": dismiss_count,
        "no_change_count": no_change_count,
        "total_outcomes": total,
        "acceptance_rate": round(accepted / improvable * 100, 1) if improvable > 0 else None,
        "no_change_rate": round(no_change_count / total * 100, 1) if total > 0 else None,
    }


def _v2_user_profile_intelligence(user) -> dict | None:
    """Extract Profile Intelligence snapshot from user model."""
    if not user.profile_snapshot:
        return None
    return {
        "available": True,
        "schema_version": user.profile_schema_version,
        "synced_at": str(user.profile_synced_at) if user.profile_synced_at else None,
        "data": user.profile_snapshot,
    }


# ---------------------------------------------------------------------------
# User Detail
# ---------------------------------------------------------------------------

@router.get("/users/{user_id}")
def get_user_detail(
    user_id: str,
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    recent_limit: int = Query(20, ge=1, le=100),
    db: Session = Depends(get_db),
):
    """Detailed analytics for a single user."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = (*_date_filter(AIRequest, start_date, end_date), AIRequest.user_id == user_id)

    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    total = db.query(sa_func.count(AIRequest.id)).filter(*filters).scalar() or 0
    successful = db.query(sa_func.count(AIRequest.id)).filter(
        *filters, AIRequest.success.is_(True)
    ).scalar() or 0

    _eff_mode = case(
        (AIRequest.origin_mode.isnot(None), AIRequest.origin_mode),
        else_=sa_func.coalesce(AIRequest.request_type, "other"),
    ).label("mode")
    mode_rows = db.query(
        _eff_mode,
        sa_func.count().label("count"),
    ).filter(*filters).group_by("mode").all()

    type_rows = db.query(
        AIRequest.request_type.label("type"),
        sa_func.count().label("count"),
    ).filter(*filters).group_by("type").all()

    daily = db.query(
        cast(AIRequest.created_at, Date).label("day"),
        sa_func.count().label("requests"),
    ).filter(*filters).group_by("day").order_by("day").all()

    recent = db.query(AIRequest).filter(
        AIRequest.user_id == user_id
    ).order_by(AIRequest.created_at.desc()).limit(recent_limit).all()

    # ── Per-mode detailed analytics ──
    # Group by (origin_mode, request_type) to get every distinct AI mode.
    # Uses a single aggregation query for efficiency.
    mode_detail_rows = db.query(
        sa_func.coalesce(AIRequest.origin_mode, "_none_").label("origin_mode"),
        AIRequest.request_type.label("request_type"),
        sa_func.count().label("total"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.count().filter(AIRequest.success.is_(False)).label("failed"),
        sa_func.avg(AIRequest.latency_ms).filter(
            AIRequest.success.is_(True)
        ).label("avg_latency"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.max(AIRequest.created_at).label("last_used"),
    ).filter(*filters).group_by("origin_mode", "request_type").order_by(
        sa_func.count().desc()
    ).all()

    # Resolve dominant provider/model per (origin_mode, request_type).
    # Uses a separate query to avoid complicating the main aggregation.
    provider_rows = db.query(
        sa_func.coalesce(AIRequest.origin_mode, "_none_").label("origin_mode"),
        AIRequest.request_type.label("request_type"),
        AIRequest.ai_provider.label("provider"),
        AIRequest.ai_model.label("model"),
        sa_func.count().label("cnt"),
    ).filter(*filters).group_by(
        "origin_mode", "request_type", "provider", "model"
    ).order_by(sa_func.count().desc()).all()

    # Build a map: (origin_mode, request_type) → (provider, model) of most frequent
    provider_map: dict[tuple[str, str], tuple[str, str]] = {}
    for pr in provider_rows:
        key = (pr.origin_mode, pr.request_type)
        if key not in provider_map:
            provider_map[key] = (pr.provider, pr.model)

    # p95 latency per mode — use percentile_cont grouped by mode.
    # PostgreSQL supports this via within_group.
    p95_rows = db.query(
        sa_func.coalesce(AIRequest.origin_mode, "_none_").label("origin_mode"),
        AIRequest.request_type.label("request_type"),
        sa_func.percentile_cont(0.95).within_group(
            AIRequest.latency_ms
        ).label("p95"),
    ).filter(*filters, AIRequest.success.is_(True)).group_by(
        "origin_mode", "request_type"
    ).all()

    p95_map: dict[tuple[str, str], float] = {
        (r.origin_mode, r.request_type): r.p95
        for r in p95_rows
    }

    # Human-readable display name for each (origin_mode, request_type) combo
    _DISPLAY_NAMES = {
        ("selection", "explain"): "Selection Explain",
        ("screenshot", "explain"): "Screenshot Explain",
        ("session", "explain"): "Session Explain",
        ("selection", "followup"): "Selection Follow-Up",
        ("screenshot", "followup"): "Screenshot Follow-Up",
        ("session", "followup"): "Session Follow-Up",
        ("selection", "improve"): "Selection Improve",
        ("screenshot", "improve"): "Screenshot Improve",
        ("session", "improve"): "Session Improve",
        ("_none_", "vision"): "Vision",
        ("_none_", "enrichment"): "Semantic Enrichment",
        ("_none_", "enrichment_kgr"): "File Understanding (KGR)",
        ("_none_", "compression"): "VS Memory Compression",
    }

    mode_detail = []
    for r in mode_detail_rows:
        key = (r.origin_mode, r.request_type)
        prov, model = provider_map.get(key, (None, None))
        om = None if r.origin_mode == "_none_" else r.origin_mode
        display = _DISPLAY_NAMES.get(key, f"{om or ''} {r.request_type}".strip().title())
        mode_detail.append({
            "display_name": display,
            "origin_mode": om,
            "request_type": r.request_type,
            "total": r.total,
            "successful": r.successful,
            "failed": r.failed,
            "success_rate": round(r.successful / r.total * 100, 1) if r.total else 0,
            "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
            "p95_latency_ms": round(p95_map.get(key, 0)),
            "prompt_tokens": r.prompt_tokens or 0,
            "completion_tokens": r.completion_tokens or 0,
            "total_tokens": r.total_tokens or 0,
            "estimated_cost_usd": round(r.cost, 4) if r.cost else 0,
            "provider": prov,
            "model": model,
            "last_used": str(r.last_used) if r.last_used else None,
        })

    # ── Per-user History analytics (from analytics_events) ──
    history_event_types = ["history_opened", "history_followup", "history_cleared"]
    hist_date_filters = _date_filter(AnalyticsEvent, start_date, end_date)

    hist_counts = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(
            *hist_date_filters,
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type.in_(history_event_types),
        )
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    hist_opens = hist_counts.get("history_opened", 0)
    hist_followups = hist_counts.get("history_followup", 0)
    hist_clears = hist_counts.get("history_cleared", 0)

    hist_depth_rows = (
        db.query(AnalyticsEvent.metadata_["followup_depth"])
        .filter(
            *hist_date_filters,
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["followup_depth"].isnot(None),
        )
        .all()
    )
    hist_depths = [int(r[0]) for r in hist_depth_rows if r[0] is not None]
    hist_avg_depth = round(sum(hist_depths) / len(hist_depths), 1) if hist_depths else None
    hist_max_depth = max(hist_depths) if hist_depths else None

    hist_source_rows = (
        db.query(
            AnalyticsEvent.metadata_["selection_source"].as_string(),
            sa_func.count(AnalyticsEvent.id),
        )
        .filter(
            *hist_date_filters,
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["selection_source"].isnot(None),
        )
        .group_by(AnalyticsEvent.metadata_["selection_source"].as_string())
        .all()
    )
    hist_selection_source = {src: cnt for src, cnt in hist_source_rows} if hist_source_rows else {}

    hist_activity = (
        db.query(
            sa_func.min(AnalyticsEvent.created_at),
            sa_func.max(AnalyticsEvent.created_at),
        )
        .filter(
            *hist_date_filters,
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type.in_(history_event_types),
        )
        .one()
    )

    history_breakdown = {
        "history_opens": hist_opens,
        "history_followups": hist_followups,
        "history_followup_rate": round(hist_followups / hist_opens * 100, 1) if hist_opens > 0 else None,
        "history_clears": hist_clears,
        "avg_depth": hist_avg_depth,
        "max_depth": hist_max_depth,
        "selection_source": hist_selection_source,
        "first_activity": str(hist_activity[0]) if hist_activity[0] else None,
        "last_activity": str(hist_activity[1]) if hist_activity[1] else None,
    } if (hist_opens + hist_followups + hist_clears) > 0 else None

    # Compute top-level token/cost totals from mode_detail (avoids extra query)
    _total_prompt = sum(m["prompt_tokens"] for m in mode_detail)
    _total_completion = sum(m["completion_tokens"] for m in mode_detail)
    _total_tokens = sum(m["total_tokens"] for m in mode_detail)
    _total_cost = sum(m["estimated_cost_usd"] for m in mode_detail)
    _last_active_row = db.query(
        sa_func.max(AIRequest.created_at)
    ).filter(*filters).scalar()

    return {
        "user": {
            "id": str(user.id),
            "name": user.name,
            "email": user.email,
            "status": user.status.value if hasattr(user.status, "value") else str(user.status),
        },
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "total_requests": total,
        "successful_requests": successful,
        "success_rate": round(successful / total * 100, 1) if total else 0,
        "total_prompt_tokens": _total_prompt,
        "total_completion_tokens": _total_completion,
        "total_tokens": _total_tokens,
        "total_cost_usd": round(_total_cost, 4),
        "last_active": str(_last_active_row) if _last_active_row else None,
        "by_mode": [{"mode": r.mode, "count": r.count} for r in mode_rows],
        "by_request_type": [{"request_type": r.type, "count": r.count} for r in type_rows],
        "mode_detail": mode_detail,
        "history_breakdown": history_breakdown,
        "improve_breakdown": _v2_user_improve_breakdown(db, user_id, start_date, end_date),
        "profile_intelligence": _v2_user_profile_intelligence(user),
        "daily_trend": [
            {"date": str(r.day), "requests": r.requests}
            for r in daily
        ],
        "recent_requests": [_format_request(r) for r in recent],
    }


# ---------------------------------------------------------------------------
# AI Platform
# ---------------------------------------------------------------------------

@router.get("/ai-platform")
def get_ai_platform_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """AI provider and model analytics: usage, cost, latency by provider/model."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    provider_rows = db.query(
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("count"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("total_cost"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
    ).filter(*filters).group_by("provider").all()

    model_rows = db.query(
        AIRequest.ai_model.label("model"),
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("count"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("total_cost"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
    ).filter(*filters).group_by("model", "provider").all()

    error_rows = db.query(
        sa_func.coalesce(AIRequest.error_type, "unknown").label("error_type"),
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("count"),
    ).filter(*filters, AIRequest.success.is_(False)).group_by(
        "error_type", "provider"
    ).order_by(sa_func.count().desc()).limit(20).all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "by_provider": [
            {
                "provider": r.provider,
                "count": r.count,
                "successful": r.successful,
                "success_rate": round(r.successful / r.count * 100, 1) if r.count else 0,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
                "total_cost_usd": round(r.total_cost, 4) if r.total_cost else 0,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
            }
            for r in provider_rows
        ],
        "by_model": [
            {
                "model": r.model,
                "provider": r.provider,
                "count": r.count,
                "successful": r.successful,
                "success_rate": round(r.successful / r.count * 100, 1) if r.count else 0,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
                "total_cost_usd": round(r.total_cost, 4) if r.total_cost else 0,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
            }
            for r in model_rows
        ],
        "errors": [
            {"error_type": r.error_type, "provider": r.provider, "count": r.count}
            for r in error_rows
        ],
    }


# ---------------------------------------------------------------------------
# Quality
# ---------------------------------------------------------------------------

@router.get("/quality")
def get_quality_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Quality metrics: success rates, latency distributions, error rates."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    total = db.query(sa_func.count(AIRequest.id)).filter(*filters).scalar() or 0
    successful = db.query(sa_func.count(AIRequest.id)).filter(
        *filters, AIRequest.success.is_(True)
    ).scalar() or 0

    success_filters = (*filters, AIRequest.success.is_(True))
    latency = db.query(
        sa_func.avg(AIRequest.latency_ms).label("avg"),
        sa_func.percentile_cont(0.5).within_group(AIRequest.latency_ms).label("p50"),
        sa_func.percentile_cont(0.95).within_group(AIRequest.latency_ms).label("p95"),
        sa_func.percentile_cont(0.99).within_group(AIRequest.latency_ms).label("p99"),
        sa_func.min(AIRequest.latency_ms).label("min"),
        sa_func.max(AIRequest.latency_ms).label("max"),
    ).filter(*success_filters).first()

    daily = db.query(
        cast(AIRequest.created_at, Date).label("day"),
        sa_func.count().label("total"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*filters).group_by("day").order_by("day").all()

    error_rows = db.query(
        sa_func.coalesce(AIRequest.error_type, "unknown").label("error_type"),
        sa_func.count().label("count"),
    ).filter(*filters, AIRequest.success.is_(False)).group_by("error_type").order_by(
        sa_func.count().desc()
    ).all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "reliability": {
            "total_requests": total,
            "successful": successful,
            "failed": total - successful,
            "success_rate": round(successful / total * 100, 2) if total else 0,
        },
        "latency": {
            "avg_ms": round(latency.avg) if latency and latency.avg else 0,
            "p50_ms": round(latency.p50) if latency and latency.p50 else 0,
            "p95_ms": round(latency.p95) if latency and latency.p95 else 0,
            "p99_ms": round(latency.p99) if latency and latency.p99 else 0,
            "min_ms": latency.min if latency else 0,
            "max_ms": latency.max if latency else 0,
        },
        "daily_trend": [
            {
                "date": str(r.day),
                "total": r.total,
                "successful": r.successful,
                "success_rate": round(r.successful / r.total * 100, 1) if r.total else 0,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
            }
            for r in daily
        ],
        "errors": [
            {"error_type": r.error_type, "count": r.count}
            for r in error_rows
        ],
    }


# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------

@router.get("/cost")
def get_cost_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Cost analytics: total spend, by provider, by model, daily trend."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    total_cost = db.query(
        sa_func.sum(AIRequest.estimated_cost_usd)
    ).filter(*filters).scalar()

    provider_rows = db.query(
        AIRequest.ai_provider.label("provider"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
    ).filter(*filters).group_by("provider").order_by(
        sa_func.sum(AIRequest.estimated_cost_usd).desc()
    ).all()

    model_rows = db.query(
        AIRequest.ai_model.label("model"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
    ).filter(*filters).group_by("model").order_by(
        sa_func.sum(AIRequest.estimated_cost_usd).desc()
    ).all()

    type_rows = db.query(
        AIRequest.request_type.label("type"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.count().label("requests"),
    ).filter(*filters).group_by("type").order_by(
        sa_func.sum(AIRequest.estimated_cost_usd).desc()
    ).all()

    daily = db.query(
        cast(AIRequest.created_at, Date).label("day"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.count().label("requests"),
    ).filter(*filters).group_by("day").order_by("day").all()

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "total_cost_usd": round(total_cost, 4) if total_cost else 0,
        "by_provider": [
            {
                "provider": r.provider,
                "cost_usd": round(r.cost, 4) if r.cost else 0,
                "requests": r.requests,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
            }
            for r in provider_rows
        ],
        "by_model": [
            {
                "model": r.model,
                "cost_usd": round(r.cost, 4) if r.cost else 0,
                "requests": r.requests,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
            }
            for r in model_rows
        ],
        "by_request_type": [
            {
                "request_type": r.type,
                "cost_usd": round(r.cost, 4) if r.cost else 0,
                "requests": r.requests,
            }
            for r in type_rows
        ],
        "daily_trend": [
            {
                "date": str(r.day),
                "cost_usd": round(r.cost, 4) if r.cost else 0,
                "requests": r.requests,
            }
            for r in daily
        ],
    }


# ---------------------------------------------------------------------------
# Settings / Config
# ---------------------------------------------------------------------------

@router.get("/settings")
def get_settings_info(db: Session = Depends(get_db)):
    """System configuration and health info for the settings page."""
    from app.config import settings as app_settings

    total_users = db.query(sa_func.count(User.id)).scalar() or 0
    active_users = db.query(sa_func.count(User.id)).filter(
        User.status == UserStatus.active
    ).scalar() or 0

    total_v2_requests = db.query(sa_func.count(AIRequest.id)).scalar() or 0
    total_legacy_requests = db.query(sa_func.count(RequestLog.id)).scalar() or 0
    total_summaries = db.query(sa_func.count(DailySummary.id)).scalar() or 0

    latest_summary_date = db.query(
        sa_func.max(DailySummary.summary_date)
    ).scalar()

    return {
        "_source": "v2",
        "users": {
            "total": total_users,
            "active": active_users,
        },
        "data": {
            "v2_ai_requests": total_v2_requests,
            "legacy_request_logs": total_legacy_requests,
            "daily_summaries": total_summaries,
            "latest_summary_date": str(latest_summary_date) if latest_summary_date else None,
        },
        "ai_config": {
            "adapter": app_settings.AI_ADAPTER,
            "anthropic_model": app_settings.ANTHROPIC_MODEL,
            "groq_model": app_settings.GROQ_MODEL,
            "vision_provider": app_settings.VISION_PROVIDER,
        },
    }


# ---------------------------------------------------------------------------
# Founder Timeline
# ---------------------------------------------------------------------------

@router.get("/timeline")
def get_founder_timeline(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """Chronological feed of significant events for the founder.

    Synthesises milestones from raw data: user activations, daily
    summaries, and recent errors.
    """
    start_date, end_date = _parse_date_range(days, start, end)
    timeline: list[dict] = []

    # Per-source limits to avoid loading unbounded data in memory
    per_source_limit = max(limit, 20)

    # --- New user activations ---
    new_users = db.query(
        User.id, User.name, User.email, User.activated_at,
    ).filter(
        User.activated_at.isnot(None),
        cast(User.activated_at, Date) >= start_date,
        cast(User.activated_at, Date) <= end_date,
    ).order_by(User.activated_at.desc()).limit(per_source_limit).all()

    for u in new_users:
        timeline.append({
            "timestamp": str(u.activated_at),
            "type": "user_activation",
            "title": f"New user: {u.name or u.email or 'Unknown'}",
            "detail": {"user_id": str(u.id)},
        })

    # --- Daily usage summaries ---
    daily_rows = db.query(DailySummary).filter(
        DailySummary.dimension == "overall",
        DailySummary.summary_date >= start_date,
        DailySummary.summary_date <= end_date,
    ).order_by(DailySummary.summary_date.desc()).limit(per_source_limit).all()

    for ds in daily_rows:
        if ds.total_requests > 0:
            timeline.append({
                "timestamp": str(datetime.combine(ds.summary_date, datetime.min.time())),
                "type": "daily_summary",
                "title": f"{ds.total_requests} requests on {ds.summary_date}",
                "detail": {
                    "requests": ds.total_requests,
                    "successful": ds.successful_requests,
                    "failed": ds.failed_requests,
                    "unique_users": ds.unique_users,
                    "cost_usd": round(ds.total_estimated_cost_usd, 4) if ds.total_estimated_cost_usd else 0,
                },
            })

    # --- Recent errors ---
    recent_errors = db.query(
        AIRequest.created_at,
        AIRequest.error_type,
        AIRequest.ai_provider,
        AIRequest.ai_model,
        AIRequest.origin_mode,
        AIRequest.request_type,
        AIRequest.user_id,
    ).filter(
        *_date_filter(AIRequest, start_date, end_date),
        AIRequest.success.is_(False),
    ).order_by(AIRequest.created_at.desc()).limit(per_source_limit).all()

    for e in recent_errors:
        timeline.append({
            "timestamp": str(e.created_at),
            "type": "error",
            "title": f"Error: {e.error_type or 'unknown'} ({e.ai_provider})",
            "detail": {
                "error_type": e.error_type,
                "provider": e.ai_provider,
                "model": e.ai_model,
                "mode": e.origin_mode,
                "request_type": e.request_type,
            },
        })

    # Sort by timestamp descending, truncate to requested limit
    timeline.sort(key=lambda e: e["timestamp"], reverse=True)
    timeline = timeline[:limit]

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "events": timeline,
    }


# ---------------------------------------------------------------------------
# Live Monitor
# ---------------------------------------------------------------------------

@router.get("/live")
def get_live_monitor(
    minutes: int = Query(60, ge=1, le=1440),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """Recent requests for live monitoring. Shows last N minutes of activity."""
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=minutes)

    recent = db.query(AIRequest).filter(
        AIRequest.created_at >= cutoff,
    ).order_by(AIRequest.created_at.desc()).limit(limit).all()

    total = db.query(sa_func.count(AIRequest.id)).filter(
        AIRequest.created_at >= cutoff,
    ).scalar() or 0
    successful = db.query(sa_func.count(AIRequest.id)).filter(
        AIRequest.created_at >= cutoff,
        AIRequest.success.is_(True),
    ).scalar() or 0
    avg_latency = db.query(sa_func.avg(AIRequest.latency_ms)).filter(
        AIRequest.created_at >= cutoff,
        AIRequest.success.is_(True),
    ).scalar()

    return {
        "period": {"window_minutes": minutes},
        "_source": "v2",
        "stats": {
            "total_requests": total,
            "successful": successful,
            "failed": total - successful,
            "success_rate": round(successful / total * 100, 1) if total else 0,
            "avg_latency_ms": round(avg_latency) if avg_latency else 0,
        },
        "requests": [_format_request(r) for r in recent],
    }


# ---------------------------------------------------------------------------
# Global Search
# ---------------------------------------------------------------------------

@router.get("/search")
def global_search(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=100),
    db: Session = Depends(get_db),
):
    """Search across users, AI requests, and events.

    Matches against user names/emails, AI model/provider names,
    error types, event types, and mode names.
    """
    query = q.strip().lower()
    results: list[dict] = []
    per_type_limit = limit  # each type gets its own DB limit

    # --- Search users ---
    user_matches = db.query(User).filter(
        sa_func.lower(sa_func.coalesce(User.name, "")).contains(query)
        | sa_func.lower(sa_func.coalesce(User.email, "")).contains(query)
    ).limit(per_type_limit).all()

    for u in user_matches:
        results.append({
            "type": "user",
            "id": str(u.id),
            "title": u.name or u.email or "Unknown",
            "subtitle": u.email,
            "detail": {
                "status": u.status.value if hasattr(u.status, "value") else str(u.status),
            },
        })

    # --- Search AI requests by model, provider, error_type, mode ---
    request_filters = (
        sa_func.lower(AIRequest.ai_model).contains(query)
        | sa_func.lower(AIRequest.ai_provider).contains(query)
        | sa_func.lower(sa_func.coalesce(AIRequest.error_type, "")).contains(query)
        | sa_func.lower(sa_func.coalesce(AIRequest.origin_mode, "")).contains(query)
        | sa_func.lower(AIRequest.request_type).contains(query)
    )
    request_matches = db.query(AIRequest).filter(
        request_filters
    ).order_by(AIRequest.created_at.desc()).limit(per_type_limit).all()

    for r in request_matches:
        results.append({
            "type": "ai_request",
            "id": r.id,
            "title": f"{r.request_type} via {r.ai_model}",
            "subtitle": f"{'OK' if r.success else 'FAIL'} · {r.latency_ms}ms · {r.origin_mode or 'unknown'}",
            "detail": {
                "created_at": str(r.created_at),
                "user_id": r.user_id,
                "provider": r.ai_provider,
                "cost_usd": r.estimated_cost_usd,
            },
        })

    # --- Search events by type ---
    event_matches = db.query(Event).filter(
        sa_func.lower(Event.event_type).contains(query)
        | sa_func.lower(sa_func.coalesce(Event.origin_mode, "")).contains(query)
    ).order_by(Event.created_at.desc()).limit(per_type_limit).all()

    for e in event_matches:
        results.append({
            "type": "event",
            "id": e.id,
            "title": e.event_type,
            "subtitle": f"{e.origin_mode or 'unknown'} · {e.created_at}",
            "detail": {
                "user_id": e.user_id,
                "request_type": e.request_type,
            },
        })

    # Truncate to limit; signal if more exist
    truncated = results[:limit]
    return {
        "query": q,
        "_source": "v2",
        "total_results": len(truncated),
        "has_more": len(results) > limit,
        "results": truncated,
    }


# ---------------------------------------------------------------------------
# Token Breakdown
# ---------------------------------------------------------------------------

@router.get("/token-breakdown")
def get_token_breakdown(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Detailed token consumption grouped by mode, request type, and profile.

    Provides the granular token analytics needed for AI resource monitoring:
    per-mode token usage, Vision-specific breakdown, and DSA-specific breakdown.
    """
    start_date, end_date = _parse_date_range(days, start, end)
    filters = _date_filter(AIRequest, start_date, end_date)

    def _agg_group(group_col, extra_filters=()):
        """Aggregate token stats grouped by a column."""
        all_filters = (*filters, *extra_filters)
        rows = db.query(
            group_col.label("group_key"),
            sa_func.count().label("requests"),
            sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
            sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
            sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
            sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
            sa_func.avg(AIRequest.prompt_tokens).label("avg_prompt"),
            sa_func.avg(AIRequest.completion_tokens).label("avg_completion"),
            sa_func.avg(AIRequest.total_tokens).label("avg_total"),
            sa_func.sum(AIRequest.estimated_cost_usd).label("total_cost"),
            sa_func.avg(AIRequest.estimated_cost_usd).label("avg_cost"),
            sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
        ).filter(*all_filters).group_by("group_key").all()

        return [
            {
                "key": r.group_key or "unknown",
                "requests": r.requests,
                "successful": r.successful,
                "success_rate": round(r.successful / r.requests * 100, 1) if r.requests else 0,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
                "total_tokens": r.total_tokens or 0,
                "avg_prompt_tokens": round(r.avg_prompt) if r.avg_prompt else 0,
                "avg_completion_tokens": round(r.avg_completion) if r.avg_completion else 0,
                "avg_total_tokens": round(r.avg_total) if r.avg_total else 0,
                "total_cost_usd": round(r.total_cost, 4) if r.total_cost else 0,
                "avg_cost_usd": round(r.avg_cost, 6) if r.avg_cost else 0,
                "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
            }
            for r in rows
        ]

    # --- By origin mode ---
    by_mode = _agg_group(case(
        (AIRequest.origin_mode.isnot(None), AIRequest.origin_mode),
        else_=sa_func.coalesce(AIRequest.request_type, "other"),
    ))

    # --- By request type ---
    by_type = _agg_group(AIRequest.request_type)

    # --- By explanation profile ---
    by_profile = _agg_group(
        sa_func.coalesce(AIRequest.explanation_profile, "none"),
    )

    # --- Vision-specific breakdown (request_type = 'vision') ---
    vision_filters = (*filters, AIRequest.request_type == "vision")

    vision_provider_rows = db.query(
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*vision_filters).group_by("provider").all()

    vision_model_rows = db.query(
        AIRequest.ai_model.label("model"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*vision_filters).group_by("model").all()

    # Vision totals
    vision_totals = db.query(
        sa_func.count().label("requests"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.avg(AIRequest.prompt_tokens).label("avg_prompt"),
        sa_func.avg(AIRequest.completion_tokens).label("avg_completion"),
        sa_func.avg(AIRequest.total_tokens).label("avg_total"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*vision_filters).first()

    # --- DSA-specific breakdown (explanation_profile = 'dsa') ---
    dsa_filters = (*filters, AIRequest.explanation_profile == "dsa")

    dsa_provider_rows = db.query(
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*dsa_filters).group_by("provider").all()

    dsa_model_rows = db.query(
        AIRequest.ai_model.label("model"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*dsa_filters).group_by("model").all()

    dsa_totals = db.query(
        sa_func.count().label("requests"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.avg(AIRequest.prompt_tokens).label("avg_prompt"),
        sa_func.avg(AIRequest.completion_tokens).label("avg_completion"),
        sa_func.avg(AIRequest.total_tokens).label("avg_total"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*dsa_filters).first()

    def _format_breakdown_rows(rows):
        return [
            {
                "key": r.provider if hasattr(r, "provider") else r.model,
                "requests": r.requests,
                "prompt_tokens": r.prompt_tokens or 0,
                "completion_tokens": r.completion_tokens or 0,
                "total_tokens": r.total_tokens or 0,
                "cost_usd": round(r.cost, 4) if r.cost else 0,
            }
            for r in rows
        ]

    def _format_totals(t):
        if not t or not t.requests:
            return None
        return {
            "requests": t.requests,
            "successful": t.successful,
            "success_rate": round(t.successful / t.requests * 100, 1) if t.requests else 0,
            "prompt_tokens": t.prompt_tokens or 0,
            "completion_tokens": t.completion_tokens or 0,
            "total_tokens": t.total_tokens or 0,
            "avg_prompt_tokens": round(t.avg_prompt) if t.avg_prompt else 0,
            "avg_completion_tokens": round(t.avg_completion) if t.avg_completion else 0,
            "avg_total_tokens": round(t.avg_total) if t.avg_total else 0,
            "total_cost_usd": round(t.cost, 4) if t.cost else 0,
            "avg_latency_ms": round(t.avg_latency) if t.avg_latency else 0,
        }

    # --- Compound feature breakdown ---
    # Derives a "feature" label from origin_mode + request_type so the
    # dashboard can show Selection, Session, Session Follow-up, etc.
    feature_expr = case(
        (AIRequest.request_type == "vision", "vision"),
        (and_(AIRequest.origin_mode == "session",
              AIRequest.request_type == "followup"), "session_followup"),
        (and_(AIRequest.origin_mode == "session",
              AIRequest.request_type == "improve"), "session_improve"),
        (and_(AIRequest.origin_mode == "selection",
              AIRequest.request_type == "followup"), "selection_followup"),
        (and_(AIRequest.origin_mode == "screenshot",
              AIRequest.request_type == "followup"), "screenshot_followup"),
        (AIRequest.origin_mode == "selection", "selection"),
        (AIRequest.origin_mode == "session", "session"),
        (AIRequest.origin_mode == "screenshot", "screenshot"),
        (AIRequest.request_type == "enrichment", "enrichment"),
        (AIRequest.request_type == "enrichment_kgr", "enrichment_kgr"),
        (AIRequest.request_type == "compression", "compression"),
        else_="other",
    )

    by_feature = _agg_group(feature_expr)

    # --- Daily token trends ---
    daily_tokens = db.query(
        cast(AIRequest.created_at, Date).label("day"),
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*filters).group_by("day").order_by("day").all()

    daily_trend = [
        {
            "date": str(r.day),
            "requests": r.requests,
            "prompt_tokens": r.prompt_tokens or 0,
            "completion_tokens": r.completion_tokens or 0,
            "total_tokens": r.total_tokens or 0,
            "cost_usd": round(r.cost, 4) if r.cost else 0,
        }
        for r in daily_tokens
    ]

    # --- Top consumers (users) ---
    top_user_rows = db.query(
        AIRequest.user_id,
        sa_func.count().label("requests"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
    ).filter(*filters).group_by(AIRequest.user_id).order_by(
        sa_func.sum(AIRequest.total_tokens).desc()
    ).limit(15).all()

    top_user_ids = [r.user_id for r in top_user_rows]
    users_map = {}
    if top_user_ids:
        user_records = db.query(User.id, User.name, User.email).filter(
            User.id.in_(top_user_ids)
        ).all()
        users_map = {str(u.id): (u.name, u.email) for u in user_records}

    top_users = [
        {
            "user_id": r.user_id,
            "name": users_map.get(r.user_id, (None, None))[0],
            "email": users_map.get(r.user_id, (None, None))[1],
            "requests": r.requests,
            "prompt_tokens": r.prompt_tokens or 0,
            "completion_tokens": r.completion_tokens or 0,
            "total_tokens": r.total_tokens or 0,
            "cost_usd": round(r.cost, 4) if r.cost else 0,
        }
        for r in top_user_rows
    ]

    # --- Token distribution (percentiles) ---
    success_filters = (*filters, AIRequest.success.is_(True))

    token_dist = db.query(
        sa_func.percentile_cont(0.5).within_group(
            AIRequest.prompt_tokens).label("prompt_p50"),
        sa_func.percentile_cont(0.95).within_group(
            AIRequest.prompt_tokens).label("prompt_p95"),
        sa_func.percentile_cont(0.99).within_group(
            AIRequest.prompt_tokens).label("prompt_p99"),
        sa_func.max(AIRequest.prompt_tokens).label("prompt_max"),
        sa_func.percentile_cont(0.5).within_group(
            AIRequest.completion_tokens).label("completion_p50"),
        sa_func.percentile_cont(0.95).within_group(
            AIRequest.completion_tokens).label("completion_p95"),
        sa_func.percentile_cont(0.99).within_group(
            AIRequest.completion_tokens).label("completion_p99"),
        sa_func.max(AIRequest.completion_tokens).label("completion_max"),
    ).filter(*success_filters).first()

    token_distribution = None
    if token_dist and token_dist.prompt_p50 is not None:
        token_distribution = {
            "prompt": {
                "p50": round(token_dist.prompt_p50),
                "p95": round(token_dist.prompt_p95),
                "p99": round(token_dist.prompt_p99),
                "max": token_dist.prompt_max or 0,
            },
            "completion": {
                "p50": round(token_dist.completion_p50),
                "p95": round(token_dist.completion_p95),
                "p99": round(token_dist.completion_p99),
                "max": token_dist.completion_max or 0,
            },
        }

    # --- Feature × Provider cross-tab ---
    fp_rows = db.query(
        feature_expr.label("feature"),
        AIRequest.ai_provider.label("provider"),
        sa_func.count().label("requests"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.avg(AIRequest.estimated_cost_usd).label("avg_cost"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*filters).group_by("feature", "provider").all()

    feature_by_provider = [
        {
            "feature": r.feature,
            "provider": r.provider,
            "requests": r.requests,
            "successful": r.successful,
            "success_rate": round(r.successful / r.requests * 100, 1) if r.requests else 0,
            "prompt_tokens": r.prompt_tokens or 0,
            "completion_tokens": r.completion_tokens or 0,
            "total_tokens": r.total_tokens or 0,
            "cost_usd": round(r.cost, 4) if r.cost else 0,
            "avg_cost_usd": round(r.avg_cost, 6) if r.avg_cost else 0,
            "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
        }
        for r in fp_rows
    ]

    # --- Feature × Model cross-tab ---
    fm_rows = db.query(
        feature_expr.label("feature"),
        AIRequest.ai_model.label("model"),
        sa_func.count().label("requests"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("successful"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("cost"),
        sa_func.avg(AIRequest.estimated_cost_usd).label("avg_cost"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
    ).filter(*filters).group_by("feature", "model").all()

    feature_by_model = [
        {
            "feature": r.feature,
            "model": r.model,
            "requests": r.requests,
            "successful": r.successful,
            "success_rate": round(r.successful / r.requests * 100, 1) if r.requests else 0,
            "prompt_tokens": r.prompt_tokens or 0,
            "completion_tokens": r.completion_tokens or 0,
            "total_tokens": r.total_tokens or 0,
            "cost_usd": round(r.cost, 4) if r.cost else 0,
            "avg_cost_usd": round(r.avg_cost, 6) if r.avg_cost else 0,
            "avg_latency_ms": round(r.avg_latency) if r.avg_latency else 0,
        }
        for r in fm_rows
    ]

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "_source": "v2",
        "by_mode": by_mode,
        "by_request_type": by_type,
        "by_profile": by_profile,
        "by_feature": by_feature,
        "daily_trend": daily_trend,
        "top_users": top_users,
        "token_distribution": token_distribution,
        "feature_by_provider": feature_by_provider,
        "feature_by_model": feature_by_model,
        "vision": {
            "totals": _format_totals(vision_totals),
            "by_provider": _format_breakdown_rows(vision_provider_rows),
            "by_model": _format_breakdown_rows(vision_model_rows),
        },
        "dsa": {
            "totals": _format_totals(dsa_totals),
            "by_provider": _format_breakdown_rows(dsa_provider_rows),
            "by_model": _format_breakdown_rows(dsa_model_rows),
        },
    }


# ---------------------------------------------------------------------------
# Aggregation Admin
# ---------------------------------------------------------------------------

@router.post("/aggregate")
def trigger_aggregation(
    target_date: date | None = Query(None),
    backfill: bool = Query(False),
    backfill_start: date | None = Query(None),
    backfill_end: date | None = Query(None),
):
    """Trigger daily aggregation or historical backfill.

    - ``target_date``: aggregate a specific date (defaults to yesterday).
    - ``backfill=true``: backfill from legacy ``request_logs``.
    - ``backfill_start``/``backfill_end``: date range for backfill.
    """
    from app.aggregation_service import aggregate_date, backfill_range

    if backfill:
        rows = backfill_range(start_date=backfill_start, end_date=backfill_end)
        return {
            "action": "backfill",
            "start": str(backfill_start) if backfill_start else "earliest",
            "end": str(backfill_end) if backfill_end else "yesterday",
            "rows_written": rows,
        }

    d = target_date or (date.today() - timedelta(days=1))
    rows = aggregate_date(d)
    return {
        "action": "aggregate",
        "date": str(d),
        "rows_written": rows,
    }


# ---------------------------------------------------------------------------
# Feedback Analytics
# ---------------------------------------------------------------------------

@router.get("/feedback")
def get_feedback_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Feedback analytics from analytics_events where event_type='feedback'."""
    start_date, end_date = _parse_date_range(days, start, end)
    filters = (
        AnalyticsEvent.event_type == "feedback",
        cast(AnalyticsEvent.created_at, Date) >= start_date,
        cast(AnalyticsEvent.created_at, Date) <= end_date,
    )

    total = db.query(sa_func.count(AnalyticsEvent.id)).filter(*filters).scalar() or 0

    # Count likes/dislikes from JSONB metadata.
    likes = db.query(sa_func.count(AnalyticsEvent.id)).filter(
        *filters,
        AnalyticsEvent.metadata_["liked"].as_boolean().is_(True),
    ).scalar() or 0
    dislikes = total - likes

    satisfaction = round(likes / total * 100, 1) if total else 0

    # By feature (explain / optimise).
    by_feature = db.query(
        AnalyticsEvent.metadata_["feature"].as_string().label("feature"),
        sa_func.count().label("total"),
        sa_func.count(
            case(
                (AnalyticsEvent.metadata_["liked"].as_boolean().is_(True), 1),
            )
        ).label("likes"),
    ).filter(*filters).group_by("feature").all()

    # By optimisation goal (for optimise feedback only).
    by_goal = db.query(
        AnalyticsEvent.metadata_["optimisation_goal"].as_string().label("goal"),
        sa_func.count().label("total"),
        sa_func.count(
            case(
                (AnalyticsEvent.metadata_["liked"].as_boolean().is_(True), 1),
            )
        ).label("likes"),
    ).filter(
        *filters,
        AnalyticsEvent.metadata_["feature"].as_string() == "optimise",
        AnalyticsEvent.metadata_["optimisation_goal"].as_string().isnot(None),
    ).group_by("goal").all()

    # By language.
    by_language = db.query(
        AnalyticsEvent.metadata_["language"].as_string().label("language"),
        sa_func.count().label("total"),
        sa_func.count(
            case(
                (AnalyticsEvent.metadata_["liked"].as_boolean().is_(True), 1),
            )
        ).label("likes"),
    ).filter(
        *filters,
        AnalyticsEvent.metadata_["language"].as_string().isnot(None),
    ).group_by("language").order_by(sa_func.count().desc()).limit(20).all()

    # By mode (provider proxy — mode correlates with provider routing).
    by_mode = db.query(
        sa_func.coalesce(AnalyticsEvent.mode, "unknown").label("mode"),
        sa_func.count().label("total"),
        sa_func.count(
            case(
                (AnalyticsEvent.metadata_["liked"].as_boolean().is_(True), 1),
            )
        ).label("likes"),
    ).filter(*filters).group_by("mode").all()

    # Daily trend.
    daily = db.query(
        cast(AnalyticsEvent.created_at, Date).label("day"),
        sa_func.count().label("total"),
        sa_func.count(
            case(
                (AnalyticsEvent.metadata_["liked"].as_boolean().is_(True), 1),
            )
        ).label("likes"),
    ).filter(*filters).group_by("day").order_by("day").all()

    def _row(r, name_field="name"):
        t = r.total or 0
        l = r.likes or 0
        return {
            name_field: getattr(r, name_field, None) or getattr(r, "feature", None) or getattr(r, "goal", None) or getattr(r, "language", None) or getattr(r, "mode", None),
            "total": t,
            "likes": l,
            "dislikes": t - l,
            "satisfaction": round(l / t * 100, 1) if t else 0,
        }

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "total_feedback": total,
        "likes": likes,
        "dislikes": dislikes,
        "satisfaction": satisfaction,
        "by_feature": [
            {
                "feature": r.feature or "unknown",
                "total": r.total or 0,
                "likes": r.likes or 0,
                "dislikes": (r.total or 0) - (r.likes or 0),
                "satisfaction": round((r.likes or 0) / (r.total or 1) * 100, 1) if r.total else 0,
            }
            for r in by_feature
        ],
        "by_optimisation_goal": [
            {
                "goal": r.goal or "unknown",
                "total": r.total or 0,
                "likes": r.likes or 0,
                "dislikes": (r.total or 0) - (r.likes or 0),
                "satisfaction": round((r.likes or 0) / (r.total or 1) * 100, 1) if r.total else 0,
            }
            for r in by_goal
        ],
        "by_language": [
            {
                "language": r.language or "unknown",
                "total": r.total or 0,
                "likes": r.likes or 0,
                "dislikes": (r.total or 0) - (r.likes or 0),
                "satisfaction": round((r.likes or 0) / (r.total or 1) * 100, 1) if r.total else 0,
            }
            for r in by_language
        ],
        "by_mode": [
            {
                "mode": r.mode or "unknown",
                "total": r.total or 0,
                "likes": r.likes or 0,
                "dislikes": (r.total or 0) - (r.likes or 0),
                "satisfaction": round((r.likes or 0) / (r.total or 1) * 100, 1) if r.total else 0,
            }
            for r in by_mode
        ],
        "daily_trend": [
            {
                "date": str(r.day),
                "total": r.total or 0,
                "likes": r.likes or 0,
                "dislikes": (r.total or 0) - (r.likes or 0),
            }
            for r in daily
        ],
    }


# ---------------------------------------------------------------------------
# History analytics
# ---------------------------------------------------------------------------


@router.get("/history")
def get_history_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """History feature analytics: opens, follow-ups, clears, depth, selection source."""
    start_date, end_date = _parse_date_range(days, start, end)
    date_filters = _date_filter(AnalyticsEvent, start_date, end_date)

    history_types = ["history_opened", "history_followup", "history_cleared"]

    # ── Aggregate counts ──
    counts = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(*date_filters, AnalyticsEvent.event_type.in_(history_types))
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    history_opens = counts.get("history_opened", 0)
    history_followups = counts.get("history_followup", 0)
    history_clears = counts.get("history_cleared", 0)

    # ── Unique users ──
    history_users = (
        db.query(sa_func.count(sa_func.distinct(AnalyticsEvent.user_id)))
        .filter(*date_filters, AnalyticsEvent.event_type.in_(history_types))
        .scalar()
    ) or 0

    # ── Active users for adoption rate ──
    # Count unique users who made any AI request in the period.
    active_users = (
        db.query(sa_func.count(sa_func.distinct(RequestLog.user_id)))
        .filter(*_date_filter(RequestLog, start_date, end_date))
        .scalar()
    ) or 0
    adoption = round(history_users / active_users * 100, 1) if active_users > 0 else None

    # ── Follow-up rate ──
    followup_rate = round(history_followups / history_opens * 100, 1) if history_opens > 0 else None

    # ── Average follow-ups per open ──
    avg_followups_per_open = round(history_followups / history_opens, 1) if history_opens > 0 else None

    # ── Depth metrics ──
    depth_rows = (
        db.query(AnalyticsEvent.metadata_["followup_depth"])
        .filter(
            *date_filters,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["followup_depth"].isnot(None),
        )
        .all()
    )
    depth_values = [int(r[0]) for r in depth_rows if r[0] is not None]
    avg_depth = round(sum(depth_values) / len(depth_values), 1) if depth_values else None
    depth_distribution = {}
    for d in depth_values:
        depth_distribution[str(d)] = depth_distribution.get(str(d), 0) + 1

    # ── Selection source distribution ──
    source_rows = (
        db.query(
            AnalyticsEvent.metadata_["selection_source"].as_string(),
            sa_func.count(AnalyticsEvent.id),
        )
        .filter(
            *date_filters,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["selection_source"].isnot(None),
        )
        .group_by(AnalyticsEvent.metadata_["selection_source"].as_string())
        .all()
    )
    selection_source = {src: cnt for src, cnt in source_rows} if source_rows else {}

    # ── Daily trend ──
    daily = (
        db.query(
            cast(AnalyticsEvent.created_at, Date).label("day"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_opened").label("opens"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_followup").label("followups"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_cleared").label("clears"),
            sa_func.count(sa_func.distinct(AnalyticsEvent.user_id)).label("users"),
        )
        .filter(*date_filters, AnalyticsEvent.event_type.in_(history_types))
        .group_by("day")
        .order_by("day")
        .all()
    )

    # ── Per-user breakdown (top users by History activity) ──
    top_users = (
        db.query(
            AnalyticsEvent.user_id,
            sa_func.count().label("total"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_opened").label("opens"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_followup").label("followups"),
            sa_func.count().filter(AnalyticsEvent.event_type == "history_cleared").label("clears"),
        )
        .filter(*date_filters, AnalyticsEvent.event_type.in_(history_types))
        .group_by(AnalyticsEvent.user_id)
        .order_by(sa_func.count().desc())
        .limit(20)
        .all()
    )

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "history_users": history_users,
        "active_users": active_users,
        "adoption": adoption,
        "history_opens": history_opens,
        "history_followups": history_followups,
        "history_clears": history_clears,
        "followup_rate": followup_rate,
        "avg_followups_per_open": avg_followups_per_open,
        "avg_depth": avg_depth,
        "depth_distribution": depth_distribution,
        "selection_source": selection_source,
        "daily_trend": [
            {
                "date": str(r.day),
                "opens": r.opens or 0,
                "followups": r.followups or 0,
                "clears": r.clears or 0,
                "users": r.users or 0,
            }
            for r in daily
        ],
        "top_users": [
            {
                "user_id": str(r.user_id),
                "total": r.total,
                "opens": r.opens or 0,
                "followups": r.followups or 0,
                "clears": r.clears or 0,
            }
            for r in top_users
        ],
    }


# ---------------------------------------------------------------------------
# Improve Code analytics
# ---------------------------------------------------------------------------


@router.get("/improve")
def get_improve_analytics(
    days: int | None = Query(None, ge=1, le=365),
    start: date | None = None,
    end: date | None = None,
    db: Session = Depends(get_db),
):
    """Improve Code outcome analytics from analytics_events."""
    start_date, end_date = _parse_date_range(days, start, end)
    date_filters = _date_filter(AnalyticsEvent, start_date, end_date)
    req_date_filters = _date_filter(AIRequest, start_date, end_date)

    improve_types = ["improve_copy", "improve_replace", "improve_dismiss", "improve_no_change"]

    # ── Aggregate outcome counts ──
    counts = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(*date_filters, AnalyticsEvent.event_type.in_(improve_types))
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    copy_count = counts.get("improve_copy", 0)
    replace_count = counts.get("improve_replace", 0)
    dismiss_count = counts.get("improve_dismiss", 0)
    no_change_count = counts.get("improve_no_change", 0)
    total_outcomes = copy_count + replace_count + dismiss_count + no_change_count

    # ── Improve AI requests count (from ai_requests) ──
    improve_requests = (
        db.query(sa_func.count(AIRequest.id))
        .filter(*req_date_filters, AIRequest.request_type == "improve")
        .scalar()
    ) or 0

    # ── Explain requests for adoption rate ──
    explain_requests = (
        db.query(sa_func.count(AIRequest.id))
        .filter(*req_date_filters, AIRequest.request_type == "explain")
        .scalar()
    ) or 0
    adoption_rate = round(improve_requests / explain_requests * 100, 1) if explain_requests > 0 else None

    # ── Acceptance rate: (copy + replace) / improvable requests ──
    improvable_total = total_outcomes - no_change_count
    accepted_total = copy_count + replace_count
    acceptance_rate = round(accepted_total / improvable_total * 100, 1) if improvable_total > 0 else None
    no_change_rate = round(no_change_count / total_outcomes * 100, 1) if total_outcomes > 0 else None

    # ── Replace failure rate from metadata ──
    replace_failure_count = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(
            *date_filters,
            AnalyticsEvent.event_type == "improve_replace",
            AnalyticsEvent.metadata_["replace_result"].as_string() != "success",
        )
        .scalar()
    ) or 0
    replace_failure_rate = (
        round(replace_failure_count / replace_count * 100, 1)
        if replace_count > 0 else None
    )

    # ── Unique users ──
    improve_users = (
        db.query(sa_func.count(sa_func.distinct(AnalyticsEvent.user_id)))
        .filter(*date_filters, AnalyticsEvent.event_type.in_(improve_types))
        .scalar()
    ) or 0

    # ── Daily trend ──
    daily = (
        db.query(
            cast(AnalyticsEvent.created_at, Date).label("day"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_copy").label("copies"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_replace").label("replaces"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_dismiss").label("dismissals"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_no_change").label("no_changes"),
        )
        .filter(*date_filters, AnalyticsEvent.event_type.in_(improve_types))
        .group_by("day")
        .order_by("day")
        .all()
    )

    # ── Top users by improve activity ──
    top_users = (
        db.query(
            AnalyticsEvent.user_id,
            sa_func.count().label("total"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_copy").label("copies"),
            sa_func.count().filter(AnalyticsEvent.event_type == "improve_replace").label("replaces"),
        )
        .filter(*date_filters, AnalyticsEvent.event_type.in_(improve_types))
        .group_by(AnalyticsEvent.user_id)
        .order_by(sa_func.count().desc())
        .limit(20)
        .all()
    )

    return {
        "period": {"start": str(start_date), "end": str(end_date)},
        "improve_requests": improve_requests,
        "explain_requests": explain_requests,
        "adoption_rate": adoption_rate,
        "copy_count": copy_count,
        "replace_count": replace_count,
        "dismiss_count": dismiss_count,
        "no_change_count": no_change_count,
        "total_outcomes": total_outcomes,
        "acceptance_rate": acceptance_rate,
        "no_change_rate": no_change_rate,
        "replace_failure_count": replace_failure_count,
        "replace_failure_rate": replace_failure_rate,
        "improve_users": improve_users,
        "daily_trend": [
            {
                "date": str(r.day),
                "copies": r.copies or 0,
                "replaces": r.replaces or 0,
                "dismissals": r.dismissals or 0,
                "no_changes": r.no_changes or 0,
            }
            for r in daily
        ],
        "top_users": [
            {
                "user_id": str(r.user_id),
                "total": r.total,
                "copies": r.copies or 0,
                "replaces": r.replaces or 0,
            }
            for r in top_users
        ],
    }
