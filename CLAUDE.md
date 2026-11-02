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
