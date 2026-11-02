-- Project Payment Tracker: schema, invariants and business-rule functions.
-- All authorization (ownership / assignment) is checked inside the functions below.
-- The backend calls them with the service-role key; RLS is enabled with no public policies.

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'client')),
  full_name text not null,
  email text not null,
  must_change_password boolean not null default false,
  created_by uuid references profiles (id),
  created_at timestamptz not null default now()
);

create table projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles (id),
  client_id uuid not null references profiles (id),
  title text not null check (length(trim(title)) > 0),
  description text not null default '',
  budget numeric(12, 2) not null check (budget > 0),
  status text not null default 'active' check (status in ('active', 'completed')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index projects_owner_idx on projects (owner_id);
create index projects_client_idx on projects (client_id);

create table payments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects (id),
  amount numeric(12, 2) not null check (amount > 0),
  paid_on date not null,
  method text not null default '',
  reference text not null default '',
  note text not null default '',
  proof_path text,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  reject_reason text,
  created_by uuid not null references profiles (id),
  decided_by uuid references profiles (id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index payments_project_status_idx on payments (project_id, status);

create table budget_requests (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects (id),
  old_budget numeric(12, 2) not null,
  new_budget numeric(12, 2) not null check (new_budget > old_budget),
  note text not null default '',
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create unique index budget_requests_one_pending_idx
  on budget_requests (project_id) where status = 'pending';

alter table profiles enable row level security;
alter table projects enable row level security;
alter table payments enable row level security;
alter table budget_requests enable row level security;

-- ---------------------------------------------------------------------------
-- Invariant triggers
-- ---------------------------------------------------------------------------

create function enforce_max_two_owners() returns trigger language plpgsql as $$
begin
  if new.role = 'owner' then
    perform pg_advisory_xact_lock(hashtext('owner_limit'));
    if (select count(*) from profiles where role = 'owner') >= 2 then
      raise exception 'CONFLICT: at most 2 owner accounts are allowed';
    end if;
  end if;
  return new;
end $$;

create trigger profiles_max_two_owners
  before insert on profiles
  for each row execute function enforce_max_two_owners();

-- Decided payments / budget requests are immutable history and are never deleted.
create function enforce_decided_immutable() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'CONFLICT: % rows cannot be deleted', tg_table_name;
  end if;
  if old.status <> 'pending' then
    raise exception 'CONFLICT: a decided % row cannot be modified', tg_table_name;
  end if;
  return new;
end $$;

create trigger payments_immutable
  before update or delete on payments
  for each row execute function enforce_decided_immutable();

create trigger budget_requests_immutable
  before update or delete on budget_requests
  for each row execute function enforce_decided_immutable();

-- ---------------------------------------------------------------------------
-- Business rules. Error messages are prefixed so the API can map them:
-- NOTFOUND / FORBIDDEN / CONFLICT / INVALID
-- ---------------------------------------------------------------------------

create function create_project(
  p_owner uuid, p_client uuid, p_title text, p_description text, p_budget numeric
) returns projects language plpgsql as $$
declare
  result projects;
begin
  if not exists (select 1 from profiles where id = p_owner and role = 'owner') then
    raise exception 'FORBIDDEN: only an owner can create projects';
  end if;
  if not exists (select 1 from profiles where id = p_client and role = 'client') then
    raise exception 'INVALID: client not found';
  end if;
  insert into projects (owner_id, client_id, title, description, budget)
  values (p_owner, p_client, trim(p_title), coalesce(p_description, ''), p_budget)
  returning * into result;
  return result;
end $$;

create function log_payment(
  p_project uuid, p_client uuid, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text
) returns payments language plpgsql as $$
declare
  proj projects;
  committed numeric;
  result payments;
begin
  select * into proj from projects where id = p_project for update;
  if not found then raise exception 'NOTFOUND: project not found'; end if;
  if proj.client_id <> p_client then
    raise exception 'FORBIDDEN: this project belongs to another client';
  end if;
  if proj.status = 'completed' then
    raise exception 'CONFLICT: project is completed; no further payments can be logged';
  end if;

  select coalesce(sum(amount), 0) into committed
  from payments where project_id = p_project and status in ('pending', 'confirmed');

  if p_amount > proj.budget - committed then
    raise exception 'INVALID: amount exceeds the remaining budget of %', proj.budget - committed;
  end if;

  insert into payments (project_id, amount, paid_on, method, reference, note, created_by)
  values (p_project, p_amount, p_paid_on, coalesce(p_method, ''), coalesce(p_reference, ''),
          coalesce(p_note, ''), p_client)
  returning * into result;
  return result;
end $$;

create function attach_payment_proof(p_payment uuid, p_client uuid, p_path text)
returns payments language plpgsql as $$
declare
  result payments;
begin
  update payments set proof_path = p_path
  where id = p_payment and created_by = p_client and status = 'pending'
  returning * into result;
  if not found then
    raise exception 'CONFLICT: payment not found, not yours, or already decided';
  end if;
  return result;
end $$;

create function decide_payment(
  p_payment uuid, p_owner uuid, p_confirm boolean, p_reason text
) returns payments language plpgsql as $$
declare
  pay payments;
  proj projects;
  confirmed_total numeric;
begin
  select pr.* into proj from projects pr
  join payments pa on pa.project_id = pr.id
  where pa.id = p_payment for update of pr;
  if not found then raise exception 'NOTFOUND: payment not found'; end if;
  if proj.owner_id <> p_owner then
    raise exception 'FORBIDDEN: this project belongs to another owner';
  end if;

  select * into pay from payments where id = p_payment;
  if pay.status <> 'pending' then
    raise exception 'CONFLICT: payment is already %', pay.status;
  end if;

  if not p_confirm then
    if p_reason is null or length(trim(p_reason)) = 0 then
      raise exception 'INVALID: a reason is required to deny a payment';
    end if;
    update payments set status = 'rejected', reject_reason = trim(p_reason),
      decided_by = p_owner, decided_at = now()
    where id = p_payment returning * into pay;
    return pay;
  end if;

  update payments set status = 'confirmed', decided_by = p_owner, decided_at = now()
  where id = p_payment returning * into pay;

  select coalesce(sum(amount), 0) into confirmed_total
  from payments where project_id = proj.id and status = 'confirmed';

  if confirmed_total >= proj.budget then
    update projects set status = 'completed', completed_at = now() where id = proj.id;
    update budget_requests set status = 'cancelled', responded_at = now()
    where project_id = proj.id and status = 'pending';
  end if;
  return pay;
end $$;

create function request_budget_increase(
  p_project uuid, p_owner uuid, p_new_budget numeric, p_note text
) returns budget_requests language plpgsql as $$
declare
  proj projects;
  result budget_requests;
begin
  select * into proj from projects where id = p_project for update;
  if not found then raise exception 'NOTFOUND: project not found'; end if;
  if proj.owner_id <> p_owner then
    raise exception 'FORBIDDEN: this project belongs to another owner';
  end if;
  if proj.status = 'completed' then
    raise exception 'CONFLICT: project is completed';
  end if;
  if p_new_budget <= proj.budget then
    raise exception 'INVALID: new budget must be greater than the current budget';
  end if;
  if exists (select 1 from budget_requests where project_id = p_project and status = 'pending') then
    raise exception 'CONFLICT: a budget request is already awaiting the client';
  end if;
  insert into budget_requests (project_id, old_budget, new_budget, note)
  values (p_project, proj.budget, p_new_budget, coalesce(p_note, ''))
  returning * into result;
  return result;
end $$;

create function respond_budget_request(p_request uuid, p_client uuid, p_accept boolean)
returns budget_requests language plpgsql as $$
declare
  req budget_requests;
  proj projects;
begin
  select pr.* into proj from projects pr
  join budget_requests br on br.project_id = pr.id
  where br.id = p_request for update of pr;
  if not found then raise exception 'NOTFOUND: budget request not found'; end if;
  if proj.client_id <> p_client then
    raise exception 'FORBIDDEN: this project belongs to another client';
  end if;

  select * into req from budget_requests where id = p_request;
  if req.status <> 'pending' then
    raise exception 'CONFLICT: request is already %', req.status;
  end if;
  if proj.status = 'completed' then
    raise exception 'CONFLICT: project is completed';
  end if;

  update budget_requests
  set status = case when p_accept then 'accepted' else 'rejected' end, responded_at = now()
  where id = p_request returning * into req;

  if p_accept then
    update projects set budget = req.new_budget where id = proj.id;
  end if;
  return req;
end $$;

-- One row per project with money totals; avoids N+1 for lists and dashboards.
create function project_summaries(p_owner uuid default null, p_client uuid default null)
returns table (
  id uuid, owner_id uuid, client_id uuid, client_name text, title text, description text,
  budget numeric, status text, created_at timestamptz, completed_at timestamptz,
  confirmed numeric, pending numeric, pending_count bigint, has_open_budget_request boolean
) language sql stable as $$
  select p.id, p.owner_id, p.client_id, c.full_name, p.title, p.description,
    p.budget, p.status, p.created_at, p.completed_at,
    coalesce(sum(pa.amount) filter (where pa.status = 'confirmed'), 0),
    coalesce(sum(pa.amount) filter (where pa.status = 'pending'), 0),
    count(pa.id) filter (where pa.status = 'pending'),
    exists (select 1 from budget_requests br where br.project_id = p.id and br.status = 'pending')
  from projects p
  join profiles c on c.id = p.client_id
  left join payments pa on pa.project_id = p.id
  where (p_owner is null or p.owner_id = p_owner)
    and (p_client is null or p.client_id = p_client)
  group by p.id, c.full_name
  order by p.created_at desc
$$;

-- Private bucket for payment proof images.
insert into storage.buckets (id, name, public)
values ('payment-proofs', 'payment-proofs', false)
on conflict (id) do nothing;
