from datetime import date
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, EmailStr, Field, StringConstraints, model_validator

Money = Annotated[Decimal, Field(gt=0, max_digits=12, decimal_places=2)]
ShortText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
LongText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)]


class Link(BaseModel):
    label: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = ""
    url: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000, pattern=r"^https?://\S+$")]


Links = Annotated[list[Link], Field(max_length=10)]


class ClientCreate(BaseModel):
    full_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    email: EmailStr
    temp_password: Annotated[str, StringConstraints(min_length=8, max_length=72)]


class ProjectCreate(BaseModel):
    client_id: str
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
    description: LongText = ""
    budget: Money
    links: Links = []


class ProposalCreate(BaseModel):
    """`side` is the sender's side: 'payee' (I get paid) or 'payer' (I pay)."""

    recipient_id: str
    side: Literal["payee", "payer"]
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
    description: LongText = ""
    budget: Money
    links: Links = []


class ProposalReject(BaseModel):
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]


class PaymentCreate(BaseModel):
    amount: Money
    paid_on: date
    method: ShortText = ""
    reference: ShortText = ""
    note: LongText = ""
    links: Links = []


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
