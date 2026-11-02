from typing import Any

from fastapi import APIRouter, Request

from app.core.auth import CurrentUser
from app.core.errors import call_rpc
from app.core.limiter import limiter
from app.core.supabase import get_supabase
from app.schemas import ProposalCreate, ProposalReject

router = APIRouter(tags=["proposals"])


@router.get("/people")
def people(user: CurrentUser) -> list[dict[str, Any]]:
    """Who the caller may send a project request to. Clients only ever see owners."""
    query = get_supabase().table("profiles").select("id, full_name, email, role").neq("id", user["id"])
    if user["role"] != "owner":
        query = query.eq("role", "owner")
    return query.order("full_name").execute().data


@router.get("/proposals")
def list_proposals(user: CurrentUser) -> dict[str, list[dict[str, Any]]]:
    rows = (
        get_supabase()
        .table("project_proposals")
        .select("*")
        .or_(f"proposer_id.eq.{user['id']},recipient_id.eq.{user['id']}")
        .order("created_at", desc=True)
        .execute()
        .data
    )
    if not rows:
        return {"incoming": [], "outgoing": []}
    people_ids = list({i for r in rows for i in (r["proposer_id"], r["recipient_id"])})
    names = {
        p["id"]: p["full_name"]
        for p in get_supabase().table("profiles").select("id, full_name").in_("id", people_ids).execute().data
    }
    rows = [
        {**r, "proposer_name": names.get(r["proposer_id"], ""), "recipient_name": names.get(r["recipient_id"], "")}
        for r in rows
    ]
    return {
        "incoming": [r for r in rows if r["recipient_id"] == user["id"]],
        "outgoing": [r for r in rows if r["proposer_id"] == user["id"]],
    }


@router.post("/proposals", status_code=201)
@limiter.limit("30/minute")
def create_proposal(request: Request, body: ProposalCreate, user: CurrentUser):
    return call_rpc(
        "create_project_proposal",
        {
            "p_proposer": user["id"],
            "p_recipient": body.recipient_id,
            "p_side": body.side,
            "p_title": body.title,
            "p_description": body.description,
            "p_budget": str(body.budget),
            "p_links": [link.model_dump() for link in body.links],
        },
    )


@router.post("/proposals/{proposal_id}/accept")
@limiter.limit("30/minute")
def accept_proposal(request: Request, proposal_id: str, user: CurrentUser):
    return call_rpc(
        "respond_project_proposal",
        {"p_proposal": proposal_id, "p_user": user["id"], "p_accept": True, "p_reason": None},
    )


@router.post("/proposals/{proposal_id}/reject")
@limiter.limit("30/minute")
def reject_proposal(request: Request, proposal_id: str, body: ProposalReject, user: CurrentUser):
    return call_rpc(
        "respond_project_proposal",
        {"p_proposal": proposal_id, "p_user": user["id"], "p_accept": False, "p_reason": body.reason},
    )


@router.post("/proposals/{proposal_id}/cancel")
@limiter.limit("30/minute")
def cancel_proposal(request: Request, proposal_id: str, user: CurrentUser):
    return call_rpc("cancel_project_proposal", {"p_proposal": proposal_id, "p_user": user["id"]})
