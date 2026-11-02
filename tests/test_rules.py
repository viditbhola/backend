"""Integration tests for the payment rules.

They run against a DISPOSABLE Supabase project (never the live one): set
RUN_DB_TESTS=1 and point SUPABASE_URL / SUPABASE_SERVICE_KEY at the test project.
Payments / budget requests are append-only by design, so the tests do not clean up;
use a throwaway project and reset it when done.
"""

import os
import uuid
from datetime import date

import pytest
from fastapi import HTTPException

from app.core.errors import call_rpc
from app.core.supabase import get_supabase

pytestmark = pytest.mark.skipif(
    os.getenv("RUN_DB_TESTS") != "1", reason="set RUN_DB_TESTS=1 with a disposable Supabase project"
)


def make_user(role: str) -> str:
    db = get_supabase()
    email = f"{role}-{uuid.uuid4().hex[:8]}@test.local"
    user = db.auth.admin.create_user({"email": email, "password": "Passw0rd!x", "email_confirm": True})
    try:
        db.table("profiles").insert(
            {"id": user.user.id, "role": role, "full_name": role, "email": email}
        ).execute()
    except Exception:
        db.auth.admin.delete_user(user.user.id)
        raise
    return user.user.id


@pytest.fixture(scope="session")
def owners():
    """The system allows exactly 2 owners, so the whole session shares two."""
    return make_user("owner"), make_user("owner")


@pytest.fixture
def world(owners):
    owner, _ = owners
    client = make_user("client")
    project = call_rpc(
        "create_project",
        {"p_owner": owner, "p_client": client, "p_title": "P1", "p_description": "", "p_budget": "100000"},
    )
    return owner, client, project["id"]


def log(project, client, amount):
    return call_rpc(
        "log_payment",
        {
            "p_project": project, "p_client": client, "p_amount": str(amount),
            "p_paid_on": date.today().isoformat(), "p_method": "UPI", "p_reference": "", "p_note": "",
        },
    )


def decide(payment, owner, confirm, reason=None):
    return call_rpc(
        "decide_payment",
        {"p_payment": payment, "p_owner": owner, "p_confirm": confirm, "p_reason": reason},
    )


def project_row(project):
    return get_supabase().table("projects").select("status,budget").eq("id", project).single().execute().data


def test_cannot_log_more_than_remaining(world):
    _, client, project = world
    log(project, client, 60000)
    with pytest.raises(HTTPException) as err:
        log(project, client, 50000)
    assert err.value.status_code == 400


def test_full_confirmation_completes_and_locks(world):
    owner, client, project = world
    first = log(project, client, 30000)
    assert first["status"] == "pending"
    decide(first["id"], owner, True)
    assert project_row(project)["status"] == "active"
    decide(log(project, client, 70000)["id"], owner, True)
    assert project_row(project)["status"] == "completed"
    with pytest.raises(HTTPException) as err:
        log(project, client, 1)
    assert err.value.status_code == 409


def test_deny_requires_reason_and_frees_amount(world):
    owner, client, project = world
    pay = log(project, client, 100000)
    with pytest.raises(HTTPException):
        decide(pay["id"], owner, False, "")
    decide(pay["id"], owner, False, "not received")
    log(project, client, 100000)  # the denied amount is loggable again


def test_decided_payment_cannot_be_decided_again(world):
    owner, client, project = world
    pay = log(project, client, 1000)
    decide(pay["id"], owner, True)
    with pytest.raises(HTTPException) as err:
        decide(pay["id"], owner, False, "changed my mind")
    assert err.value.status_code == 409


def test_budget_increase_accept_reopens_logging(world):
    owner, client, project = world
    log(project, client, 100000)
    request = call_rpc(
        "request_budget_increase",
        {"p_project": project, "p_owner": owner, "p_new_budget": "150000", "p_note": ""},
    )
    with pytest.raises(HTTPException):
        log(project, client, 1)  # still capped until the client accepts
    call_rpc("respond_budget_request", {"p_request": request["id"], "p_client": client, "p_accept": True})
    log(project, client, 50000)
    assert float(project_row(project)["budget"]) == 150000


