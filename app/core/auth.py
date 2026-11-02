import time
from typing import Annotated, Any

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt

from app.core.config import get_settings
from app.core.supabase import get_supabase

bearer = HTTPBearer(auto_error=False)

PROFILE_TTL_SECONDS = 30
_profile_cache: dict[str, tuple[float, dict[str, Any]]] = {}


def _user_id_from_token(token: str) -> str:
    settings = get_settings()
    if settings.supabase_jwt_secret:
        try:
            claims = jwt.decode(
                token,
                settings.supabase_jwt_secret,
                algorithms=["HS256"],
                audience="authenticated",
            )
        except JWTError as exc:
            raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
        return claims["sub"]

    try:
        result = get_supabase().auth.get_user(token)
    except Exception as exc:  # supabase-py raises several auth error types
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    if result is None or result.user is None:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    return result.user.id


def _load_profile(user_id: str) -> dict[str, Any]:
    cached = _profile_cache.get(user_id)
    if cached and time.monotonic() - cached[0] < PROFILE_TTL_SECONDS:
        return cached[1]
    rows = get_supabase().table("profiles").select("*").eq("id", user_id).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=403, detail="No profile for this account")
    _profile_cache[user_id] = (time.monotonic(), rows[0])
    return rows[0]


def invalidate_profile(user_id: str) -> None:
    _profile_cache.pop(user_id, None)


def current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> dict[str, Any]:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return _load_profile(_user_id_from_token(credentials.credentials))


def require_owner(user: Annotated[dict[str, Any], Depends(current_user)]) -> dict[str, Any]:
    if user["role"] != "owner":
        raise HTTPException(status_code=403, detail="Owner access required")
    return user


def require_client(user: Annotated[dict[str, Any], Depends(current_user)]) -> dict[str, Any]:
    if user["role"] != "client":
        raise HTTPException(status_code=403, detail="Client access required")
    return user


CurrentUser = Annotated[dict[str, Any], Depends(current_user)]
Owner = Annotated[dict[str, Any], Depends(require_owner)]
Client = Annotated[dict[str, Any], Depends(require_client)]
