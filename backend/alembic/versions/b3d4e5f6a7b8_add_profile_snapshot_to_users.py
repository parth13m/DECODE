"""add profile_snapshot to users

Revision ID: b3d4e5f6a7b8
Revises: a2b3c4d5e6f7
Create Date: 2026-08-11 00:00:01.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB


# revision identifiers, used by Alembic.
revision: str = 'b3d4e5f6a7b8'
down_revision: str | None = 'a2b3c4d5e6f7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('users', sa.Column('profile_snapshot', JSONB, nullable=True))
    op.add_column('users', sa.Column('profile_synced_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('users', sa.Column('profile_schema_version', sa.Integer, nullable=True))


def downgrade() -> None:
    op.drop_column('users', 'profile_schema_version')
    op.drop_column('users', 'profile_synced_at')
    op.drop_column('users', 'profile_snapshot')
