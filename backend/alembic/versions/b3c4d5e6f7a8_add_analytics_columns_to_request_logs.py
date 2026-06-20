"""add analytics columns to request_logs

Revision ID: b3c4d5e6f7a8
Revises: a1b2c3d4e5f6
Create Date: 2026-06-12 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b3c4d5e6f7a8'
down_revision: Union[str, None] = 'a1b2c3d4e5f6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('request_logs', sa.Column('context_tier', sa.String(length=8), nullable=True))
    op.add_column('request_logs', sa.Column('prompt_tokens', sa.Integer(), nullable=True))
    op.add_column('request_logs', sa.Column('completion_tokens', sa.Integer(), nullable=True))
    op.add_column('request_logs', sa.Column('total_tokens', sa.Integer(), nullable=True))
    op.add_column('request_logs', sa.Column('prompt_character_count', sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column('request_logs', 'prompt_character_count')
    op.drop_column('request_logs', 'total_tokens')
    op.drop_column('request_logs', 'completion_tokens')
    op.drop_column('request_logs', 'prompt_tokens')
    op.drop_column('request_logs', 'context_tier')
