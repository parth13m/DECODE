"""Daily aggregation service for the analytics v2 platform.

Computes ``daily_summaries`` rows from ``ai_requests`` (or ``request_logs``
for historical backfill).  Aggregation is idempotent — re-running for a
date replaces existing rows via upsert on the
``(summary_date, dimension, dimension_value)`` unique constraint.

Usage::

    from app.aggregation_service import aggregate_date, backfill_range

    # Aggregate yesterday
    aggregate_date(date.today() - timedelta(days=1))

    # Backfill all history
    backfill_range()
"""

import logging
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import Date, case, cast, func as sa_func, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from app.database import SessionLocal
from app.models.ai_request import AIRequest
from app.models.daily_summary import DailySummary
from app.models.request_log import RequestLog
from app.pricing import MODEL_PRICING_PER_MTOK

logger = logging.getLogger(__name__)

# Dimensions to aggregate
DIMENSIONS = ["overall", "mode", "request_type", "provider", "model", "user"]


# ---------------------------------------------------------------------------
# Core aggregation
# ---------------------------------------------------------------------------

def aggregate_date(target_date: date, *, use_legacy: bool = False) -> int:
    """Aggregate all dimensions for a single date.

    Args:
        target_date: The date to aggregate.
        use_legacy: If True, read from ``request_logs`` instead of ``ai_requests``.

    Returns:
        Number of summary rows written.
    """
    db = SessionLocal()
    try:
        total_rows = 0
        for dimension in DIMENSIONS:
            rows = _aggregate_dimension(db, target_date, dimension, use_legacy=use_legacy)
            total_rows += rows

        logger.info(
            "AGGREGATION date=%s rows=%d source=%s",
            target_date, total_rows, "legacy" if use_legacy else "v2",
        )
        return total_rows
    finally:
        db.close()


def backfill_range(
    start_date: date | None = None,
    end_date: date | None = None,
) -> int:
    """Backfill daily summaries from legacy ``request_logs``.

    If no range is specified, backfills from the earliest request_log
    to yesterday.

    Returns:
        Total number of summary rows written.
    """
    db = SessionLocal()
    try:
        if start_date is None:
            earliest = db.query(
                sa_func.min(cast(RequestLog.created_at, Date))
            ).scalar()
            if earliest is None:
                logger.info("BACKFILL no request_logs found, nothing to backfill")
                return 0
            start_date = earliest

        if end_date is None:
            end_date = date.today() - timedelta(days=1)

        if start_date > end_date:
            return 0
    finally:
        db.close()

    total_rows = 0
    current = start_date
    while current <= end_date:
        rows = aggregate_date(current, use_legacy=True)
        total_rows += rows
        current += timedelta(days=1)

    logger.info(
        "BACKFILL complete start=%s end=%s total_rows=%d",
        start_date, end_date, total_rows,
    )
    return total_rows


# ---------------------------------------------------------------------------
# Dimension aggregation
# ---------------------------------------------------------------------------

def _aggregate_dimension(
    db: Session,
    target_date: date,
    dimension: str,
    *,
    use_legacy: bool = False,
) -> int:
    """Aggregate one dimension for a single date and upsert into daily_summaries."""
    if use_legacy:
        groups = _query_legacy_groups(db, target_date, dimension)
    else:
        groups = _query_v2_groups(db, target_date, dimension)

    if not groups:
        return 0

    rows_written = 0
    for dim_value, stats in groups.items():
        _upsert_summary(db, target_date, dimension, dim_value, stats)
        rows_written += 1

    return rows_written


