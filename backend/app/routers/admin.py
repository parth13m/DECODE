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


class TierAnalytics(BaseModel):
    context_tier: str
    request_count: int
    pct_of_total: float
    success_count: int
    failure_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_prompt_tokens: float | None
    avg_completion_tokens: float | None
    avg_total_tokens: float | None
    avg_prompt_character_count: float | None
    estimated_cost_usd: float | None


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
    analytics_coverage: float | None
    estimated_total_cost_usd: float | None
    tier_analytics: list[TierAnalytics]
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
            sa_func.sum(RequestLog.prompt_tokens).label("sum_prompt"),
            sa_func.sum(RequestLog.completion_tokens).label("sum_completion"),
        )
        .outerjoin(RequestLog, join_cond)
        .group_by(User.id)
        .order_by(User.created_at.desc())
        .all()
    )

    # Resolve the current model for cost estimation.
    from app.config import settings as _settings
    current_model = _settings.AI_MODEL

    results: list[UserResponse] = []
    for u, total, successful, selection, screenshot, session, last_active, active_days, sum_p, sum_c in rows:
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
                estimated_cost_usd=_estimate_cost(current_model, sum_p, sum_c),
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

    # Cascade: delete all request logs for this user first.
    db.query(RequestLog).filter(RequestLog.user_id == user_id).delete()
    db.delete(user)
    db.flush()


# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------
# Approximate pricing per million tokens (USD) as of early 2025.
# Key = ai_model value stored in request_logs.
# Value = (input_usd_per_mtok, output_usd_per_mtok).
# Update when providers change rates or new models are added.
_MODEL_PRICING_PER_MTOK: dict[str, tuple[float, float]] = {
    "claude-haiku-4-5-20251001": (0.80, 4.00),
    "llama-3.3-70b-versatile": (0.59, 0.79),
}


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
        return None
    input_rate, output_rate = pricing
    return round(
        (sum_prompt_tokens * input_rate + sum_completion_tokens * output_rate)
        / 1_000_000,
        4,
    )


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
        sa_func.sum(RequestLog.prompt_tokens),
        sa_func.sum(RequestLog.completion_tokens),
    ).filter(
        RequestLog.mode.in_(["selection_followup", "session_followup", "screenshot_followup"]),
        RequestLog.prompt_tokens.isnot(None),
    )
    followup_tok_stats = _profile_filter(followup_tok_q, profile).one()
    followup_avg_prompt_tokens = round(followup_tok_stats[0], 1) if followup_tok_stats[0] is not None else None
    followup_avg_completion_tokens = round(followup_tok_stats[1], 1) if followup_tok_stats[1] is not None else None
    followup_avg_total_tokens = round(followup_tok_stats[2], 1) if followup_tok_stats[2] is not None else None

    from app.config import settings as _followup_settings
    followup_estimated_cost = _estimate_cost(
        _followup_settings.AI_MODEL,
        followup_tok_stats[3],
        followup_tok_stats[4],
    )

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

    # ── Per-tier performance ──
    tier_q = (
        db.query(
            RequestLog.context_tier,
            sa_func.count(RequestLog.id),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.count(case((RequestLog.success.is_(False), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
            sa_func.avg(RequestLog.prompt_tokens),
            sa_func.avg(RequestLog.completion_tokens),
            sa_func.avg(RequestLog.total_tokens),
            sa_func.avg(RequestLog.prompt_character_count),
        )
        .filter(RequestLog.context_tier.isnot(None))
    )
    tier_rows = (
        _profile_filter(tier_q, profile)
        .group_by(RequestLog.context_tier)
        .order_by(RequestLog.context_tier)
        .all()
    )

    # Tier cost estimation: GROUP BY (ai_model, context_tier) for accurate
    # per-model costing, then aggregate by tier.
    tier_cost_q = (
        db.query(
            RequestLog.ai_model,
            RequestLog.context_tier,
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
        )
        .filter(RequestLog.prompt_tokens.isnot(None))
        .filter(RequestLog.context_tier.isnot(None))
    )
    tier_cost_rows = (
        _profile_filter(tier_cost_q, profile)
        .group_by(RequestLog.ai_model, RequestLog.context_tier)
        .all()
    )
    tier_cost_map: dict[str, float] = {}
    estimated_total_cost = 0.0
    has_any_cost = False
    for model, tier, sp, sc in tier_cost_rows:
        cost = _estimate_cost(model, sp, sc)
        if cost is not None:
            has_any_cost = True
            estimated_total_cost += cost
            tier_cost_map[tier] = tier_cost_map.get(tier, 0.0) + cost

    tier_total_tracked = sum(row[1] for row in tier_rows)
    tier_analytics = [
        TierAnalytics(
            context_tier=tier,
            request_count=count,
            pct_of_total=round(count / tier_total_tracked * 100, 1) if tier_total_tracked > 0 else 0.0,
            success_count=sc,
            failure_count=fc,
            success_rate=round(sc / count * 100, 1) if count > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            avg_prompt_tokens=round(apt, 1) if apt is not None else None,
            avg_completion_tokens=round(act, 1) if act is not None else None,
            avg_total_tokens=round(att, 1) if att is not None else None,
            avg_prompt_character_count=round(apc, 1) if apc is not None else None,
            estimated_cost_usd=round(tier_cost_map.get(tier, 0.0), 4) if tier in tier_cost_map else None,
        )
        for tier, count, sc, fc, alat, apt, act, att, apc in tier_rows
    ]

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

    # Also include cost from non-tier rows (e.g. selection/screenshot mode)
    # in the total.  The tier_cost_rows only cover context_tier IS NOT NULL.
    # Recompute total from provider_rows which covers everything.
    estimated_total_cost = 0.0
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
        avg_prompt_tokens=avg_prompt_tokens,
        avg_completion_tokens=avg_completion_tokens,
        avg_total_tokens=avg_total_tokens,
        analytics_coverage=analytics_coverage,
        estimated_total_cost_usd=round(estimated_total_cost, 4) if has_any_cost else None,
        tier_analytics=tier_analytics,
        provider_analytics=provider_analytics,
        profile_analytics=profile_analytics,
        error_breakdown=error_breakdown,
    )


# ---------------------------------------------------------------------------
# Timeseries analytics
# ---------------------------------------------------------------------------


class DailyRecord(BaseModel):
    date: str
    requests: int
    successful: int
    failed: int
    active_users: int
    selection_requests: int
    screenshot_requests: int
    session_requests: int
    avg_latency_ms: float | None
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    estimated_cost_usd: float | None


@router.get("/analytics/timeseries", response_model=list[DailyRecord])
def get_timeseries(
    db: Session = Depends(get_db),
    profile: str | None = Query(None),
) -> list[DailyRecord]:
    """Return per-day analytics for the global dashboard charts."""
    day = cast(RequestLog.created_at, Date).label("day")

    ts_q = db.query(
        day,
        sa_func.count(RequestLog.id),
        sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
        sa_func.count(case((RequestLog.success.is_(False), RequestLog.id))),
        sa_func.count(sa_func.distinct(RequestLog.user_id)),
        sa_func.count(case((RequestLog.mode == "selection", RequestLog.id))),
        sa_func.count(case((RequestLog.mode == "screenshot", RequestLog.id))),
        sa_func.count(case((RequestLog.mode == "session", RequestLog.id))),
        sa_func.avg(RequestLog.latency_ms),
        sa_func.sum(RequestLog.prompt_tokens),
        sa_func.sum(RequestLog.completion_tokens),
        sa_func.sum(RequestLog.total_tokens),
    )
    rows = (
        _profile_filter(ts_q, profile)
        .group_by(day)
        .order_by(day)
        .all()
    )

    from app.config import settings as _settings
    current_model = _settings.AI_MODEL

    return [
        DailyRecord(
            date=str(d),
            requests=total,
            successful=succ,
            failed=fail,
            active_users=au,
            selection_requests=sel,
            screenshot_requests=scr,
            session_requests=ses,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            prompt_tokens=sp,
            completion_tokens=sc,
            total_tokens=st,
            estimated_cost_usd=_estimate_cost(current_model, sp, sc),
        )
        for d, total, succ, fail, au, sel, scr, ses, alat, sp, sc, st in rows
    ]


# ---------------------------------------------------------------------------
# Mode analytics
# ---------------------------------------------------------------------------


class ModeAnalyticsItem(BaseModel):
    mode: str
    request_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_prompt_tokens: float | None
    avg_completion_tokens: float | None
    avg_total_tokens: float | None
    estimated_cost_usd: float | None


@router.get("/analytics/modes", response_model=list[ModeAnalyticsItem])
def get_mode_analytics(
    db: Session = Depends(get_db),
    profile: str | None = Query(None),
) -> list[ModeAnalyticsItem]:
    """Return per-mode analytics with full metrics."""
    mode_q = (
        db.query(
            RequestLog.mode,
            sa_func.count(RequestLog.id),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
            sa_func.avg(RequestLog.prompt_tokens),
            sa_func.avg(RequestLog.completion_tokens),
            sa_func.avg(RequestLog.total_tokens),
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
        )
        .filter(RequestLog.mode.isnot(None))
    )
    rows = (
        _profile_filter(mode_q, profile)
        .group_by(RequestLog.mode)
        .order_by(sa_func.count(RequestLog.id).desc())
        .all()
    )

    from app.config import settings as _settings
    current_model = _settings.AI_MODEL

    return [
        ModeAnalyticsItem(
            mode=mode,
            request_count=count,
            success_rate=round(sc / count * 100, 1) if count > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
            avg_prompt_tokens=round(apt, 1) if apt is not None else None,
            avg_completion_tokens=round(act, 1) if act is not None else None,
            avg_total_tokens=round(att, 1) if att is not None else None,
            estimated_cost_usd=_estimate_cost(current_model, sp, scp),
        )
        for mode, count, sc, alat, apt, act, att, sp, scp in rows
    ]


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


class UserTierBreakdown(BaseModel):
    tier1: int
    tier2: int
    tier2_5: int
    tier3: int


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
    tier1: int
    tier2: int
    tier2_5: int
    tier3: int
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


class UserDetailResponse(BaseModel):
    profile: UserProfile
    mode_breakdown: UserModeBreakdown
    improve_breakdown: UserImproveBreakdown = UserImproveBreakdown()
    followup_breakdown: UserFollowUpBreakdown = UserFollowUpBreakdown()
    tier_breakdown: UserTierBreakdown
    token_breakdown: UserTokenBreakdown
    cost_breakdown: UserCostBreakdown
    daily: list[UserDailyRecord]


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
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
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

    from app.config import settings as _settings
    estimated_cost = _estimate_cost(
        _settings.AI_MODEL,
        followup_stats[4],
        followup_stats[5],
    )

    return UserFollowUpBreakdown(
        followup_count=followup_count,
        followup_rate=followup_rate,
        avg_prompt_tokens=round(followup_stats[1], 1) if followup_stats[1] is not None else None,
        avg_completion_tokens=round(followup_stats[2], 1) if followup_stats[2] is not None else None,
        avg_total_tokens=round(followup_stats[3], 1) if followup_stats[3] is not None else None,
        estimated_cost_usd=estimated_cost,
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

    # ── Tier breakdown (Session mode only) ──
    tier_rows = (
        _user_log_q(
            db.query(RequestLog.context_tier, sa_func.count(RequestLog.id))
            .filter(RequestLog.context_tier.isnot(None))
        )
        .group_by(RequestLog.context_tier)
        .all()
    )
    tier_map = {t: c for t, c in tier_rows}

    # ── Token breakdown ──
    token_stats = _user_log_q(db.query(
        sa_func.avg(RequestLog.prompt_tokens),
        sa_func.avg(RequestLog.completion_tokens),
        sa_func.avg(RequestLog.total_tokens),
    ).filter(RequestLog.prompt_tokens.isnot(None))).one()

    # ── Cost breakdown ──
    cost_stats = _user_log_q(db.query(
        sa_func.sum(RequestLog.prompt_tokens),
        sa_func.sum(RequestLog.completion_tokens),
        sa_func.count(RequestLog.id),
    ).filter(RequestLog.prompt_tokens.isnot(None))).one()

    from app.config import settings as _settings
    current_model = _settings.AI_MODEL
    total_cost = _estimate_cost(current_model, cost_stats[0], cost_stats[1])
    total_reqs = cost_stats[2] or 0

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
            sa_func.count(case((RequestLog.context_tier == "tier1", RequestLog.id))),
            sa_func.count(case((RequestLog.context_tier == "tier2", RequestLog.id))),
            sa_func.count(case((RequestLog.context_tier == "tier2.5", RequestLog.id))),
            sa_func.count(case((RequestLog.context_tier == "tier3", RequestLog.id))),
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
            sa_func.sum(RequestLog.total_tokens),
            sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
            sa_func.avg(RequestLog.latency_ms),
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
            tier1=t1,
            tier2=t2,
            tier2_5=t25,
            tier3=t3,
            prompt_tokens=sp,
            completion_tokens=sc,
            total_tokens=st,
            estimated_cost=_estimate_cost(current_model, sp, sc),
            success_rate=round(succ / total * 100, 1) if total > 0 else 0.0,
            avg_latency_ms=round(alat, 1) if alat is not None else None,
        )
        for d, total, sel, scr, ses, t1, t2, t25, t3, sp, sc, st, succ, alat in daily_rows
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
        tier_breakdown=UserTierBreakdown(
            tier1=tier_map.get("tier1", 0),
            tier2=tier_map.get("tier2", 0),
            tier2_5=tier_map.get("tier2.5", 0),
            tier3=tier_map.get("tier3", 0),
        ),
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

    from app.config import settings as _settings
    current_model = _settings.AI_MODEL
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
            sa_func.sum(RequestLog.prompt_tokens),
            sa_func.sum(RequestLog.completion_tokens),
        ).filter(RequestLog.prompt_tokens.isnot(None))
        q = _profile_filter(q, profile)
        if since:
            q = q.filter(RequestLog.created_at >= since)
        row = q.one()
        active_count = row[0] or 0
        cost = _estimate_cost(current_model, row[1], row[2])
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
        sa_func.sum(RequestLog.prompt_tokens),
        sa_func.sum(RequestLog.completion_tokens),
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
            estimated_cost_usd=_estimate_cost(current_model, sp, scp),
        )
        for lang, count, sc, alat, atot, sp, scp in lang_rows
    ]

    return FounderIntelligenceResponse(
        activation_funnel=activation_funnel,
        time_to_first_value=time_to_first_value,
        cost_per_active_user=cost_per_active_user,
        slowest_requests=slowest_requests,
        error_trends=error_trends,
        language_analytics=language_analytics,
    )


