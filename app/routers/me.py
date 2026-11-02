from fastapi import APIRouter

from app.core.auth import CurrentUser, invalidate_profile
from app.core.supabase import get_supabase

router = APIRouter(tags=["me"])


@router.get("/me")
def read_me(user: CurrentUser):
    return user


@router.post("/me/password-changed")
def password_changed(user: CurrentUser):
    """Called by the UI after the user set a new password; clears the first-login flag."""
    get_supabase().table("profiles").update({"must_change_password": False}).eq(
        "id", user["id"]
    ).execute()
    invalidate_profile(user["id"])
    return {"ok": True}
