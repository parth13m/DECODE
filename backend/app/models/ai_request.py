from datetime import datetime

from sqlalchemy import Boolean, DateTime, Float, Integer, String, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class AIRequest(Base):
    """Dedicated AI request telemetry.

    Stores one row per AI provider call with orthogonal dimensions
    (``origin_mode`` and ``request_type`` as separate fields instead of
    compound mode strings).  Pre-computes ``estimated_cost_usd`` at
    write time so dashboards never need to JOIN a pricing table.

    Coexists with the legacy ``request_logs`` table via dual-write.
    """

    __tablename__ = "ai_requests"

    id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        primary_key=True,
        server_default=func.gen_random_uuid(),
    )
    user_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        nullable=False,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )

    # --- Request classification (orthogonal dimensions) ---
    origin_mode: Mapped[str | None] = mapped_column(String(32), index=True)
    request_type: Mapped[str] = mapped_column(String(32), nullable=False, index=True)
    explanation_profile: Mapped[str | None] = mapped_column(String(16))
    language: Mapped[str | None] = mapped_column(String(32))

    # --- AI provider details ---
    ai_provider: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    ai_model: Mapped[str] = mapped_column(String(128), nullable=False, index=True)

    # --- Outcome ---
    success: Mapped[bool] = mapped_column(Boolean, nullable=False)
    error_type: Mapped[str | None] = mapped_column(String(64))
    latency_ms: Mapped[int] = mapped_column(Integer, nullable=False)

    # --- Token usage ---
    prompt_tokens: Mapped[int | None] = mapped_column(Integer)
    completion_tokens: Mapped[int | None] = mapped_column(Integer)
    total_tokens: Mapped[int | None] = mapped_column(Integer)
    prompt_character_count: Mapped[int | None] = mapped_column(Integer)

    # --- Pre-computed cost ---
    estimated_cost_usd: Mapped[float | None] = mapped_column(Float)

    # --- Correlation ---
    interaction_id: Mapped[str | None] = mapped_column(
        UUID(as_uuid=False),
        index=True,
    )

    # --- Legacy linkage ---
    legacy_request_log_id: Mapped[str | None] = mapped_column(
        UUID(as_uuid=False),
    )

    def __repr__(self) -> str:
        return (
            f"<AIRequest user={self.user_id} type={self.request_type} "
            f"mode={self.origin_mode} model={self.ai_model} "
            f"{'OK' if self.success else 'FAIL'} {self.latency_ms}ms>"
        )
