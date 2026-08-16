import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import Date, case, cast, func as sa_func
from sqlalchemy.orm import Session

from app.auth import generate_invite_code, require_admin
from app.database import get_db
from app.models.analytics_event import AnalyticsEvent
from app.models.request_log import RequestLog
from app.models.user import User, UserStatus

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/admin",
    tags=["admin"],
    dependencies=[Depends(require_admin)],
)


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class InviteRequest(BaseModel):
    name: str | None = None
    email: str | None = None


class InviteResponse(BaseModel):
    user_id: str
    invite_code: str
    status: str


class UserResponse(BaseModel):
    id: str
    name: str | None
    email: str | None
    status: str
    invite_code: str | None
    created_at: datetime
    activated_at: datetime | None
    selection_requests: int
    screenshot_requests: int
    session_requests: int
    total_requests: int
    successful_requests: int
    success_rate: int | None
    last_active: datetime | None
    estimated_cost_usd: float | None
    active_days: int


class UserUpdateRequest(BaseModel):
    name: str | None = None
    email: str | None = None


class UserStatusResponse(BaseModel):
    user_id: str
    status: str


class ProviderAnalytics(BaseModel):
    ai_provider: str
    ai_model: str | None
    request_count: int
    success_count: int
    failure_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_total_tokens: float | None
    estimated_cost_usd: float | None


class ProfileAnalytics(BaseModel):
    explanation_profile: str
    request_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_total_tokens: float | None


class ErrorBreakdown(BaseModel):
    error_type: str
    count: int


class AnalyticsResponse(BaseModel):
    total_users: int
    active_users: int
    pending_users: int
    disabled_users: int
    total_requests: int
    successful_requests: int
    failed_requests: int
    success_rate: float | None
    average_latency_ms: int | None
    p50_latency_ms: int | None
    p95_latency_ms: int | None
    selection_requests: int
    screenshot_requests: int
    session_requests: int
    avg_prompt_tokens: float | None
    avg_completion_tokens: float | None
    avg_total_tokens: float | None
    selection_improve_requests: int = 0
    session_improve_requests: int = 0
    improve_adoption_rate: float | None = None
    improve_copy_count: int = 0
    improve_replace_count: int = 0
    improve_acceptance_rate: float | None = None
    improve_no_change_count: int = 0
    improve_no_change_rate: float | None = None
    improve_replace_failure_count: int = 0
    improve_replace_failure_rate: float | None = None
    total_followups: int = 0
    followup_rate: float | None = None
    followup_avg_prompt_tokens: float | None = None
    followup_avg_completion_tokens: float | None = None
    followup_avg_total_tokens: float | None = None
    followup_estimated_cost_usd: float | None = None
    # History analytics (from analytics_events)
    history_opens: int = 0
    history_users: int = 0
    history_followups: int = 0
    history_followup_rate: float | None = None
    history_clears: int = 0
    history_avg_depth: float | None = None
    history_selection_source: dict | None = None
    history_depth_distribution: dict | None = None
    analytics_coverage: float | None
    estimated_total_cost_usd: float | None
    provider_analytics: list[ProviderAnalytics]
    profile_analytics: list[ProfileAnalytics]
    error_breakdown: list[ErrorBreakdown]


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/invite", response_model=InviteResponse)
def create_invite(
    body: InviteRequest,
    db: Session = Depends(get_db),
) -> InviteResponse:
    """Generate a new invite code and create a pending user."""
    code = generate_invite_code()
    email = (body.email or "").strip()
    name = (body.name or "").strip() or None

    user = User(
        name=name,
        email=email if email else f"pending-{code.lower()}@decode.app",
        invite_code=code,
        status=UserStatus.pending,
    )
    db.add(user)
    db.flush()

    return InviteResponse(
        user_id=user.id,
        invite_code=code,
        status=user.status.value,
    )


@router.get("/users", response_model=list[UserResponse])
def list_users(
    db: Session = Depends(get_db),
    profile: str | None = Query(None),
) -> list[UserResponse]:
    """List all users with per-user usage analytics, newest first."""
    # When profile is set, filter the join condition so aggregates
    # reflect only requests with that explanation_profile.
    join_cond = User.id == RequestLog.user_id
    if profile:
        join_cond = join_cond & (RequestLog.explanation_profile == profile)

    rows = (
        db.query(
            User,
            sa_func.count(RequestLog.id).label("total_requests"),
            sa_func.count(
                case((RequestLog.success.is_(True), RequestLog.id))
            ).label("successful_requests"),
            sa_func.count(
                case((RequestLog.mode == "selection", RequestLog.id))
            ).label("selection_requests"),
            sa_func.count(
                case((RequestLog.mode == "screenshot", RequestLog.id))
            ).label("screenshot_requests"),
            sa_func.count(
                case((RequestLog.mode == "session", RequestLog.id))
            ).label("session_requests"),
            sa_func.max(RequestLog.created_at).label("last_active"),
            sa_func.count(
                sa_func.distinct(cast(RequestLog.created_at, Date))
            ).label("active_days"),
            sa_func.sum(_cost_sql_expr()).label("estimated_cost"),
        )
        .outerjoin(RequestLog, join_cond)
        .group_by(User.id)
        .order_by(User.created_at.desc())
        .all()
    )

    results: list[UserResponse] = []
    for u, total, successful, selection, screenshot, session, last_active, active_days, est_cost in rows:
        success_rate: int | None = None
        if total > 0:
            success_rate = round(successful / total * 100)
        results.append(
            UserResponse(
                id=u.id,
                name=u.name,
                email=u.email,
                status=u.status.value,
                invite_code=u.invite_code,
                created_at=u.created_at,
                activated_at=u.activated_at,
                selection_requests=selection,
                screenshot_requests=screenshot,
                session_requests=session,
                total_requests=total,
                successful_requests=successful,
                success_rate=success_rate,
                last_active=last_active,
                estimated_cost_usd=round(est_cost, 4) if est_cost is not None else None,
                active_days=active_days or 0,
            )
        )
    return results


