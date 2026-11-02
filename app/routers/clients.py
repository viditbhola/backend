from fastapi import APIRouter, HTTPException

from app.core.auth import Owner
from app.core.supabase import get_supabase
from app.schemas import ClientCreate

router = APIRouter(prefix="/clients", tags=["clients"])


@router.get("")
def list_clients(owner: Owner):
    return (
        get_supabase()
        .table("profiles")
        .select("id, full_name, email, must_change_password, created_at")
        .eq("role", "client")
        .order("created_at", desc=True)
        .execute()
        .data
    )


@router.post("", status_code=201)
def create_client(body: ClientCreate, owner: Owner):
    db = get_supabase()
    try:
        created = db.auth.admin.create_user(
            {"email": body.email, "password": body.temp_password, "email_confirm": True}
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Could not create user (email may already exist)") from exc

    user_id = created.user.id
    try:
        row = (
            db.table("profiles")
            .insert(
                {
                    "id": user_id,
                    "role": "client",
                    "full_name": body.full_name,
                    "email": body.email,
                    "must_change_password": True,
                    "created_by": owner["id"],
                }
            )
            .execute()
            .data[0]
        )
    except Exception as exc:
        db.auth.admin.delete_user(user_id)  # compensate: no orphan login without a profile
        raise HTTPException(status_code=500, detail="Could not create client profile") from exc
    return row
