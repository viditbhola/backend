# Project Payment Tracker

React (Vercel) + FastAPI (Render) + Supabase. See README.md for setup.

## Invariants
- Business rules (budget cap, completion lock, budget-request flow, max 2 owners) live in Postgres functions/triggers in `supabase/migrations/`. Do not re-implement them in Python.
- **Authorization lives in the SQL functions** (they take the caller id and check ownership/assignment). Routers only authenticate and gate on role (`require_owner` / `require_client` in `backend/app/core/auth.py`).
- Function errors are prefixed `NOTFOUND:` / `FORBIDDEN:` / `CONFLICT:` / `INVALID:`; `backend/app/core/errors.py` maps them to 404/403/409/400. Keep the prefixes when adding rules.
- `payments` and `budget_requests` are immutable once decided (trigger). The only sanctioned change path is the two-party flow below; never add other update/delete paths.
- Money: `numeric(12,2)` in DB, `Decimal` in Python, sent to RPC as strings.
- Backend uses the Supabase service-role key; the frontend only uses the anon key for login. RLS is on with no public policies.
- Schema changes: add a new numbered migration; do not edit `001_init.sql` once it has been applied anywhere.
- DB tests (`backend/tests`) need a disposable Supabase project and `RUN_DB_TESTS=1`.
- Editing/deleting payments (`002_payment_changes.sql`): pending payments are edited/deleted directly by their client; **confirmed** payments change only via `payment_change_requests`, which the *other* party must approve. Deletes are soft (`status='deleted'`). The `app.allow_payment_change` transaction flag lets `respond_payment_change` bypass the immutability trigger; never set it anywhere else. Approval recomputes project status (`recompute_project_status`).
- Project sides are per project, not per role (`003_project_requests_and_links.sql`): `owner_id` is the payee (always an owner), `client_id` the payer (a client, or the other owner). Routers for paying-side actions use `CurrentUser`; SQL checks the project's ids. The API tags each project with `my_side` ('payee'|'payer') and the UI must branch on that, never on `profile.role`.
- Projects can also be created through `project_proposals` (either side proposes, the recipient accepts; a payee must be an owner, a client can only propose as payer to an owner). Accepting inserts the project in the same transaction. There is NO direct create endpoint: every new project needs the recipient's acceptance (`create_project` in SQL is only a helper for tests).
- `links` (jsonb, max 10 `{label,url}`, http/https only) on projects and payments are validated by `validate_links()` in SQL and by pydantic; render them only with `rel="noopener noreferrer"`. Confirmed-payment change requests do not change links.
- Projects are deleted only through `project_delete_requests` (`004_project_deletion.sql`): either party asks, the OTHER party approves (the requester cannot self-approve). Deletion is soft (`projects.status='deleted'`); payments are kept. `block_deleted_project()` triggers stop any write under a deleted project, and `project_summaries` hides deleted projects. Approval cancels open budget/change requests and marks pending payments `deleted` BEFORE flagging the project.
- Owners can record a received payment (`005_owner_recorded_payment.sql`, `record_received_payment`): it is inserted already `confirmed` (created_by = decided_by = owner) and is "recorded by owner" when `created_by = projects.owner_id`. The client disputes it via the normal payment change request; no proof upload for these.