@router.post("/users/{user_id}/disable", response_model=UserStatusResponse)
def disable_user(
    user_id: str,
    db: Session = Depends(get_db),
) -> UserStatusResponse:
    """Disable a user account."""
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    user.status = UserStatus.disabled
    db.flush()

    return UserStatusResponse(user_id=user.id, status=user.status.value)


@router.post("/users/{user_id}/enable", response_model=UserStatusResponse)
def enable_user(
    user_id: str,
    db: Session = Depends(get_db),
) -> UserStatusResponse:
    """Re-enable a disabled user account."""
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    user.status = UserStatus.active
    db.flush()

    return UserStatusResponse(user_id=user.id, status=user.status.value)


@router.patch("/users/{user_id}")
def update_user(
    user_id: str,
    body: UserUpdateRequest,
    db: Session = Depends(get_db),
) -> dict:
    """Update a user's name and/or email."""
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    if body.name is not None:
        user.name = body.name.strip() or None
    if body.email is not None:
        email = body.email.strip()
        if email and "@" not in email:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid email format",
            )
        if email:
            user.email = email

    user.updated_at = datetime.now(timezone.utc)
    db.flush()

    return {
        "id": user.id,
        "name": user.name,
        "email": user.email,
        "status": user.status.value,
    }


@router.delete("/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_user(
    user_id: str,
    db: Session = Depends(get_db),
) -> None:
    """Delete a user and all their request logs."""
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    # Cascade: delete all related records for this user first.
    db.query(AnalyticsEvent).filter(AnalyticsEvent.user_id == user_id).delete()
    db.query(RequestLog).filter(RequestLog.user_id == user_id).delete()
    db.delete(user)
    db.flush()


# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------
# Pricing is defined in app.pricing — single source of truth.
from app.pricing import MODEL_PRICING_PER_MTOK as _MODEL_PRICING_PER_MTOK


def _profile_filter(query, profile: str | None):
    """Apply explanation_profile WHERE clause when a profile scope is set."""
    if profile:
        return query.filter(RequestLog.explanation_profile == profile)
    return query


def _estimate_cost(
    model: str | None,
    sum_prompt_tokens: int | None,
    sum_completion_tokens: int | None,
) -> float | None:
    """Estimate USD cost from token sums and known model pricing."""
    if not model or sum_prompt_tokens is None or sum_completion_tokens is None:
        return None
    pricing = _MODEL_PRICING_PER_MTOK.get(model)
    if pricing is None:
        logger.warning(
            "COST_ESTIMATION unknown model '%s' — add to app/pricing.py for accurate cost tracking",
            model,
        )
        return None
    input_rate, output_rate = pricing
    return round(
        (sum_prompt_tokens * input_rate + sum_completion_tokens * output_rate)
        / 1_000_000,
        4,
    )


def _cost_sql_expr():
    """Return a SQL expression that estimates cost per-row using ai_model.

    Uses a CASE expression over known model pricing so that aggregate
    queries (SUM, AVG) compute cost from each request's actual ai_model
    rather than a single global config value.
    """
    whens = [
        (
            RequestLog.ai_model == model,
            (RequestLog.prompt_tokens * input_rate
             + RequestLog.completion_tokens * output_rate) / 1_000_000,
        )
        for model, (input_rate, output_rate) in _MODEL_PRICING_PER_MTOK.items()
    ]
    return case(*whens, else_=None)


# ---------------------------------------------------------------------------
# Analytics endpoint
# ---------------------------------------------------------------------------


