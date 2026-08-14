"""merge heads: profile snapshot and compression fix

Revision ID: 3e35cf554f9a
Revises: b3d4e5f6a7b8, g8b9c0d1e2f3
Create Date: 2026-08-13 00:00:01.000000
"""
from typing import Sequence, Union


# revision identifiers, used by Alembic.
revision: str = '3e35cf554f9a'
down_revision: Union[str, tuple[str, ...], None] = ('b3d4e5f6a7b8', 'g8b9c0d1e2f3')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
