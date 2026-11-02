from typing import Any

from fastapi import APIRouter, HTTPException, Request

from app.core.auth import CurrentUser, Owner
from app.core.errors import call_rpc
from app.core.limiter import limiter
from app.core.supabase import get_supabase
from app.schemas import DeleteRequestCreate

router = APIRouter(prefix="/projects", tags=["projects"])


def user_projects(user: dict[str, Any]) -> list[dict[str, Any]]:
    """Every project the user is part of, tagged with `my_side` ('payee' = gets paid, 'payer' = pays).

    Sides belong to the project, not the account role: an owner can be the payer of the other
    owner's project.
    """
    payee = []
    if user["role"] == "owner":  # only owners can be paid
        payee = [{**r, "my_side": "payee"} for r in call_rpc("project_summaries", {"p_owner": user["id"]})]
    payer = [{**r, "my_side": "payer"} for r in call_rpc("project_summaries", {"p_client": user["id"]})]
    return sorted(payee + payer, key=lambda r: r["created_at"], reverse=True)


def _with_remaining(row: dict[str, Any]) -> dict[str, Any]:
    budget, confirmed, pending = (float(row[k]) for k in ("budget", "confirmed", "pending"))
    row["remaining_to_pay"] = budget - confirmed
    row["loggable"] = budget - confirmed - pending
    return row


@router.get("")
def list_projects(user: CurrentUser):
    return [_with_remaining(r) for r in user_projects(user)]


@router.get("/{project_id}")
def project_detail(project_id: str, user: CurrentUser):
    summaries = [r for r in user_projects(user) if r["id"] == project_id]
    if not summaries:
        raise HTTPException(status_code=404, detail="project not found")
    db = get_supabase()
    payments = (
        db.table("payments")
        .select("*")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )
    budget_requests = (
        db.table("budget_requests")
        .select("*")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )
    payment_changes = (
        db.table("payment_change_requests")
        .select("*")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )
    delete_requests = (
        db.table("project_delete_requests")
        .select("*")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )
    return {
        "project": _with_remaining(summaries[0]),
        "payments": payments,
        "budget_requests": budget_requests,
        "payment_changes": payment_changes,
        "delete_requests": delete_requests,
    }


@router.post("/{project_id}/delete-requests", status_code=201)
@limiter.limit("30/minute")
def request_deletion(request: Request, project_id: str, body: DeleteRequestCreate, user: CurrentUser):
    """Either party asks to delete the project; the other party must approve."""
    return call_rpc(
        "request_project_deletion",
        {"p_project": project_id, "p_user": user["id"], "p_reason": body.reason},
    )


deletion_router = APIRouter(prefix="/project-delete-requests", tags=["projects"])


@deletion_router.post("/{request_id}/approve")
@limiter.limit("30/minute")
def approve_deletion(request: Request, request_id: str, user: CurrentUser):
    return call_rpc(
        "respond_project_deletion", {"p_request": request_id, "p_user": user["id"], "p_approve": True}
    )


@deletion_router.post("/{request_id}/reject")
@limiter.limit("30/minute")
def reject_deletion(request: Request, request_id: str, user: CurrentUser):
    return call_rpc(
        "respond_project_deletion", {"p_request": request_id, "p_user": user["id"], "p_approve": False}
    )


@deletion_router.post("/{request_id}/cancel")
@limiter.limit("30/minute")
def cancel_deletion(request: Request, request_id: str, user: CurrentUser):
    return call_rpc("cancel_project_deletion", {"p_request": request_id, "p_user": user["id"]})
