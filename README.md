# Project Payment Tracker

Two **owners** agree projects and budgets with **clients**. Clients log payments (pending); the owner confirms or denies. Only confirmed money counts. When confirmed payments reach the budget the project is completed and locked. Owners can request a budget increase; the client accepts or denies it. Amounts are in INR.

Stack: React + Vite + Tailwind (Vercel) · FastAPI (Render) · Supabase (Postgres, Auth, Storage).

```
frontend/            React app (talks only to the FastAPI backend; Supabase JS is used for login only)
backend/             FastAPI (JWT auth, validation, calls Postgres functions)
supabase/migrations/ schema + business-rule functions (run 001 then 002 in order)
render.yaml          Render blueprint for the backend
```

## Rules live in the database
Budget cap, completion lock, budget-request flow, max-2-owners and "decided rows are immutable" are enforced by Postgres functions/triggers in `supabase/migrations/001_init.sql`, with row locks to avoid races. **All ownership checks are in those functions**; the routers only authenticate and gate on role. The backend uses the service-role key, so RLS has no public policies by design.

## Setup

### 1. Supabase
1. Create a project.
2. SQL editor → run `supabase/migrations/001_init.sql`, then `002_payment_changes.sql`.
3. Settings → API: copy the URL, the `anon` key and the `service_role` key (and the JWT secret if your project uses HS256).

### 2. Backend (local)
```
cd backend
python -m venv .venv && .venv\Scripts\activate    # Windows
pip install -r requirements.txt
copy .env.example .env                             # fill in the values
python -m scripts.create_owner "Your Name" you@example.com "a-strong-password"   # run once per owner (max 2)
uvicorn app.main:app --reload
```
`SUPABASE_JWT_SECRET` is optional; leave it empty to verify tokens through Supabase Auth instead.

### 3. Frontend (local)
```
cd frontend
copy .env.example .env.local     # VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY, VITE_API_URL=http://localhost:8000
npm install
npm run dev
```

### 4. Deploy
- **Render**: New → Blueprint → point at this repo (`render.yaml`). Set `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET` (optional), and `FRONTEND_ORIGIN` = your Vercel URL. The free tier sleeps; the UI shows a "waking up" message and retries.
- **Vercel**: import the repo, root directory `frontend`, set `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_API_URL` (the Render URL). `vercel.json` handles SPA routing.
- Never put the service-role key in the frontend or commit any `.env`.

## Using it
1. Owner signs in → **Clients** → creates a client (email + temporary password; the client must set their own on first login).
2. Owner → **Projects** → creates a project for that client with the agreed budget.
3. Client logs payments (amount, date, reference, optional proof). They show as *pending*.
4. Owner confirms or denies (denial needs a reason). Dashboard shows total earned and pending from clients.
5. Owner can request a budget increase; until the client accepts, logging stays capped at the old budget.
6. Mistakes: the client can edit or delete a payment while it is still pending. Once confirmed, either side can request an edit or delete with a reason, and the other side must approve it (deleted payments stay visible, marked deleted). Approving may reopen a completed project or complete one.

## Tests
Rule tests need a **disposable** Supabase project (payments are append-only, so they are not cleaned up):
```
cd backend
set RUN_DB_TESTS=1
pytest
```
Without `RUN_DB_TESTS=1` they are skipped.
