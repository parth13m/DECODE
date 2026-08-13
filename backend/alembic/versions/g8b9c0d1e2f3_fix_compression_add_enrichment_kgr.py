"""fix compression decomposition and add enrichment_kgr support

Backfills ai_requests rows where compression mode was incorrectly
decomposed as origin_mode='compression', request_type='unknown'.
Corrects to origin_mode=NULL, request_type='compression'.

No schema changes — only data fixup.

Revision ID: g8b9c0d1e2f3
Revises: f7a8b9c0d1e2
Create Date: 2026-08-14 00:00:01.000000
"""
from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'g8b9c0d1e2f3'
down_revision: Union[str, None] = 'f7a8b9c0d1e2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Fix compression records: origin_mode='compression', request_type='unknown'
    # → origin_mode=NULL, request_type='compression'
    op.execute(
        "UPDATE ai_requests "
        "SET origin_mode = NULL, request_type = 'compression' "
        "WHERE origin_mode = 'compression' AND request_type = 'unknown'"
    )

    # Also fix any events table records with the same issue
    op.execute(
        "UPDATE events "
        "SET origin_mode = NULL, request_type = 'compression' "
        "WHERE origin_mode = 'compression' AND request_type = 'unknown'"
    )


def downgrade() -> None:
    # Reverse: set compression records back to the old decomposition
    op.execute(
        "UPDATE ai_requests "
        "SET origin_mode = 'compression', request_type = 'unknown' "
        "WHERE origin_mode IS NULL AND request_type = 'compression'"
    )
    op.execute(
        "UPDATE events "
        "SET origin_mode = 'compression', request_type = 'unknown' "
        "WHERE origin_mode IS NULL AND request_type = 'compression'"
    )