def test_budget_increase_deny_keeps_budget(world):
    owner, client, project = world
    request = call_rpc(
        "request_budget_increase",
        {"p_project": project, "p_owner": owner, "p_new_budget": "150000", "p_note": ""},
    )
    call_rpc("respond_budget_request", {"p_request": request["id"], "p_client": client, "p_accept": False})
    assert float(project_row(project)["budget"]) == 100000


def test_completion_cancels_open_budget_request(world):
    owner, client, project = world
    pay = log(project, client, 100000)
    request = call_rpc(
        "request_budget_increase",
        {"p_project": project, "p_owner": owner, "p_new_budget": "150000", "p_note": ""},
    )
    decide(pay["id"], owner, True)
    with pytest.raises(HTTPException) as err:
        call_rpc("respond_budget_request", {"p_request": request["id"], "p_client": client, "p_accept": True})
    assert err.value.status_code == 409


def test_wrong_client_cannot_log(world):
    _, _, project = world
    with pytest.raises(HTTPException) as err:
        log(project, make_user("client"), 10)
    assert err.value.status_code == 403


def test_wrong_owner_cannot_decide(world, owners):
    _, client, project = world
    pay = log(project, client, 10)
    other_owner = next(o for o in owners if o != world[0])
    with pytest.raises(HTTPException) as err:
        decide(pay["id"], other_owner, True)
    assert err.value.status_code == 403


def test_third_owner_rejected(owners):
    with pytest.raises(Exception):
        make_user("owner")


def propose(payment, user, kind, reason="fix", amount=None):
    return call_rpc(
        "propose_payment_change",
        {
            "p_payment": payment, "p_user": user, "p_kind": kind, "p_amount": amount,
            "p_paid_on": date.today().isoformat() if kind == "edit" else None,
            "p_method": "", "p_reference": "", "p_note": "", "p_reason": reason,
        },
    )


def respond(change, user, approve):
    return call_rpc("respond_payment_change", {"p_request": change, "p_user": user, "p_approve": approve})


def confirmed_payment(owner, client, project, amount):
    return decide(log(project, client, amount)["id"], owner, True)


def test_pending_payment_can_be_edited_and_deleted_directly(world):
    _, client, project = world
    pay = log(project, client, 1000)
    edited = call_rpc(
        "edit_pending_payment",
        {
            "p_payment": pay["id"], "p_client": client, "p_amount": "2000",
            "p_paid_on": date.today().isoformat(), "p_method": "", "p_reference": "", "p_note": "",
        },
    )
    assert float(edited["amount"]) == 2000
    deleted = call_rpc("delete_pending_payment", {"p_payment": pay["id"], "p_client": client})
    assert deleted["status"] == "deleted"


def test_confirmed_edit_needs_other_party_approval(world):
    owner, client, project = world
    pay = confirmed_payment(owner, client, project, 40000)
    change = propose(pay["id"], client, "edit", amount="30000")
    with pytest.raises(HTTPException) as err:
        respond(change["id"], client, True)  # requester cannot approve own request
    assert err.value.status_code == 403
    respond(change["id"], owner, True)
    row = get_supabase().table("payments").select("amount").eq("id", pay["id"]).single().execute().data
    assert float(row["amount"]) == 30000


def test_rejected_change_leaves_payment_untouched(world):
    owner, client, project = world
    pay = confirmed_payment(owner, client, project, 40000)
    change = propose(pay["id"], owner, "delete")
    respond(change["id"], client, False)
    row = get_supabase().table("payments").select("status").eq("id", pay["id"]).single().execute().data
    assert row["status"] == "confirmed"


def test_approved_delete_reopens_completed_project(world):
    owner, client, project = world
    pay = confirmed_payment(owner, client, project, 100000)
    assert project_row(project)["status"] == "completed"
    respond(propose(pay["id"], client, "delete")["id"], owner, True)
    assert project_row(project)["status"] == "active"
    log(project, client, 100000)  # logging is open again


def test_only_one_open_change_per_payment(world):
    owner, client, project = world
    pay = confirmed_payment(owner, client, project, 1000)
    propose(pay["id"], client, "delete")
    with pytest.raises(HTTPException) as err:
        propose(pay["id"], owner, "delete")
    assert err.value.status_code == 409