@router.get("/analytics", response_model=AnalyticsResponse)
def get_analytics(
    db: Session = Depends(get_db),
    profile: str | None = Query(None, description="Filter by explanation_profile: general, dsa"),
) -> AnalyticsResponse:
    """Return platform analytics from users and request_logs."""
    # ── User counts ──
    status_counts = (
        db.query(User.status, sa_func.count())
        .group_by(User.status)
        .all()
    )
    counts = {s.value: c for s, c in status_counts}

    total_users = sum(counts.values())
    active_users = counts.get("active", 0)
    pending_users = counts.get("pending", 0)
    disabled_users = counts.get("disabled", 0)

    # ── Request log aggregates ──
    log_q = db.query(
        sa_func.count(RequestLog.id),
        sa_func.count(RequestLog.id).filter(RequestLog.success.is_(True)),
        sa_func.count(RequestLog.id).filter(RequestLog.success.is_(False)),
        sa_func.avg(RequestLog.latency_ms),
        sa_func.count(RequestLog.id).filter(RequestLog.mode == "selection"),
        sa_func.count(RequestLog.id).filter(RequestLog.mode == "screenshot"),
        sa_func.count(RequestLog.id).filter(RequestLog.mode == "session"),
        sa_func.count(RequestLog.id).filter(RequestLog.mode == "selection_improve"),
        sa_func.count(RequestLog.id).filter(RequestLog.mode == "session_improve"),
        sa_func.count(RequestLog.id).filter(RequestLog.mode.in_(["selection_followup", "session_followup", "screenshot_followup"])),
    )
    log_stats = _profile_filter(log_q, profile).one()

    total_requests = log_stats[0] or 0
    successful_requests = log_stats[1] or 0
    failed_requests = log_stats[2] or 0
    avg_latency = int(log_stats[3]) if log_stats[3] is not None else None
    success_rate = round(successful_requests / total_requests * 100, 1) if total_requests > 0 else None

    selection_improve_requests = log_stats[7] or 0
    session_improve_requests = log_stats[8] or 0
    explain_total = (log_stats[4] or 0) + (log_stats[6] or 0)
    improve_total = selection_improve_requests + session_improve_requests
    improve_adoption_rate = (
        round(improve_total / explain_total * 100, 1)
        if explain_total > 0 else None
    )

    # ── Improve Code outcome events (from analytics_events) ──
    event_counts = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.event_type.in_([
            "improve_copy", "improve_replace", "improve_dismiss", "improve_no_change",
        ]))
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    improve_copy_count = event_counts.get("improve_copy", 0)
    improve_replace_count = event_counts.get("improve_replace", 0)
    improve_no_change_count = event_counts.get("improve_no_change", 0)

    # Acceptance = (copy + replace) / improve requests that produced code.
    # "No change" requests have no code to accept, so exclude them.
    improvable_total = improve_total - improve_no_change_count
    accepted_total = improve_copy_count + improve_replace_count
    improve_acceptance_rate = (
        round(accepted_total / improvable_total * 100, 1)
        if improvable_total > 0 else None
    )
    improve_no_change_rate = (
        round(improve_no_change_count / improve_total * 100, 1)
        if improve_total > 0 else None
    )

    # Replace failure rate from metadata.
    replace_failure_count = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(
            AnalyticsEvent.event_type == "improve_replace",
            AnalyticsEvent.metadata_["replace_result"].as_string() != "success",
        )
        .scalar()
    ) or 0
    improve_replace_failure_rate = (
        round(replace_failure_count / improve_replace_count * 100, 1)
        if improve_replace_count > 0 else None
    )

    # ── Follow-Up analytics ──
    total_followups = log_stats[9] or 0
    # Follow-up rate = followups / (selection + screenshot + session explanations).
    explain_base = (log_stats[4] or 0) + (log_stats[5] or 0) + (log_stats[6] or 0)
    followup_rate = (
        round(total_followups / explain_base * 100, 1)
        if explain_base > 0 else None
    )
    followup_tok_q = db.query(
        sa_func.avg(RequestLog.prompt_tokens),
        sa_func.avg(RequestLog.completion_tokens),
        sa_func.avg(RequestLog.total_tokens),
        sa_func.sum(_cost_sql_expr()),
    ).filter(
        RequestLog.mode.in_(["selection_followup", "session_followup", "screenshot_followup"]),
        RequestLog.prompt_tokens.isnot(None),
    )
    followup_tok_stats = _profile_filter(followup_tok_q, profile).one()
    followup_avg_prompt_tokens = round(followup_tok_stats[0], 1) if followup_tok_stats[0] is not None else None
    followup_avg_completion_tokens = round(followup_tok_stats[1], 1) if followup_tok_stats[1] is not None else None
    followup_avg_total_tokens = round(followup_tok_stats[2], 1) if followup_tok_stats[2] is not None else None
    followup_estimated_cost = round(followup_tok_stats[3], 4) if followup_tok_stats[3] is not None else None

    # ── History analytics (from analytics_events) ──
    history_opens = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.event_type == "history_opened")
        .scalar()
    ) or 0
    history_users = (
        db.query(sa_func.count(sa_func.distinct(AnalyticsEvent.user_id)))
        .filter(AnalyticsEvent.event_type.in_(["history_opened", "history_followup", "history_cleared"]))
        .scalar()
    ) or 0
    history_followups = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.event_type == "history_followup")
        .scalar()
    ) or 0
    # History follow-up rate = history follow-ups / history opens.
    history_followup_rate = (
        round(history_followups / history_opens * 100, 1)
        if history_opens > 0 else None
    )
    history_clears = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.event_type == "history_cleared")
        .scalar()
    ) or 0
    # Average follow-up depth from metadata.
    history_depth_rows = (
        db.query(AnalyticsEvent.metadata_["followup_depth"])
        .filter(
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["followup_depth"].isnot(None),
        )
        .all()
    )
    depth_values = [int(r[0]) for r in history_depth_rows if r[0] is not None]
    history_avg_depth = round(sum(depth_values) / len(depth_values), 1) if depth_values else None
    # Depth distribution.
    history_depth_distribution = {}
    for d in depth_values:
        history_depth_distribution[str(d)] = history_depth_distribution.get(str(d), 0) + 1
    # Selection source distribution from metadata.
    history_source_rows = (
        db.query(
            AnalyticsEvent.metadata_["selection_source"].as_string(),
            sa_func.count(AnalyticsEvent.id),
        )
        .filter(
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["selection_source"].isnot(None),
        )
        .group_by(AnalyticsEvent.metadata_["selection_source"].as_string())
        .all()
    )
    history_selection_source = {src: cnt for src, cnt in history_source_rows} if history_source_rows else None

    # ── Latency percentiles (PostgreSQL percentile_cont) ──
    lat_q = db.query(
        sa_func.percentile_cont(0.5).within_group(RequestLog.latency_ms),
        sa_func.percentile_cont(0.95).within_group(RequestLog.latency_ms),
    ).filter(RequestLog.success.is_(True))
    latency_pct = _profile_filter(lat_q, profile).one()

    p50_latency = int(latency_pct[0]) if latency_pct[0] is not None else None
    p95_latency = int(latency_pct[1]) if latency_pct[1] is not None else None

    # ── Global token averages (exclude legacy rows without analytics) ──
    tok_q = db.query(
        sa_func.avg(RequestLog.prompt_tokens),
        sa_func.avg(RequestLog.completion_tokens),
        sa_func.avg(RequestLog.total_tokens),
        sa_func.count(RequestLog.id),
    ).filter(RequestLog.prompt_tokens.isnot(None))
    token_stats = _profile_filter(tok_q, profile).one()

    avg_prompt_tokens = round(token_stats[0], 1) if token_stats[0] is not None else None
    avg_completion_tokens = round(token_stats[1], 1) if token_stats[1] is not None else None
    avg_total_tokens = round(token_stats[2], 1) if token_stats[2] is not None else None
    analytics_count = token_stats[3] or 0
    analytics_coverage = round(analytics_count / total_requests * 100, 1) if total_requests > 0 else None

    # ── Provider analytics ──
    prov_q = (
        db.query(
            RequestLog.ai_provider,
            RequestLog.ai_model,
            sa_func.count(RequestLog.id),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.count(case((RequestLog.success.is_(False), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
            sa_func.avg(RequestLog.total_tokens),
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
        )
        .filter(RequestLog.ai_provider.isnot(None))
    )
    provider_rows = (
        _profile_filter(prov_q, profile)
        .group_by(RequestLog.ai_provider, RequestLog.ai_model)
        .order_by(sa_func.count(RequestLog.id).desc())
        .all()
    )

    provider_analytics = [
        ProviderAnalytics(
            ai_provider=prov,
            ai_model=model,
            request_count=count,
            success_count=sc,
            failure_count=fc,
            success_rate=round(sc / count * 100, 1) if count > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            avg_total_tokens=round(atot, 1) if atot is not None else None,
            estimated_cost_usd=_estimate_cost(model, sp, scp),
        )
        for prov, model, count, sc, fc, alat, atot, sp, scp in provider_rows
    ]

    # ── Profile analytics (explanation_profile) ──
    prof_q = (
        db.query(
            RequestLog.explanation_profile,
            sa_func.count(RequestLog.id),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
            sa_func.avg(RequestLog.total_tokens),
        )
        .filter(RequestLog.explanation_profile.isnot(None))
    )
    profile_rows = (
        _profile_filter(prof_q, profile)
        .group_by(RequestLog.explanation_profile)
        .order_by(sa_func.count(RequestLog.id).desc())
        .all()
    )

    profile_analytics = [
        ProfileAnalytics(
            explanation_profile=profile,
            request_count=count,
            success_rate=round(sc / count * 100, 1) if count > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            avg_total_tokens=round(atot, 1) if atot is not None else None,
        )
        for profile, count, sc, alat, atot in profile_rows
    ]

    # ── Error breakdown ──
    err_q = (
        db.query(
            RequestLog.error_type,
            sa_func.count(RequestLog.id),
        )
        .filter(RequestLog.success.is_(False))
        .filter(RequestLog.error_type.isnot(None))
    )
    error_rows = (
        _profile_filter(err_q, profile)
        .group_by(RequestLog.error_type)
        .order_by(sa_func.count(RequestLog.id).desc())
        .all()
    )

    error_breakdown = [
        ErrorBreakdown(error_type=et, count=c)
        for et, c in error_rows
    ]

    # ── Total cost (computed from per-provider/model groups) ──
    estimated_total_cost = 0.0
    has_any_cost = False
    for _, model, _, _, _, _, _, sp, scp in provider_rows:
        cost = _estimate_cost(model, sp, scp)
        if cost is not None:
            has_any_cost = True
            estimated_total_cost += cost

    return AnalyticsResponse(
        total_users=total_users,
        active_users=active_users,
        pending_users=pending_users,
        disabled_users=disabled_users,
        total_requests=total_requests,
        successful_requests=successful_requests,
        failed_requests=failed_requests,
        success_rate=success_rate,
        average_latency_ms=avg_latency,
        p50_latency_ms=p50_latency,
        p95_latency_ms=p95_latency,
        selection_requests=log_stats[4] or 0,
        screenshot_requests=log_stats[5] or 0,
        session_requests=log_stats[6] or 0,
        selection_improve_requests=selection_improve_requests,
        session_improve_requests=session_improve_requests,
        improve_adoption_rate=improve_adoption_rate,
        improve_copy_count=improve_copy_count,
        improve_replace_count=improve_replace_count,
        improve_acceptance_rate=improve_acceptance_rate,
        improve_no_change_count=improve_no_change_count,
        improve_no_change_rate=improve_no_change_rate,
        improve_replace_failure_count=replace_failure_count,
        improve_replace_failure_rate=improve_replace_failure_rate,
        total_followups=total_followups,
        followup_rate=followup_rate,
        followup_avg_prompt_tokens=followup_avg_prompt_tokens,
        followup_avg_completion_tokens=followup_avg_completion_tokens,
        followup_avg_total_tokens=followup_avg_total_tokens,
        followup_estimated_cost_usd=followup_estimated_cost,
        history_opens=history_opens,
        history_users=history_users,
        history_followups=history_followups,
        history_followup_rate=history_followup_rate,
        history_clears=history_clears,
        history_avg_depth=history_avg_depth,
        history_selection_source=history_selection_source,
        history_depth_distribution=history_depth_distribution,
        avg_prompt_tokens=avg_prompt_tokens,
        avg_completion_tokens=avg_completion_tokens,
        avg_total_tokens=avg_total_tokens,
        analytics_coverage=analytics_coverage,
        estimated_total_cost_usd=round(estimated_total_cost, 4) if has_any_cost else None,
        provider_analytics=provider_analytics,
        profile_analytics=profile_analytics,
        error_breakdown=error_breakdown,
    )


# ---------------------------------------------------------------------------
# User detail
# ---------------------------------------------------------------------------


class UserProfile(BaseModel):
    id: str
    name: str | None
    email: str | None
    invite_code: str | None
    status: str
    created_at: datetime
    activated_at: datetime | None
    first_request: datetime | None
    last_request: datetime | None
    active_days: int


class UserImproveBreakdown(BaseModel):
    improve_requests: int = 0
    copy_count: int = 0
    replace_count: int = 0
    acceptance_rate: float | None = None


class UserModeBreakdown(BaseModel):
    selection: int
    screenshot: int
    session: int


class UserTokenBreakdown(BaseModel):
    avg_prompt_tokens: float | None
    avg_completion_tokens: float | None
    avg_total_tokens: float | None


class UserCostBreakdown(BaseModel):
    total_cost: float | None
    cost_per_request: float | None
    cost_per_active_day: float | None


class UserDailyRecord(BaseModel):
    date: str
    requests: int
    selection: int
    screenshot: int
    session: int
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    estimated_cost: float | None
    success_rate: float
    avg_latency_ms: float | None


class UserFollowUpBreakdown(BaseModel):
    followup_count: int = 0
    followup_rate: float | None = None
    avg_prompt_tokens: float | None = None
    avg_completion_tokens: float | None = None
    avg_total_tokens: float | None = None
    estimated_cost_usd: float | None = None


class UserHistoryBreakdown(BaseModel):
    history_opens: int = 0
    history_followups: int = 0
    history_followup_rate: float | None = None
    history_clears: int = 0
    avg_depth: float | None = None
    max_depth: int | None = None
    selection_source: dict | None = None
    last_activity: datetime | None = None
    first_activity: datetime | None = None


class UserProfileIntelligence(BaseModel):
    """Derived Profile Intelligence snapshot synced from the macOS client."""
    available: bool = False
    schema_version: int | None = None
    synced_at: datetime | None = None
    data: dict | None = None


class UserDetailResponse(BaseModel):
    profile: UserProfile
    mode_breakdown: UserModeBreakdown
    improve_breakdown: UserImproveBreakdown = UserImproveBreakdown()
    followup_breakdown: UserFollowUpBreakdown = UserFollowUpBreakdown()
    history_breakdown: UserHistoryBreakdown = UserHistoryBreakdown()
    token_breakdown: UserTokenBreakdown
    cost_breakdown: UserCostBreakdown
    daily: list[UserDailyRecord]
    profile_intelligence: UserProfileIntelligence = UserProfileIntelligence()


def _user_improve_breakdown(db: Session, user_id: str) -> UserImproveBreakdown:
    """Compute per-user Improve Code metrics from request_logs + analytics_events."""
    improve_requests = (
        db.query(sa_func.count(RequestLog.id))
        .filter(
            RequestLog.user_id == user_id,
            RequestLog.mode.in_(["selection_improve", "session_improve"]),
        )
        .scalar()
    ) or 0

    user_events = dict(
        db.query(AnalyticsEvent.event_type, sa_func.count(AnalyticsEvent.id))
        .filter(
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type.in_(["improve_copy", "improve_replace"]),
        )
        .group_by(AnalyticsEvent.event_type)
        .all()
    )
    copy_count = user_events.get("improve_copy", 0)
    replace_count = user_events.get("improve_replace", 0)
    accepted = copy_count + replace_count
    acceptance_rate = (
        round(accepted / improve_requests * 100, 1)
        if improve_requests > 0 else None
    )
    return UserImproveBreakdown(
        improve_requests=improve_requests,
        copy_count=copy_count,
        replace_count=replace_count,
        acceptance_rate=acceptance_rate,
    )


def _user_followup_breakdown(db: Session, user_id: str) -> UserFollowUpBreakdown:
    """Compute per-user Follow-Up metrics from request_logs."""
    followup_modes = ["selection_followup", "session_followup", "screenshot_followup"]
    base_modes = ["selection", "screenshot", "session"]

    followup_stats = (
        db.query(
            sa_func.count(RequestLog.id),
            sa_func.avg(RequestLog.prompt_tokens),
            sa_func.avg(RequestLog.completion_tokens),
            sa_func.avg(RequestLog.total_tokens),
            sa_func.sum(_cost_sql_expr()),
        )
        .filter(
            RequestLog.user_id == user_id,
            RequestLog.mode.in_(followup_modes),
        )
        .one()
    )

    followup_count = followup_stats[0] or 0

    # Rate = followups / base explanation requests for this user.
    explain_count = (
        db.query(sa_func.count(RequestLog.id))
        .filter(
            RequestLog.user_id == user_id,
            RequestLog.mode.in_(base_modes),
        )
        .scalar()
    ) or 0

    followup_rate = (
        round(followup_count / explain_count * 100, 1)
        if explain_count > 0 else None
    )

    estimated_cost = round(followup_stats[4], 4) if followup_stats[4] is not None else None

    return UserFollowUpBreakdown(
        followup_count=followup_count,
        followup_rate=followup_rate,
        avg_prompt_tokens=round(followup_stats[1], 1) if followup_stats[1] is not None else None,
        avg_completion_tokens=round(followup_stats[2], 1) if followup_stats[2] is not None else None,
        avg_total_tokens=round(followup_stats[3], 1) if followup_stats[3] is not None else None,
        estimated_cost_usd=estimated_cost,
    )


def _user_history_breakdown(db: Session, user_id: str) -> UserHistoryBreakdown:
    """Compute per-user History metrics from analytics_events."""
    history_opens = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.user_id == user_id, AnalyticsEvent.event_type == "history_opened")
        .scalar()
    ) or 0

    history_followups = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.user_id == user_id, AnalyticsEvent.event_type == "history_followup")
        .scalar()
    ) or 0

    history_followup_rate = (
        round(history_followups / history_opens * 100, 1)
        if history_opens > 0 else None
    )

    history_clears = (
        db.query(sa_func.count(AnalyticsEvent.id))
        .filter(AnalyticsEvent.user_id == user_id, AnalyticsEvent.event_type == "history_cleared")
        .scalar()
    ) or 0

    # Depth metrics from metadata.
    depth_rows = (
        db.query(AnalyticsEvent.metadata_["followup_depth"])
        .filter(
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["followup_depth"].isnot(None),
        )
        .all()
    )
    depth_values = [int(r[0]) for r in depth_rows if r[0] is not None]
    avg_depth = round(sum(depth_values) / len(depth_values), 1) if depth_values else None
    max_depth = max(depth_values) if depth_values else None

    # Selection source distribution.
    source_rows = (
        db.query(
            AnalyticsEvent.metadata_["selection_source"].as_string(),
            sa_func.count(AnalyticsEvent.id),
        )
        .filter(
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type == "history_followup",
            AnalyticsEvent.metadata_["selection_source"].isnot(None),
        )
        .group_by(AnalyticsEvent.metadata_["selection_source"].as_string())
        .all()
    )
    selection_source = {src: cnt for src, cnt in source_rows} if source_rows else None

    # First and last History activity timestamps.
    activity_range = (
        db.query(
            sa_func.min(AnalyticsEvent.created_at),
            sa_func.max(AnalyticsEvent.created_at),
        )
        .filter(
            AnalyticsEvent.user_id == user_id,
            AnalyticsEvent.event_type.in_(["history_opened", "history_followup", "history_cleared"]),
        )
        .one()
    )
    first_activity = activity_range[0]
    last_activity = activity_range[1]

    return UserHistoryBreakdown(
        history_opens=history_opens,
        history_followups=history_followups,
        history_followup_rate=history_followup_rate,
        history_clears=history_clears,
        avg_depth=avg_depth,
        max_depth=max_depth,
        selection_source=selection_source,
        first_activity=first_activity,
        last_activity=last_activity,
    )


