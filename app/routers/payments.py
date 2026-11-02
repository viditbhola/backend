import uuid
from typing import Any

from fastapi import APIRouter, File, HTTPException, Request, UploadFile

from app.core.auth import Client, CurrentUser, Owner
from app.core.config import get_settings
from app.core.errors import call_rpc
from app.core.limiter import limiter
from app.core.supabase import get_supabase
from app.schemas import PaymentChangeCreate, PaymentCreate, PaymentReject

router = APIRouter(tags=["payments"])

ALLOWED_PROOF_TYPES = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "application/pdf": "pdf",
}


@router.post("/projects/{project_id}/payments", status_code=201)
@limiter.limit("30/minute")
def log_payment(request: Request, project_id: str, body: PaymentCreate, client: Client):
    return call_rpc(
        "log_payment",
        {
            "p_project": project_id,
            "p_client": client["id"],
            "p_amount": str(body.amount),
            "p_paid_on": body.paid_on.isoformat(),
            "p_method": body.method,
            "p_reference": body.reference,
            "p_note": body.note,
        },
    )


@router.patch("/payments/{payment_id}")
@limiter.limit("30/minute")
def edit_pending_payment(request: Request, payment_id: str, body: PaymentCreate, client: Client):
    """Direct edit; allowed only while the payment is still pending."""
    return call_rpc(
        "edit_pending_payment",
        {
            "p_payment": payment_id,
            "p_client": client["id"],
            "p_amount": str(body.amount),
            "p_paid_on": body.paid_on.isoformat(),
            "p_method": body.method,
            "p_reference": body.reference,
            "p_note": body.note,
        },
    )


@router.delete("/payments/{payment_id}")
@limiter.limit("30/minute")
def delete_pending_payment(request: Request, payment_id: str, client: Client):
    """Direct delete; allowed only while the payment is still pending."""
    return call_rpc("delete_pending_payment", {"p_payment": payment_id, "p_client": client["id"]})


@router.post("/payments/{payment_id}/changes", status_code=201)
@limiter.limit("30/minute")
def propose_change(request: Request, payment_id: str, body: PaymentChangeCreate, user: CurrentUser):
    """Either party proposes an edit/delete of a confirmed payment; the other must approve."""
    return call_rpc(
        "propose_payment_change",
        {
            "p_payment": payment_id,
            "p_user": user["id"],
            "p_kind": body.kind,
            "p_amount": str(body.amount) if body.amount is not None else None,
            "p_paid_on": body.paid_on.isoformat() if body.paid_on else None,
            "p_method": body.method,
            "p_reference": body.reference,
            "p_note": body.note,
            "p_reason": body.reason,
        },
    )


@router.post("/payment-changes/{change_id}/approve")
@limiter.limit("30/minute")
def approve_change(request: Request, change_id: str, user: CurrentUser):
    return call_rpc(
        "respond_payment_change", {"p_request": change_id, "p_user": user["id"], "p_approve": True}
    )


@router.post("/payment-changes/{change_id}/reject")
@limiter.limit("30/minute")
def reject_change(request: Request, change_id: str, user: CurrentUser):
    return call_rpc(
        "respond_payment_change", {"p_request": change_id, "p_user": user["id"], "p_approve": False}
    )


@router.post("/payment-changes/{change_id}/cancel")
@limiter.limit("30/minute")
def cancel_change(request: Request, change_id: str, user: CurrentUser):
    return call_rpc("cancel_payment_change", {"p_request": change_id, "p_user": user["id"]})


@router.post("/payments/{payment_id}/confirm")
@limiter.limit("30/minute")
def confirm_payment(request: Request, payment_id: str, owner: Owner):
    return call_rpc(
        "decide_payment",
        {"p_payment": payment_id, "p_owner": owner["id"], "p_confirm": True, "p_reason": None},
    )


@router.post("/payments/{payment_id}/reject")
@limiter.limit("30/minute")
def reject_payment(request: Request, payment_id: str, body: PaymentReject, owner: Owner):
    return call_rpc(
        "decide_payment",
        {"p_payment": payment_id, "p_owner": owner["id"], "p_confirm": False, "p_reason": body.reason},
    )


@router.post("/payments/{payment_id}/proof")
@limiter.limit("10/minute")
async def upload_proof(request: Request, payment_id: str, client: Client, file: UploadFile = File(...)):
    settings = get_settings()
    extension = ALLOWED_PROOF_TYPES.get(file.content_type or "")
    if extension is None:
        raise HTTPException(status_code=400, detail="Proof must be a JPEG, PNG, WebP or PDF file")
    data = await file.read(settings.max_proof_bytes + 1)
    if len(data) > settings.max_proof_bytes:
        raise HTTPException(status_code=400, detail="Proof must be 5 MB or smaller")

    payment = _owned_payment(payment_id, client)
    path = f"{payment['project_id']}/{payment_id}/{uuid.uuid4().hex}.{extension}"
    storage = get_supabase().storage.from_(settings.proof_bucket)
    storage.upload(path, data, {"content-type": file.content_type})
    return call_rpc(
        "attach_payment_proof", {"p_payment": payment_id, "p_client": client["id"], "p_path": path}
    )


@router.get("/payments/{payment_id}/proof")
def proof_url(payment_id: str, user: CurrentUser):
    payment = _visible_payment(payment_id, user)
    if not payment.get("proof_path"):
        raise HTTPException(status_code=404, detail="No proof attached")
    signed = (
        get_supabase()
        .storage.from_(get_settings().proof_bucket)
        .create_signed_url(payment["proof_path"], 300)
    )
    return {"url": signed["signedURL"]}


def _payment_with_project(payment_id: str) -> dict[str, Any]:
    rows = (
        get_supabase()
        .table("payments")
        .select("*, projects(owner_id, client_id)")
        .eq("id", payment_id)
        .limit(1)
        .execute()
        .data
    )
    if not rows:
        raise HTTPException(status_code=404, detail="payment not found")
    return rows[0]


def _owned_payment(payment_id: str, client: dict[str, Any]) -> dict[str, Any]:
    payment = _payment_with_project(payment_id)
    if payment["created_by"] != client["id"]:
        raise HTTPException(status_code=403, detail="not your payment")
    return payment


def _visible_payment(payment_id: str, user: dict[str, Any]) -> dict[str, Any]:
    payment = _payment_with_project(payment_id)
    project = payment["projects"]
    if user["id"] not in (project["owner_id"], project["client_id"]):
        raise HTTPException(status_code=404, detail="payment not found")
    return payment
