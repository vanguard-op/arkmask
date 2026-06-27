from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import get_settings


def _build_engine():
    settings = get_settings()
    return create_engine(
        settings.database_url,
        pool_pre_ping=True,   # reconnect automatically after idle timeout
        pool_size=10,
        max_overflow=20,
    )


engine = _build_engine()
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    """SQLAlchemy declarative base shared by all ORM models."""
    pass


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency — yields a database session, always closes it."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
