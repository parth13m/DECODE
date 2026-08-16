from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.auth import (
    generate_access_token,
    get_current_user,
    hash_token,
)
from app.database import get_db
from app.models.user import User, UserStatus
from app.rate_limit import limiter

router = APIRouter(prefix="/api/auth", tags=["auth"])


class ActivateRequest(BaseModel):
    invite_code: str
    email: str | None = None


class ActivateResponse(BaseModel):
    access_token: str
    user_id: str
    status: str


class ValidateResponse(BaseModel):
    user_id: str
    status: str
    name: str | None = None
    email: str | None = None
    activated_at: str | None = None


@router.post("/activate", response_model=ActivateResponse)
@limiter.limit("5/minute")
def activate_invite(request: Request, body: ActivateRequest, db: Session = Depends(get_db)) -> ActivateResponse:
    """Redeem an invite code and receive an access token."""
    code = body.invite_code.strip().upper()

    user = db.query(User).filter(User.invite_code == code).first()

    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Invalid invite code",
        )

    if user.status != UserStatus.pending:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Invite code already used",
        )

    # Update email if provided and not already set.
    if body.email and not user.email:
        user.email = body.email

    token = generate_access_token()
    user.token_hash = hash_token(token)
    user.status = UserStatus.active
    user.activated_at = datetime.now(timezone.utc)

    db.flush()

    return ActivateResponse(
        access_token=token,
        user_id=user.id,
        status=user.status.value,
    )


@router.post("/validate", response_model=ValidateResponse)
def validate_token(user: User = Depends(get_current_user)) -> ValidateResponse:
    """Check if a stored token is still valid."""
    return ValidateResponse(
        user_id=user.id,
        status=user.status.value,
        name=user.name,
        email=user.email,
        activated_at=user.activated_at.isoformat() if user.activated_at else None,
    )
