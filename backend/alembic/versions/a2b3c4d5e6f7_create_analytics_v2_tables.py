"""create analytics v2 tables (events, ai_requests, daily_summaries)

Revision ID: a2b3c4d5e6f7
Revises: f7a8b9c0d1e2
Create Date: 2026-08-06 00:00:01.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID


# revision identifiers, used by Alembic.
revision: str = 'a2b3c4d5e6f7'
down_revision: Union[str, None] = 'f7a8b9c0d1e2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── events ──
    op.create_table(
        'events',
        sa.Column('id', UUID(as_uuid=False), server_default=sa.text('gen_random_uuid()'), primary_key=True),
        sa.Column('user_id', UUID(as_uuid=False), nullable=False),
        sa.Column('event_type', sa.String(64), nullable=False),
        sa.Column('origin_mode', sa.String(32), nullable=True),
        sa.Column('request_type', sa.String(32), nullable=True),
        sa.Column('interaction_id', UUID(as_uuid=False), nullable=True),
        sa.Column('metadata', JSONB, nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('now()')),
    )
    op.create_index('ix_events_user_id', 'events', ['user_id'])
    op.create_index('ix_events_event_type', 'events', ['event_type'])
    op.create_index('ix_events_origin_mode', 'events', ['origin_mode'])
    op.create_index('ix_events_request_type', 'events', ['request_type'])
    op.create_index('ix_events_interaction_id', 'events', ['interaction_id'])
    op.create_index('ix_events_created_at', 'events', ['created_at'])

    # ── ai_requests ──
    op.create_table(
        'ai_requests',
        sa.Column('id', UUID(as_uuid=False), server_default=sa.text('gen_random_uuid()'), primary_key=True),
        sa.Column('user_id', UUID(as_uuid=False), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('now()')),
        sa.Column('origin_mode', sa.String(32), nullable=True),
        sa.Column('request_type', sa.String(32), nullable=False),
        sa.Column('explanation_profile', sa.String(16), nullable=True),
        sa.Column('language', sa.String(32), nullable=True),
        sa.Column('ai_provider', sa.String(64), nullable=False),
        sa.Column('ai_model', sa.String(128), nullable=False),
        sa.Column('success', sa.Boolean(), nullable=False),
        sa.Column('error_type', sa.String(64), nullable=True),
        sa.Column('latency_ms', sa.Integer(), nullable=False),
        sa.Column('prompt_tokens', sa.Integer(), nullable=True),
        sa.Column('completion_tokens', sa.Integer(), nullable=True),
        sa.Column('total_tokens', sa.Integer(), nullable=True),
        sa.Column('prompt_character_count', sa.Integer(), nullable=True),
        sa.Column('estimated_cost_usd', sa.Float(), nullable=True),
        sa.Column('interaction_id', UUID(as_uuid=False), nullable=True),
        sa.Column('legacy_request_log_id', UUID(as_uuid=False), nullable=True),
    )
    op.create_index('ix_ai_requests_user_id', 'ai_requests', ['user_id'])
    op.create_index('ix_ai_requests_created_at', 'ai_requests', ['created_at'])
    op.create_index('ix_ai_requests_origin_mode', 'ai_requests', ['origin_mode'])
    op.create_index('ix_ai_requests_request_type', 'ai_requests', ['request_type'])
    op.create_index('ix_ai_requests_ai_provider', 'ai_requests', ['ai_provider'])
    op.create_index('ix_ai_requests_ai_model', 'ai_requests', ['ai_model'])
    op.create_index('ix_ai_requests_interaction_id', 'ai_requests', ['interaction_id'])
    # Composite index for common dashboard queries
    op.create_index('ix_ai_requests_date_mode', 'ai_requests', ['created_at', 'origin_mode'])
    op.create_index('ix_ai_requests_date_provider', 'ai_requests', ['created_at', 'ai_provider'])

    # ── daily_summaries ──
    op.create_table(
        'daily_summaries',
        sa.Column('id', UUID(as_uuid=False), server_default=sa.text('gen_random_uuid()'), primary_key=True),
        sa.Column('summary_date', sa.Date(), nullable=False),
        sa.Column('dimension', sa.String(32), nullable=False),
        sa.Column('dimension_value', sa.String(128), nullable=False),
        sa.Column('total_requests', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('successful_requests', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('failed_requests', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('unique_users', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('avg_latency_ms', sa.Float(), nullable=True),
        sa.Column('p50_latency_ms', sa.Float(), nullable=True),
        sa.Column('p95_latency_ms', sa.Float(), nullable=True),
        sa.Column('p99_latency_ms', sa.Float(), nullable=True),
        sa.Column('total_prompt_tokens', sa.Integer(), nullable=True),
        sa.Column('total_completion_tokens', sa.Integer(), nullable=True),
        sa.Column('total_tokens', sa.Integer(), nullable=True),
        sa.Column('total_estimated_cost_usd', sa.Float(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('now()')),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('now()')),
        sa.UniqueConstraint('summary_date', 'dimension', 'dimension_value', name='uq_daily_summary_date_dim'),
    )
    op.create_index('ix_daily_summaries_summary_date', 'daily_summaries', ['summary_date'])
    op.create_index('ix_daily_summaries_dimension', 'daily_summaries', ['dimension'])
    # Composite index for lookups by date + dimension
    op.create_index('ix_daily_summaries_date_dim', 'daily_summaries', ['summary_date', 'dimension'])


def downgrade() -> None:
    op.drop_table('daily_summaries')
    op.drop_table('ai_requests')
    op.drop_table('events')
