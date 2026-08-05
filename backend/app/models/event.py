from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Event(Base):
    """Universal analytics event log.

    Captures all user-facing and system events with a consistent schema.
    Coexists with the legacy ``analytics_events`` table via dual-write.
    """

    __tablename__ = "events"

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
    event_type: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    origin_mode: Mapped[str | None] = mapped_column(String(32), index=True)
    request_type: Mapped[str | None] = mapped_column(String(32), index=True)
    interaction_id: Mapped[str | None] = mapped_column(
        UUID(as_uuid=False),
        index=True,
    )
    metadata_: Mapped[dict | None] = mapped_column("metadata", JSONB)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )

    def __repr__(self) -> str:
        return f"<Event user={self.user_id} type={self.event_type} mode={self.origin_mode}>"
