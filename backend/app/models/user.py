import enum
from datetime import datetime

from sqlalchemy import DateTime, Enum, String, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class UserStatus(str, enum.Enum):
    pending = "pending"
    active = "active"
    disabled = "disabled"


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        primary_key=True,
        server_default=func.gen_random_uuid(),
    )
    name: Mapped[str | None] = mapped_column(String(255))
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    invite_code: Mapped[str | None] = mapped_column(String(64), unique=True)
    status: Mapped[UserStatus] = mapped_column(
        Enum(UserStatus, name="user_status", create_constraint=True),
        nullable=False,
        server_default=UserStatus.pending.value,
    )
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
    token_hash: Mapped[str | None] = mapped_column(String(64), unique=True)
    activated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
    )

    def __repr__(self) -> str:
        label = self.name or self.email
        return f"<User {label} ({self.status.value})>"
