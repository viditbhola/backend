from typing import Any

from fastapi import APIRouter, HTTPException

from app.core.auth import CurrentUser, Owner
from app.core.errors import call_rpc
from app.core.supabase import get_supabase
from app.schemas import ProjectCreate

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


@router.post("", status_code=201)
def create_project(body: ProjectCreate, owner: Owner):
    return call_rpc(
        "create_project",
        {
            "p_owner": owner["id"],
            "p_client": body.client_id,
            "p_title": body.title,
            "p_description": body.description,
            "p_budget": str(body.budget),
            "p_links": [link.model_dump() for link in body.links],
        },
    )


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
    return {
        "project": _with_remaining(summaries[0]),
        "payments": payments,
        "budget_requests": budget_requests,
        "payment_changes": payment_changes,
    }
