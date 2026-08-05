from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, Integer, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class DailySummary(Base):
    """Pre-aggregated daily metrics for dashboard performance.

    Each row represents one ``(summary_date, dimension, dimension_value)``
    combination.  Dimensions include ``overall``, ``mode``, ``request_type``,
    ``provider``, ``model``, ``user``, etc.  This avoids expensive
    full-table scans on ``ai_requests`` for dashboard queries.

    Aggregation is idempotent — re-running for a given date replaces
    existing rows (upsert on the unique constraint).
    """

    __tablename__ = "daily_summaries"

    id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        primary_key=True,
        server_default=func.gen_random_uuid(),
    )
    summary_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    dimension: Mapped[str] = mapped_column(String(32), nullable=False, index=True)
    dimension_value: Mapped[str] = mapped_column(String(128), nullable=False)

    # --- Counts ---
    total_requests: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    successful_requests: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    failed_requests: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    unique_users: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    # --- Latency ---
    avg_latency_ms: Mapped[float | None] = mapped_column(Float)
    p50_latency_ms: Mapped[float | None] = mapped_column(Float)
    p95_latency_ms: Mapped[float | None] = mapped_column(Float)
    p99_latency_ms: Mapped[float | None] = mapped_column(Float)

    # --- Tokens ---
    total_prompt_tokens: Mapped[int | None] = mapped_column(Integer)
    total_completion_tokens: Mapped[int | None] = mapped_column(Integer)
    total_tokens: Mapped[int | None] = mapped_column(Integer)

    # --- Cost ---
    total_estimated_cost_usd: Mapped[float | None] = mapped_column(Float)

    # --- Timestamps ---
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    # Unique constraint for idempotent upserts
    __table_args__ = (
        UniqueConstraint(
            "summary_date", "dimension", "dimension_value",
            name="uq_daily_summary_date_dim",
        ),
    )

    def __repr__(self) -> str:
        return (
            f"<DailySummary {self.summary_date} "
            f"{self.dimension}={self.dimension_value} "
            f"reqs={self.total_requests}>"
        )