# ── Profile Comparison ──────────────────────────────────────────────


class ProfileSummary(BaseModel):
    profile: str
    request_count: int
    success_rate: float
    avg_latency_ms: float | None
    avg_total_tokens: float | None
    estimated_cost_usd: float | None


class ProfileUserBreakdown(BaseModel):
    user_name: str | None
    user_email: str
    general_requests: int
    dsa_requests: int
    total_requests: int


class ProfileComparisonResponse(BaseModel):
    product_mix: dict  # {general_count, dsa_count, general_pct, dsa_pct, total}
    profiles: list[ProfileSummary]
    user_breakdown: list[ProfileUserBreakdown]


@router.get("/analytics/profile-comparison", response_model=ProfileComparisonResponse)
def get_profile_comparison(
    db: Session = Depends(get_db),
) -> ProfileComparisonResponse:
    """Side-by-side General vs DSA metrics + user-level breakdown."""

    from app.config import settings as _settings
    current_model = _settings.AI_MODEL

    # ── Product Mix ──
    general_count = (
        db.query(sa_func.count(RequestLog.id))
        .filter(RequestLog.explanation_profile == "general")
        .scalar()
    ) or 0
    dsa_count = (
        db.query(sa_func.count(RequestLog.id))
        .filter(RequestLog.explanation_profile == "dsa")
        .scalar()
    ) or 0
    total = general_count + dsa_count
    product_mix = {
        "general_count": general_count,
        "dsa_count": dsa_count,
        "general_pct": round(general_count / total * 100, 1) if total > 0 else 0.0,
        "dsa_pct": round(dsa_count / total * 100, 1) if total > 0 else 0.0,
        "total": total,
    }

    # ── Per-profile summary ──
    profiles: list[ProfileSummary] = []
    for prof in ("general", "dsa"):
        row = (
            db.query(
                sa_func.count(RequestLog.id),
                sa_func.count(case((RequestLog.success.is_(True), RequestLog.id))),
                sa_func.avg(RequestLog.latency_ms),
                sa_func.avg(RequestLog.total_tokens),
                sa_func.sum(RequestLog.prompt_tokens),
                sa_func.sum(RequestLog.completion_tokens),
            )
            .filter(RequestLog.explanation_profile == prof)
            .one()
        )
        cnt = row[0] or 0
        profiles.append(ProfileSummary(
            profile=prof,
            request_count=cnt,
            success_rate=round(row[1] / cnt * 100, 1) if cnt > 0 else 0.0,
            avg_latency_ms=round(row[2], 1) if row[2] is not None else None,
            avg_total_tokens=round(row[3], 1) if row[3] is not None else None,
            estimated_cost_usd=_estimate_cost(current_model, row[4], row[5]),
        ))

    # ── User-level breakdown ──
    general_sub = (
        db.query(
            RequestLog.user_id,
            sa_func.count(RequestLog.id).label("cnt"),
        )
        .filter(RequestLog.explanation_profile == "general")
        .group_by(RequestLog.user_id)
        .subquery()
    )
    dsa_sub = (
        db.query(
            RequestLog.user_id,
            sa_func.count(RequestLog.id).label("cnt"),
        )
        .filter(RequestLog.explanation_profile == "dsa")
        .group_by(RequestLog.user_id)
        .subquery()
    )
    user_rows = (
        db.query(
            User.name,
            User.email,
            sa_func.coalesce(general_sub.c.cnt, 0),
            sa_func.coalesce(dsa_sub.c.cnt, 0),
        )
        .outerjoin(general_sub, User.id == general_sub.c.user_id)
        .outerjoin(dsa_sub, User.id == dsa_sub.c.user_id)
        .filter(User.status.in_([UserStatus.active, UserStatus.disabled]))
        .order_by(
            (sa_func.coalesce(general_sub.c.cnt, 0) + sa_func.coalesce(dsa_sub.c.cnt, 0)).desc()
        )
        .all()
    )

    user_breakdown = [
        ProfileUserBreakdown(
            user_name=name,
            user_email=email,
            general_requests=gc,
            dsa_requests=dc,
            total_requests=gc + dc,
        )
        for name, email, gc, dc in user_rows
    ]

    return ProfileComparisonResponse(
        product_mix=product_mix,
        profiles=profiles,
        user_breakdown=user_breakdown,
    )
