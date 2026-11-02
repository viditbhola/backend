from datetime import date
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, EmailStr, Field, StringConstraints, model_validator

Money = Annotated[Decimal, Field(gt=0, max_digits=12, decimal_places=2)]
ShortText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
LongText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)]


class ClientCreate(BaseModel):
    full_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    email: EmailStr
    temp_password: Annotated[str, StringConstraints(min_length=8, max_length=72)]


class ProjectCreate(BaseModel):
    client_id: str
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
    description: LongText = ""
    budget: Money


class PaymentCreate(BaseModel):
    amount: Money
    paid_on: date
    method: ShortText = ""
    reference: ShortText = ""
    note: LongText = ""


class PaymentReject(BaseModel):
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]


class PaymentChangeCreate(BaseModel):
    """Proposal to edit or delete a confirmed payment; the other party must approve."""

    kind: Literal["edit", "delete"]
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
    amount: Money | None = None
    paid_on: date | None = None
    method: ShortText = ""
    reference: ShortText = ""
    note: LongText = ""

    @model_validator(mode="after")
    def edit_needs_amount_and_date(self):
        if self.kind == "edit" and (self.amount is None or self.paid_on is None):
            raise ValueError("amount and paid_on are required to edit a payment")
        return self


class BudgetRequestCreate(BaseModel):
    new_budget: Money
    note: LongText = ""
