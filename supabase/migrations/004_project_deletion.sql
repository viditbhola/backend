-- Deleting a project needs BOTH parties: one asks, the other approves.
-- Deletion is soft: the project and its payments stay in the database (audit trail) but the
-- project disappears from every list and total. Nothing here modifies an existing row.
-- One transaction; not re-runnable (like 001-003).
-- Dry run (optional, read-only): select status, count(*) from projects group by status;  -- no 'deleted' yet
begin;

alter table projects drop constraint projects_status_check;
alter table projects add constraint projects_status_check
  check (status in ('active', 'completed', 'deleted'));
alter table projects add column deleted_at timestamptz;

create table project_delete_requests (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects (id),
  requested_by uuid not null references profiles (id),
  reason text not null default '',
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  responded_by uuid references profiles (id),
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index project_delete_one_pending_idx
  on project_delete_requests (project_id) where status = 'pending';
alter table project_delete_requests enable row level security;

create trigger project_delete_requests_immutable
  before update or delete on project_delete_requests
  for each row execute function enforce_decided_immutable();

-- Once a project is deleted nothing may be added to or changed under it.
create function block_deleted_project() returns trigger language plpgsql as $$
begin
  if exists (select 1 from projects where id = new.project_id and status = 'deleted') then
    raise exception 'CONFLICT: this project was deleted';
  end if;
  return new;
end $$;

create trigger payments_block_deleted
  before insert or update on payments
  for each row execute function block_deleted_project();
create trigger budget_requests_block_deleted
  before insert or update on budget_requests
  for each row execute function block_deleted_project();
create trigger payment_change_requests_block_deleted
  before insert or update on payment_change_requests
  for each row execute function block_deleted_project();

create function request_project_deletion(p_project uuid, p_user uuid, p_reason text)
returns project_delete_requests language plpgsql as $$
declare
  proj projects;
  result project_delete_requests;
begin
  select * into proj from projects where id = p_project for update;
  if not found or proj.status = 'deleted' then raise exception 'NOTFOUND: project not found'; end if;
  if p_user not in (proj.owner_id, proj.client_id) then
    raise exception 'FORBIDDEN: you are not part of this project';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'INVALID: a reason is required';
  end if;
  if exists (select 1 from project_delete_requests where project_id = p_project and status = 'pending') then
    raise exception 'CONFLICT: a deletion request for this project is already open';
  end if;
  insert into project_delete_requests (project_id, requested_by, reason)
  values (p_project, p_user, trim(p_reason))
  returning * into result;
  return result;
end $$;

-- The OTHER party answers. Approving cancels everything still open, then marks the project deleted
-- (in that order: the guard trigger blocks writes once the project is deleted).
create function respond_project_deletion(p_request uuid, p_user uuid, p_approve boolean)
returns project_delete_requests language plpgsql as $$
declare
  proj projects;
  req project_delete_requests;
begin
  select pr.* into proj from projects pr join project_delete_requests r on r.project_id = pr.id
  where r.id = p_request for update of pr;
  if not found then raise exception 'NOTFOUND: deletion request not found'; end if;
  if p_user not in (proj.owner_id, proj.client_id) then
    raise exception 'FORBIDDEN: you are not part of this project';
  end if;
  select * into req from project_delete_requests where id = p_request;
  if req.requested_by = p_user then
    raise exception 'FORBIDDEN: the other party must respond to your request';
  end if;
  if req.status <> 'pending' then raise exception 'CONFLICT: request is already %', req.status; end if;

  if p_approve then
    update budget_requests set status = 'cancelled', responded_at = now()
    where project_id = proj.id and status = 'pending';
    update payment_change_requests set status = 'cancelled', responded_by = p_user, responded_at = now()
    where project_id = proj.id and status = 'pending';
    update payments set status = 'deleted' where project_id = proj.id and status = 'pending';
    update projects set status = 'deleted', deleted_at = now() where id = proj.id;
  end if;

  update project_delete_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      responded_by = p_user, responded_at = now()
  where id = p_request returning * into req;
  return req;
end $$;

create function cancel_project_deletion(p_request uuid, p_user uuid)
returns project_delete_requests language plpgsql as $$
declare
  req project_delete_requests;
begin
  update project_delete_requests set status = 'cancelled', responded_by = p_user, responded_at = now()
  where id = p_request and requested_by = p_user and status = 'pending'
  returning * into req;
  if not found then
    raise exception 'CONFLICT: request not found, not yours, or already answered';
  end if;
  return req;
end $$;

-- As in 003, but hides deleted projects and reports an open deletion request.
drop function project_summaries(uuid, uuid);
create function project_summaries(p_owner uuid default null, p_client uuid default null)
returns table (
  id uuid, owner_id uuid, client_id uuid, client_name text, title text, description text,
  budget numeric, status text, created_at timestamptz, completed_at timestamptz,
  confirmed numeric, pending numeric, pending_count bigint, has_open_budget_request boolean,
  pending_changes bigint, links jsonb, owner_name text, has_open_delete_request boolean
) language sql stable as $$
  select p.id, p.owner_id, p.client_id, c.full_name, p.title, p.description,
    p.budget, p.status, p.created_at, p.completed_at,
    coalesce(sum(pa.amount) filter (where pa.status = 'confirmed'), 0),
    coalesce(sum(pa.amount) filter (where pa.status = 'pending'), 0),
    count(pa.id) filter (where pa.status = 'pending'),
    exists (select 1 from budget_requests br where br.project_id = p.id and br.status = 'pending'),
    (select count(*) from payment_change_requests r where r.project_id = p.id and r.status = 'pending'),
    p.links, o.full_name,
    exists (select 1 from project_delete_requests d where d.project_id = p.id and d.status = 'pending')
  from projects p
  join profiles c on c.id = p.client_id
  join profiles o on o.id = p.owner_id
  left join payments pa on pa.project_id = p.id
  where p.status <> 'deleted'
    and (p_owner is null or p.owner_id = p_owner)
    and (p_client is null or p.client_id = p_client)
  group by p.id, c.full_name, o.full_name
  order by p.created_at desc
$$;

commit;