@router.get("/users/{user_id}", response_model=UserDetailResponse)
def get_user_detail(
    user_id: str,
    db: Session = Depends(get_db),
    profile: str | None = Query(None),
) -> UserDetailResponse:
    """Return detailed analytics for a single user."""
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    # Base filter for this user, optionally scoped to a profile.
    def _user_log_q(q):
        q = q.filter(RequestLog.user_id == user_id)
        return _profile_filter(q, profile)

    # ── Profile stats ──
    profile_stats = _user_log_q(db.query(
        sa_func.min(RequestLog.created_at),
        sa_func.max(RequestLog.created_at),
        sa_func.count(sa_func.distinct(cast(RequestLog.created_at, Date))),
    )).one()

    first_request = profile_stats[0]
    last_request = profile_stats[1]
    active_days = profile_stats[2] or 0

    # ── Mode breakdown ──
    mode_rows = (
        _user_log_q(
            db.query(RequestLog.mode, sa_func.count(RequestLog.id))
            .filter(RequestLog.mode.isnot(None))
        )
        .group_by(RequestLog.mode)
        .all()
    )
    mode_map = {m: c for m, c in mode_rows}

    # ── Token breakdown ──
    token_stats = _user_log_q(db.query(
        sa_func.avg(RequestLog.prompt_tokens),
        sa_func.avg(RequestLog.completion_tokens),
        sa_func.avg(RequestLog.total_tokens),
    ).filter(RequestLog.prompt_tokens.isnot(None))).one()

    # ── Cost breakdown ──
    cost_stats = _user_log_q(db.query(
        sa_func.sum(_cost_sql_expr()),
        sa_func.count(RequestLog.id),
    ).filter(RequestLog.prompt_tokens.isnot(None))).one()

    total_cost = round(cost_stats[0], 4) if cost_stats[0] is not None else None
    total_reqs = cost_stats[1] or 0

    cost_per_request = round(total_cost / total_reqs, 4) if total_cost and total_reqs > 0 else None
    cost_per_active_day = round(total_cost / active_days, 4) if total_cost and active_days > 0 else None

    # ── Per-day analytics ──
    day = cast(RequestLog.created_at, Date).label("day")
    daily_rows = (
        _user_log_q(db.query(
            day,
            sa_func.count(RequestLog.id),
            sa_func.count(case((RequestLog.mode == "selection", RequestLog.id))),
            sa_func.count(case((RequestLog.mode == "screenshot", RequestLog.id))),
            sa_func.count(case((RequestLog.mode == "session", RequestLog.id))),
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
            sa_func.sum(RequestLog.total_tokens),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
            sa_func.sum(_cost_sql_expr()),
        ))
        .group_by(day)
        .order_by(day)
        .all()
    )

    daily = [
        UserDailyRecord(
            date=str(d),
            requests=total,
            selection=sel,
            screenshot=scr,
            session=ses,
            prompt_tokens=sp,
            completion_tokens=sc,
            total_tokens=st,
            estimated_cost=round(est_cost, 4) if est_cost is not None else None,
            success_rate=round(succ / total * 100, 1) if total > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
        )
        for d, total, sel, scr, ses, sp, sc, st, succ, alat, est_cost in daily_rows
    ]

    return UserDetailResponse(
        profile=UserProfile(
            id=user.id,
            name=user.name,
            email=user.email,
            invite_code=user.invite_code,
            status=user.status.value,
            created_at=user.created_at,
            activated_at=user.activated_at,
            first_request=first_request,
            last_request=last_request,
            active_days=active_days,
        ),
        mode_breakdown=UserModeBreakdown(
            selection=mode_map.get("selection", 0),
            screenshot=mode_map.get("screenshot", 0),
            session=mode_map.get("session", 0),
        ),
        improve_breakdown=_user_improve_breakdown(db, user.id),
        followup_breakdown=_user_followup_breakdown(db, user.id),
        history_breakdown=_user_history_breakdown(db, user.id),
        token_breakdown=UserTokenBreakdown(
            avg_prompt_tokens=round(token_stats[0], 1) if token_stats[0] is not None else None,
            avg_completion_tokens=round(token_stats[1], 1) if token_stats[1] is not None else None,
            avg_total_tokens=round(token_stats[2], 1) if token_stats[2] is not None else None,
        ),
        cost_breakdown=UserCostBreakdown(
            total_cost=total_cost,
            cost_per_request=cost_per_request,
            cost_per_active_day=cost_per_active_day,
        ),
        daily=daily,
        profile_intelligence=UserProfileIntelligence(
            available=user.profile_snapshot is not None,
            schema_version=user.profile_schema_version,
            synced_at=user.profile_synced_at,
            data=user.profile_snapshot,
        ),
    )