def _query_v2_groups(
    db: Session,
    target_date: date,
    dimension: str,
) -> dict[str, dict]:
    """Query ai_requests for a single date, grouped by dimension."""
    date_filter = cast(AIRequest.created_at, Date) == target_date

    group_col = _get_v2_group_column(dimension)

    query = db.query(
        group_col.label("dim_value"),
        sa_func.count().label("total"),
        sa_func.count().filter(AIRequest.success.is_(True)).label("success"),
        sa_func.count().filter(AIRequest.success.is_(False)).label("failed"),
        sa_func.count(sa_func.distinct(AIRequest.user_id)).label("unique_users"),
        sa_func.avg(AIRequest.latency_ms).label("avg_latency"),
        sa_func.percentile_cont(0.5).within_group(AIRequest.latency_ms).label("p50"),
        sa_func.percentile_cont(0.95).within_group(AIRequest.latency_ms).label("p95"),
        sa_func.percentile_cont(0.99).within_group(AIRequest.latency_ms).label("p99"),
        sa_func.sum(AIRequest.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(AIRequest.completion_tokens).label("completion_tokens"),
        sa_func.sum(AIRequest.total_tokens).label("total_tokens"),
        sa_func.sum(AIRequest.estimated_cost_usd).label("total_cost"),
    ).filter(date_filter)

    if dimension != "overall":
        query = query.group_by(group_col)

    results = {}
    for row in query.all():
        dim_value = str(row.dim_value) if row.dim_value else "unknown"
        results[dim_value] = {
            "total_requests": row.total or 0,
            "successful_requests": row.success or 0,
            "failed_requests": row.failed or 0,
            "unique_users": row.unique_users or 0,
            "avg_latency_ms": float(row.avg_latency) if row.avg_latency else None,
            "p50_latency_ms": float(row.p50) if row.p50 else None,
            "p95_latency_ms": float(row.p95) if row.p95 else None,
            "p99_latency_ms": float(row.p99) if row.p99 else None,
            "total_prompt_tokens": row.prompt_tokens,
            "total_completion_tokens": row.completion_tokens,
            "total_tokens": row.total_tokens,
            "total_estimated_cost_usd": float(row.total_cost) if row.total_cost else None,
        }

    return results


def _query_legacy_groups(
    db: Session,
    target_date: date,
    dimension: str,
) -> dict[str, dict]:
    """Query request_logs for a single date, grouped by dimension.

    For backfill: decomposes compound mode strings and estimates cost
    from the pricing table.
    """
    date_filter = cast(RequestLog.created_at, Date) == target_date

    group_col = _get_legacy_group_column(dimension)

    # Build cost expression for legacy data
    cost_expr = _legacy_cost_expr()

    query = db.query(
        group_col.label("dim_value"),
        sa_func.count().label("total"),
        sa_func.count().filter(RequestLog.success.is_(True)).label("success"),
        sa_func.count().filter(RequestLog.success.is_(False)).label("failed"),
        sa_func.count(sa_func.distinct(RequestLog.user_id)).label("unique_users"),
        sa_func.avg(RequestLog.latency_ms).label("avg_latency"),
        sa_func.percentile_cont(0.5).within_group(RequestLog.latency_ms).label("p50"),
        sa_func.percentile_cont(0.95).within_group(RequestLog.latency_ms).label("p95"),
        sa_func.percentile_cont(0.99).within_group(RequestLog.latency_ms).label("p99"),
        sa_func.sum(RequestLog.prompt_tokens).label("prompt_tokens"),
        sa_func.sum(RequestLog.completion_tokens).label("completion_tokens"),
        sa_func.sum(RequestLog.total_tokens).label("total_tokens"),
        sa_func.sum(cost_expr).label("total_cost"),
    ).filter(date_filter)

    if dimension != "overall":
        query = query.group_by(group_col)

    results = {}
    for row in query.all():
        dim_value = str(row.dim_value) if row.dim_value else "unknown"
        results[dim_value] = {
            "total_requests": row.total or 0,
            "successful_requests": row.success or 0,
            "failed_requests": row.failed or 0,
            "unique_users": row.unique_users or 0,
            "avg_latency_ms": float(row.avg_latency) if row.avg_latency else None,
            "p50_latency_ms": float(row.p50) if row.p50 else None,
            "p95_latency_ms": float(row.p95) if row.p95 else None,
            "p99_latency_ms": float(row.p99) if row.p99 else None,
            "total_prompt_tokens": row.prompt_tokens,
            "total_completion_tokens": row.completion_tokens,
            "total_tokens": row.total_tokens,
            "total_estimated_cost_usd": float(row.total_cost) if row.total_cost else None,
        }

    return results


# ---------------------------------------------------------------------------
# Group column resolution
# ---------------------------------------------------------------------------

def _get_v2_group_column(dimension: str):
    """Return the SQLAlchemy column to group by for a v2 dimension."""
    if dimension == "overall":
        return sa_func.literal("all")
    elif dimension == "mode":
        return sa_func.coalesce(AIRequest.origin_mode, "unknown")
    elif dimension == "request_type":
        return AIRequest.request_type
    elif dimension == "provider":
        return AIRequest.ai_provider
    elif dimension == "model":
        return AIRequest.ai_model
    elif dimension == "user":
        return AIRequest.user_id
    else:
        raise ValueError(f"Unknown dimension: {dimension}")


def _get_legacy_group_column(dimension: str):
    """Return the SQLAlchemy column/expression to group by for legacy data.

    For 'mode' and 'request_type', decomposes the compound mode string.
    """
    from app.dual_write_service import _COMPOUND_MODE_MAP

    if dimension == "overall":
        return sa_func.literal("all")
    elif dimension == "mode":
        # Extract origin_mode from compound mode string
        whens = [
            (RequestLog.mode == compound, origin)
            for compound, (origin, _) in _COMPOUND_MODE_MAP.items()
        ]
        return case(*whens, else_=sa_func.coalesce(RequestLog.mode, "unknown"))
    elif dimension == "request_type":
        # Extract request_type from compound mode string
        whens = [
            (RequestLog.mode == compound, req_type)
            for compound, (_, req_type) in _COMPOUND_MODE_MAP.items()
        ]
        return case(*whens, else_="unknown")
    elif dimension == "provider":
        return sa_func.coalesce(RequestLog.ai_provider, "unknown")
    elif dimension == "model":
        return sa_func.coalesce(RequestLog.ai_model, "unknown")
    elif dimension == "user":
        return RequestLog.user_id
    else:
        raise ValueError(f"Unknown dimension: {dimension}")


def _legacy_cost_expr():
    """SQL CASE expression for per-row cost estimation on request_logs."""
    whens = [
        (
            RequestLog.ai_model == model,
            (RequestLog.prompt_tokens * input_rate
             + RequestLog.completion_tokens * output_rate) / 1_000_000,
        )
        for model, (input_rate, output_rate) in MODEL_PRICING_PER_MTOK.items()
    ]
    return case(*whens, else_=None)


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------

def _upsert_summary(
    db: Session,
    target_date: date,
    dimension: str,
    dimension_value: str,
    stats: dict,
) -> None:
    """Insert or update a daily_summaries row."""
    values = {
        "summary_date": target_date,
        "dimension": dimension,
        "dimension_value": dimension_value,
        **stats,
    }

    stmt = pg_insert(DailySummary).values(**values)
    stmt = stmt.on_conflict_do_update(
        constraint="uq_daily_summary_date_dim",
        set_={
            "total_requests": stmt.excluded.total_requests,
            "successful_requests": stmt.excluded.successful_requests,
            "failed_requests": stmt.excluded.failed_requests,
            "unique_users": stmt.excluded.unique_users,
            "avg_latency_ms": stmt.excluded.avg_latency_ms,
            "p50_latency_ms": stmt.excluded.p50_latency_ms,
            "p95_latency_ms": stmt.excluded.p95_latency_ms,
            "p99_latency_ms": stmt.excluded.p99_latency_ms,
            "total_prompt_tokens": stmt.excluded.total_prompt_tokens,
            "total_completion_tokens": stmt.excluded.total_completion_tokens,
            "total_tokens": stmt.excluded.total_tokens,
            "total_estimated_cost_usd": stmt.excluded.total_estimated_cost_usd,
            "updated_at": sa_func.now(),
        },
    )
    db.execute(stmt)
    db.commit()
