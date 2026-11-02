from collections import defaultdict
from decimal import Decimal
from typing import Any

from fastapi import APIRouter

from app.core.auth import CurrentUser
from app.routers.projects import user_projects

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


def _money(value: Any) -> Decimal:
    return Decimal(str(value))


@router.get("")
def dashboard(user: CurrentUser):
    """Totals over the projects where the user is the one being paid (owners) or the one paying
    (clients). Projects an owner pays for are listed separately under `paying`."""
    everything = user_projects(user)
    side = "payee" if user["role"] == "owner" else "payer"
    projects = [p for p in everything if p["my_side"] == side]
    paying = [p for p in everything if p["my_side"] == "payer"] if user["role"] == "owner" else []

    total_budget = sum((_money(p["budget"]) for p in projects), Decimal(0))
    total_confirmed = sum((_money(p["confirmed"]) for p in projects), Decimal(0))
    awaiting = sum((_money(p["pending"]) for p in projects), Decimal(0))

    per_client: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"client_name": "", "budget": Decimal(0), "received": Decimal(0), "pending_to_receive": Decimal(0)}
    )
    for p in projects:
        row = per_client[p["client_id"]]
        row["client_name"] = p["client_name"]
        row["budget"] += _money(p["budget"])
        row["received"] += _money(p["confirmed"])
        row["pending_to_receive"] += _money(p["budget"]) - _money(p["confirmed"])

    paying_budget = sum((_money(p["budget"]) for p in paying), Decimal(0))
    paying_paid = sum((_money(p["confirmed"]) for p in paying), Decimal(0))

    return {
        "total_received": total_confirmed,
        "total_pending_to_receive": total_budget - total_confirmed,
        "total_budget": total_budget,
        "awaiting_confirmation_amount": awaiting,
        "awaiting_confirmation_count": sum(p["pending_count"] for p in projects),
        "active_projects": sum(1 for p in projects if p["status"] == "active"),
        "completed_projects": sum(1 for p in projects if p["status"] == "completed"),
        "clients": [{"client_id": cid, **row} for cid, row in per_client.items()],
        "projects": projects,
        "paying": paying,
        "paying_totals": {
            "budget": paying_budget,
            "paid": paying_paid,
            "to_pay": paying_budget - paying_paid,
            "awaiting": sum((_money(p["pending"]) for p in paying), Decimal(0)),
        },
    }