# ---------------------------------------------------------------------------
# Founder Intelligence
# ---------------------------------------------------------------------------


class ActivationFunnel(BaseModel):
    invites_generated: int
    activated: int
    made_first_request: int
    active_after_7d: int
    active_after_30d: int
    activated_pct: float
    first_request_pct: float
    active_7d_pct: float
    active_30d_pct: float


class TimeToFirstValue(BaseModel):
    average_seconds: float | None
    median_seconds: float | None
    fastest_seconds: float | None
    slowest_seconds: float | None
    sample_size: int


class CostPerActiveUser(BaseModel):
    today: float | None
    last_7d: float | None
    all_time: float | None
    active_users_today: int
    active_users_7d: int
    active_users_all_time: int


class SlowestRequest(BaseModel):
    user_name: str | None
    user_email: str | None
    mode: str | None
    latency_ms: int
    created_at: datetime
    ai_provider: str | None
    ai_model: str | None
    success: bool


class ErrorTrendDay(BaseModel):
    date: str
    error_type: str
    count: int


class LanguageAnalyticsItem(BaseModel):
    language: str
    request_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_total_tokens: float | None
    estimated_cost_usd: float | None


class FounderIntelligenceResponse(BaseModel):
    activation_funnel: ActivationFunnel
    time_to_first_value: TimeToFirstValue
    cost_per_active_user: CostPerActiveUser
    slowest_requests: list[SlowestRequest]
    error_trends: list[ErrorTrendDay]
    language_analytics: list[LanguageAnalyticsItem]


