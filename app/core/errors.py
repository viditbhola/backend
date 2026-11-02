"""Translate Postgres function errors ("PREFIX: message") into HTTP errors."""

from typing import Any, Callable

from fastapi import HTTPException
from postgrest.exceptions import APIError

_STATUS_BY_PREFIX = {
    "NOTFOUND": 404,
    "FORBIDDEN": 403,
    "CONFLICT": 409,
    "INVALID": 400,
}


def call_rpc(name: str, params: dict[str, Any]) -> Any:
    """Call a Postgres function and return its data, mapping rule violations to HTTP errors."""
    from app.core.supabase import get_supabase

    try:
        return get_supabase().rpc(name, params).execute().data
    except APIError as exc:
        raise to_http_error(exc) from exc


def to_http_error(exc: APIError) -> HTTPException:
    message = exc.message or "Request failed"
    prefix, _, rest = message.partition(": ")
    if prefix in _STATUS_BY_PREFIX and rest:
        return HTTPException(status_code=_STATUS_BY_PREFIX[prefix], detail=rest)
    return HTTPException(status_code=500, detail="Unexpected database error")


def run_query(query_fn: Callable[[], Any]) -> Any:
    try:
        return query_fn()
    except APIError as exc:
        raise to_http_error(exc) from exc
