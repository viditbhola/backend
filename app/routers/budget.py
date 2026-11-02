from fastapi import APIRouter, Request

from app.core.auth import Client, Owner
from app.core.errors import call_rpc
from app.core.limiter import limiter
from app.schemas import BudgetRequestCreate

router = APIRouter(tags=["budget"])


@router.post("/projects/{project_id}/budget-requests", status_code=201)
@limiter.limit("30/minute")
def request_increase(request: Request, project_id: str, body: BudgetRequestCreate, owner: Owner):
    return call_rpc(
        "request_budget_increase",
        {
            "p_project": project_id,
            "p_owner": owner["id"],
            "p_new_budget": str(body.new_budget),
            "p_note": body.note,
        },
    )


@router.post("/budget-requests/{request_id}/accept")
@limiter.limit("30/minute")
def accept_increase(request: Request, request_id: str, client: Client):
    return call_rpc(
        "respond_budget_request",
        {"p_request": request_id, "p_client": client["id"], "p_accept": True},
    )


@router.post("/budget-requests/{request_id}/reject")
@limiter.limit("30/minute")
def reject_increase(request: Request, request_id: str, client: Client):
    return call_rpc(
        "respond_budget_request",
        {"p_request": request_id, "p_client": client["id"], "p_accept": False},
    )