@router.get("/analytics/founder", response_model=FounderIntelligenceResponse)
def get_founder_intelligence(
    db: Session = Depends(get_db),
    profile: str | None = Query(None),
) -> FounderIntelligenceResponse:
    """Return founder-focused analytics: funnel, TTFV, cost, errors, language."""

    now = datetime.now(timezone.utc)

    # ── 1. Activation Funnel ──
    invites_generated = db.query(sa_func.count(User.id)).scalar() or 0
    activated = (
        db.query(sa_func.count(User.id))
        .filter(User.status.in_([UserStatus.active, UserStatus.disabled]))
        .scalar()
    ) or 0

    # Users who have made at least one request.
    _frq = db.query(
        RequestLog.user_id,
        sa_func.min(RequestLog.created_at).label("first_req"),
    )
    _frq = _profile_filter(_frq, profile)
    first_req_subq = _frq.group_by(RequestLog.user_id).subquery()
    made_first_request = (
        db.query(sa_func.count(first_req_subq.c.user_id)).scalar()
    ) or 0

    # Users with request activity spanning >7 days and >30 days from first req.
    # "Active after N days" = user's last request is >= N days after first request.
    _usq = db.query(
        RequestLog.user_id,
        sa_func.min(RequestLog.created_at).label("first_req"),
        sa_func.max(RequestLog.created_at).label("last_req"),
    )
    _usq = _profile_filter(_usq, profile)
    user_span_subq = _usq.group_by(RequestLog.user_id).subquery()

    from sqlalchemy import extract

    active_after_7d = (
        db.query(sa_func.count(user_span_subq.c.user_id))
        .filter(
            sa_func.extract(
                "epoch",
                user_span_subq.c.last_req - user_span_subq.c.first_req,
            )
            >= 7 * 86400
        )
        .scalar()
    ) or 0

    active_after_30d = (
        db.query(sa_func.count(user_span_subq.c.user_id))
        .filter(
            sa_func.extract(
                "epoch",
                user_span_subq.c.last_req - user_span_subq.c.first_req,
            )
            >= 30 * 86400
        )
        .scalar()
    ) or 0

    activation_funnel = ActivationFunnel(
        invites_generated=invites_generated,
        activated=activated,
        made_first_request=made_first_request,
        active_after_7d=active_after_7d,
        active_after_30d=active_after_30d,
        activated_pct=round(activated / invites_generated * 100, 1) if invites_generated > 0 else 0.0,
        first_request_pct=round(made_first_request / activated * 100, 1) if activated > 0 else 0.0,
        active_7d_pct=round(active_after_7d / made_first_request * 100, 1) if made_first_request > 0 else 0.0,
        active_30d_pct=round(active_after_30d / made_first_request * 100, 1) if made_first_request > 0 else 0.0,
    )

    # ── 2. Time to First Value ──
    # Time from activation to first successful request per user.
    _ttfv_q = (
        db.query(
            User.id.label("user_id"),
            User.activated_at,
            sa_func.min(RequestLog.created_at).label("first_success"),
        )
        .join(RequestLog, User.id == RequestLog.user_id)
        .filter(
            User.activated_at.isnot(None),
            RequestLog.success.is_(True),
        )
    )
    _ttfv_q = _profile_filter(_ttfv_q, profile)
    ttfv_subq = _ttfv_q.group_by(User.id, User.activated_at).subquery()

    ttfv_seconds_col = sa_func.extract(
        "epoch",
        ttfv_subq.c.first_success - ttfv_subq.c.activated_at,
    )

    ttfv_stats = db.query(
        sa_func.avg(ttfv_seconds_col),
        sa_func.percentile_cont(0.5).within_group(ttfv_seconds_col),
        sa_func.min(ttfv_seconds_col),
        sa_func.max(ttfv_seconds_col),
        sa_func.count(ttfv_subq.c.user_id),
    ).filter(ttfv_seconds_col >= 0).one()

    time_to_first_value = TimeToFirstValue(
        average_seconds=round(ttfv_stats[0], 1) if ttfv_stats[0] is not None else None,
        median_seconds=round(ttfv_stats[1], 1) if ttfv_stats[1] is not None else None,
        fastest_seconds=round(ttfv_stats[2], 1) if ttfv_stats[2] is not None else None,
        slowest_seconds=round(ttfv_stats[3], 1) if ttfv_stats[3] is not None else None,
        sample_size=ttfv_stats[4] or 0,
    )

    # ── 3. Cost Per Active User ──
    def _windowed_cost(since: datetime | None) -> tuple[float | None, int]:
        """Return (cost, active_user_count) for requests since `since`."""
        q = db.query(
            sa_func.count(sa_func.distinct(RequestLog.user_id)),
            sa_func.sum(_cost_sql_expr()),
        ).filter(RequestLog.prompt_tokens.isnot(None))
        q = _profile_filter(q, profile)
        if since:
            q = q.filter(RequestLog.created_at >= since)
        row = q.one()
        active_count = row[0] or 0
        cost = row[1]
        if cost is not None and active_count > 0:
            return round(cost / active_count, 4), active_count
        return None, active_count

    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    seven_days_ago = now - timedelta(days=7)

    cost_today, au_today = _windowed_cost(today_start)
    cost_7d, au_7d = _windowed_cost(seven_days_ago)
    cost_all, au_all = _windowed_cost(None)

    cost_per_active_user = CostPerActiveUser(
        today=cost_today,
        last_7d=cost_7d,
        all_time=cost_all,
        active_users_today=au_today,
        active_users_7d=au_7d,
        active_users_all_time=au_all,
    )

    # ── 4. Slowest Requests ──
    _slow_q = (
        db.query(
            User.name,
            User.email,
            RequestLog.mode,
            RequestLog.latency_ms,
            RequestLog.created_at,
            RequestLog.ai_provider,
            RequestLog.ai_model,
            RequestLog.success,
        )
        .join(User, User.id == RequestLog.user_id)
    )
    _slow_q = _profile_filter(_slow_q, profile)
    slowest_rows = _slow_q.order_by(RequestLog.latency_ms.desc()).limit(20).all()

    slowest_requests = [
        SlowestRequest(
            user_name=name,
            user_email=email,
            mode=mode,
            latency_ms=lat,
            created_at=cat,
            ai_provider=prov,
            ai_model=model,
            success=succ,
        )
        for name, email, mode, lat, cat, prov, model, succ in slowest_rows
    ]

    # ── 5. Error Trends ──
    day = cast(RequestLog.created_at, Date).label("day")
    _err_q = db.query(
        day,
        RequestLog.error_type,
        sa_func.count(RequestLog.id),
    ).filter(
        RequestLog.success.is_(False),
        RequestLog.error_type.isnot(None),
    )
    _err_q = _profile_filter(_err_q, profile)
    error_trend_rows = _err_q.group_by(day, RequestLog.error_type).order_by(day).all()

    error_trends = [
        ErrorTrendDay(date=str(d), error_type=et, count=c)
        for d, et, c in error_trend_rows
    ]

    # ── 6. Language Analytics ──
    _lang_q = db.query(
        RequestLog.language,
        sa_func.count(RequestLog.id),
        sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
        sa_func.avg(RequestLog.latency_ms),
        sa_func.avg(RequestLog.total_tokens),
        sa_func.sum(_cost_sql_expr()),
    ).filter(RequestLog.language.isnot(None))
    _lang_q = _profile_filter(_lang_q, profile)
    lang_rows = (
        _lang_q.group_by(RequestLog.language)
        .order_by(sa_func.count(RequestLog.id).desc())
        .all()
    )

    language_analytics = [
        LanguageAnalyticsItem(
            language=lang,
            request_count=count,
            success_rate=round(sc / count * 100, 1) if count > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            avg_total_tokens=round(atot, 1) if atot is not None else None,
            estimated_cost_usd=round(est_cost, 4) if est_cost is not None else None,
        )
        for lang, count, sc, alat, atot, est_cost in lang_rows
    ]

    return FounderIntelligenceResponse(
        activation_funnel=activation_funnel,
        time_to_first_value=time_to_first_value,
        cost_per_active_user=cost_per_active_user,
        slowest_requests=slowest_requests,
        error_trends=error_trends,
        language_analytics=language_analytics,
    )


