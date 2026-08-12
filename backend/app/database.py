import asyncio
from collections.abc import AsyncGenerator, Generator
from concurrent.futures import ThreadPoolExecutor

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import settings

engine = create_engine(
    settings.DATABASE_URL,
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=15,
)

SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)

# Shared thread pool for running synchronous DB operations off the
# async event loop.  Sized to match the DB connection pool ceiling
# (pool_size + max_overflow = 20).
_db_executor = ThreadPoolExecutor(max_workers=20, thread_name_prefix="db")


class Base(DeclarativeBase):
    """Base class for all SQLAlchemy models."""

    pass


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency that yields a database session.

    Commits on success, rolls back on exception, always closes.
    """
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


async def run_in_db_thread(fn, *args):
    """Run a synchronous database function in the thread pool.

    Prevents psycopg2 blocking calls from stalling the async event loop.
    """
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_db_executor, fn, *args)
