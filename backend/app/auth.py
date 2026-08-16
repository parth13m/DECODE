import hashlib
import logging
import secrets
import string

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.config import settings

logger = logging.getLogger(__name__)
from app.database import get_db
from app.models.user import User, UserStatus

# Characters for invite codes: A-Z, 0-9 minus ambiguous (0, O, 1, I, L)
_INVITE_CHARS = string.ascii_uppercase + string.digits
_INVITE_CHARS = "".join(
    c for c in _INVITE_CHARS if c not in "0O1IL"
)

_bearer_scheme = HTTPBearer()


def generate_invite_code() -> str:
    """Generate a human-readable invite code: DECODE-XXXX-XXXX."""
    part1 = "".join(secrets.choice(_INVITE_CHARS) for _ in range(4))
    part2 = "".join(secrets.choice(_INVITE_CHARS) for _ in range(4))
    return f"DECODE-{part1}-{part2}"


def generate_access_token() -> str:
    """Generate a 256-bit random access token (64 hex characters)."""
    return secrets.token_hex(32)


def hash_token(token: str) -> str:
    """SHA-256 hash of a token. Used for storage and lookup."""
    return hashlib.sha256(token.encode()).hexdigest()


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
    db: Session = Depends(get_db),
) -> User:
    """FastAPI dependency: authenticate request via Bearer token.

    Returns the User if the token is valid and the account is active.
    Raises 401 for invalid tokens, 403 for disabled accounts.
    """
    token = credentials.credentials
    token_digest = hash_token(token)

    user = db.query(User).filter(User.token_hash == token_digest).first()

    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )

    if user.status == UserStatus.disabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account disabled",
        )

    return user


def require_admin(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
) -> None:
    """FastAPI dependency: require the static ADMIN_TOKEN.

    Raises 503 if ADMIN_TOKEN is not configured, 401 if the token
    does not match.
    """
    if not settings.ADMIN_TOKEN:
        logger.warning("Admin login attempted but ADMIN_TOKEN is not configured")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Admin access not configured. Set the ADMIN_TOKEN environment variable.",
        )

    if not secrets.compare_digest(credentials.credentials, settings.ADMIN_TOKEN):
        logger.warning("Admin login failed: token mismatch")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid admin token",
        )

    logger.info("Admin login successful")
