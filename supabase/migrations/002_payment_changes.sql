-- Edit / delete of payments.
--  * Pending payments: the client who logged it may edit or delete it directly.
--  * Confirmed payments: need a change request that the OTHER party (owner <-> client) approves.
-- Deleted payments are kept (status 'deleted') so the history stays auditable.

alter table payments drop constraint payments_status_check;
alter table payments add constraint payments_status_check
  check (status in ('pending', 'confirmed', 'rejected', 'deleted'));

create table payment_change_requests (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments (id),
  project_id uuid not null references projects (id),
  kind text not null check (kind in ('edit', 'delete')),
  proposed jsonb,
  previous jsonb not null,
  reason text not null default '',
  requested_by uuid not null references profiles (id),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  responded_by uuid references profiles (id),
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index payment_change_one_pending_idx
  on payment_change_requests (payment_id) where status = 'pending';
create index payment_change_project_idx on payment_change_requests (project_id, status);
alter table payment_change_requests enable row level security;

create trigger payment_change_requests_immutable
  before update or delete on payment_change_requests
  for each row execute function enforce_decided_immutable();

-- Decided payments stay immutable EXCEPT inside respond_payment_change, which sets a
-- transaction-local flag after both parties have agreed.
create or replace function enforce_decided_immutable() returns trigger language plpgsql as $$
begin
  if current_setting('app.allow_payment_change', true) = 'on' and tg_op = 'UPDATE' then
    return new;
  end if;
  if tg_op = 'DELETE' then
    raise exception 'CONFLICT: % rows cannot be deleted', tg_table_name;
  end if;
  if old.status <> 'pending' then
    raise exception 'CONFLICT: a decided % row cannot be modified', tg_table_name;
  end if;
  return new;
end $$;

-- Completed <-> active follows the confirmed total.
create function recompute_project_status(p_project uuid) returns void language plpgsql as $$
declare
  proj projects;
  confirmed_total numeric;
begin
  select * into proj from projects where id = p_project;
  select coalesce(sum(amount), 0) into confirmed_total
  from payments where project_id = p_project and status = 'confirmed';

  if proj.status = 'active' and confirmed_total >= proj.budget then
    update projects set status = 'completed', completed_at = now() where id = p_project;
    update budget_requests set status = 'cancelled', responded_at = now()
    where project_id = p_project and status = 'pending';
  elsif proj.status = 'completed' and confirmed_total < proj.budget then
    update projects set status = 'active', completed_at = null where id = p_project;
  end if;
end $$;

-- Direct edit of a still-pending payment by the client who logged it.
create function edit_pending_payment(
  p_payment uuid, p_client uuid, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text
) returns payments language plpgsql as $$
declare
  proj projects;
  pay payments;
  other numeric;
begin
  select pr.* into proj from projects pr join payments pa on pa.project_id = pr.id
  where pa.id = p_payment for update of pr;
  if not found then raise exception 'NOTFOUND: payment not found'; end if;
  select * into pay from payments where id = p_payment;
  if pay.created_by <> p_client then raise exception 'FORBIDDEN: not your payment'; end if;
  if pay.status <> 'pending' then
    raise exception 'CONFLICT: only pending payments can be edited directly; request a change instead';
  end if;
  if proj.status = 'completed' then raise exception 'CONFLICT: project is completed'; end if;

  select coalesce(sum(amount), 0) into other from payments
  where project_id = proj.id and status in ('pending', 'confirmed') and id <> p_payment;
  if p_amount > proj.budget - other then
    raise exception 'INVALID: amount exceeds the remaining budget of %', proj.budget - other;
  end if;

  update payments set amount = p_amount, paid_on = p_paid_on, method = coalesce(p_method, ''),
    reference = coalesce(p_reference, ''), note = coalesce(p_note, '')
  where id = p_payment returning * into pay;
  return pay;
end $$;

-- Direct delete (soft) of a still-pending payment by its client.
create function delete_pending_payment(p_payment uuid, p_client uuid)
returns payments language plpgsql as $$
declare
  pay payments;
begin
  select pa.* into pay from payments pa join projects pr on pr.id = pa.project_id
  where pa.id = p_payment for update of pr;
  if not found then raise exception 'NOTFOUND: payment not found'; end if;
  if pay.created_by <> p_client then raise exception 'FORBIDDEN: not your payment'; end if;
  if pay.status <> 'pending' then
    raise exception 'CONFLICT: only pending payments can be deleted directly; request a change instead';
  end if;
  update payments set status = 'deleted' where id = p_payment returning * into pay;
  return pay;
end $$;

-- Either party proposes an edit/delete of a CONFIRMED payment.
create function propose_payment_change(
  p_payment uuid, p_user uuid, p_kind text, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text, p_reason text
) returns payment_change_requests language plpgsql as $$
declare
  proj projects;
  pay payments;
  other numeric;
  result payment_change_requests;
  proposal jsonb;
begin
  select pr.* into proj from projects pr join payments pa on pa.project_id = pr.id
  where pa.id = p_payment for update of pr;
  if not found then raise exception 'NOTFOUND: payment not found'; end if;
  if p_user not in (proj.owner_id, proj.client_id) then
    raise exception 'FORBIDDEN: you are not part of this project';
  end if;
  select * into pay from payments where id = p_payment;
  if pay.status <> 'confirmed' then
    raise exception 'CONFLICT: only confirmed payments need a change request';
  end if;
  if p_kind not in ('edit', 'delete') then raise exception 'INVALID: unknown change type'; end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'INVALID: a reason is required';
  end if;
  if exists (select 1 from payment_change_requests
             where payment_id = p_payment and status = 'pending') then
    raise exception 'CONFLICT: a change request for this payment is already open';
  end if;

  if p_kind = 'edit' then
    if p_amount is null or p_amount <= 0 or p_paid_on is null then
      raise exception 'INVALID: amount and date are required';
    end if;
    select coalesce(sum(amount), 0) into other from payments
    where project_id = proj.id and status in ('pending', 'confirmed') and id <> p_payment;
    if p_amount > proj.budget - other then
      raise exception 'INVALID: amount exceeds the budget room of %', proj.budget - other;
    end if;
    proposal := jsonb_build_object('amount', p_amount, 'paid_on', p_paid_on,
      'method', coalesce(p_method, ''), 'reference', coalesce(p_reference, ''),
      'note', coalesce(p_note, ''));
  end if;

  insert into payment_change_requests (payment_id, project_id, kind, proposed, previous, reason, requested_by)
  values (p_payment, proj.id, p_kind, proposal,
    jsonb_build_object('amount', pay.amount, 'paid_on', pay.paid_on, 'method', pay.method,
      'reference', pay.reference, 'note', pay.note),
    trim(p_reason), p_user)
  returning * into result;
  return result;
end $$;

-- The OTHER party approves or rejects. Approval applies the change.
create function respond_payment_change(p_request uuid, p_user uuid, p_approve boolean)
returns payment_change_requests language plpgsql as $$
declare
  proj projects;
  req payment_change_requests;
  pay payments;
  other numeric;
begin
  select pr.* into proj from projects pr join payment_change_requests r on r.project_id = pr.id
  where r.id = p_request for update of pr;
  if not found then raise exception 'NOTFOUND: change request not found'; end if;
  if p_user not in (proj.owner_id, proj.client_id) then
    raise exception 'FORBIDDEN: you are not part of this project';
  end if;
  select * into req from payment_change_requests where id = p_request;
  if req.requested_by = p_user then
    raise exception 'FORBIDDEN: the other party must respond to your request';
  end if;
  if req.status <> 'pending' then raise exception 'CONFLICT: request is already %', req.status; end if;

  if not p_approve then
    update payment_change_requests set status = 'rejected', responded_by = p_user, responded_at = now()
    where id = p_request returning * into req;
    return req;
  end if;

  select * into pay from payments where id = req.payment_id;
  if pay.status <> 'confirmed' then raise exception 'CONFLICT: payment is no longer confirmed'; end if;

  perform set_config('app.allow_payment_change', 'on', true);
  if req.kind = 'delete' then
    update payments set status = 'deleted' where id = pay.id;
  else
    select coalesce(sum(amount), 0) into other from payments
    where project_id = proj.id and status in ('pending', 'confirmed') and id <> pay.id;
    if (req.proposed ->> 'amount')::numeric > proj.budget - other then
      raise exception 'INVALID: amount no longer fits the budget; reject this request';
    end if;
    update payments set
      amount = (req.proposed ->> 'amount')::numeric,
      paid_on = (req.proposed ->> 'paid_on')::date,
      method = req.proposed ->> 'method',
      reference = req.proposed ->> 'reference',
      note = req.proposed ->> 'note'
    where id = pay.id;
  end if;
  perform set_config('app.allow_payment_change', 'off', true);

  update payment_change_requests set status = 'approved', responded_by = p_user, responded_at = now()
  where id = p_request returning * into req;
  perform recompute_project_status(proj.id);
  return req;
end $$;

create function cancel_payment_change(p_request uuid, p_user uuid)
returns payment_change_requests language plpgsql as $$
declare
  req payment_change_requests;
begin
  update payment_change_requests set status = 'cancelled', responded_by = p_user, responded_at = now()
  where id = p_request and requested_by = p_user and status = 'pending'
  returning * into req;
  if not found then
    raise exception 'CONFLICT: request not found, not yours, or already answered';
  end if;
  return req;
end $$;

-- Adds pending_changes so the UI can flag projects with an open change request.
drop function project_summaries(uuid, uuid);
create function project_summaries(p_owner uuid default null, p_client uuid default null)
returns table (
  id uuid, owner_id uuid, client_id uuid, client_name text, title text, description text,
  budget numeric, status text, created_at timestamptz, completed_at timestamptz,
  confirmed numeric, pending numeric, pending_count bigint, has_open_budget_request boolean,
  pending_changes bigint
) language sql stable as $$
  select p.id, p.owner_id, p.client_id, c.full_name, p.title, p.description,
    p.budget, p.status, p.created_at, p.completed_at,
    coalesce(sum(pa.amount) filter (where pa.status = 'confirmed'), 0),
    coalesce(sum(pa.amount) filter (where pa.status = 'pending'), 0),
    count(pa.id) filter (where pa.status = 'pending'),
    exists (select 1 from budget_requests br where br.project_id = p.id and br.status = 'pending'),
    (select count(*) from payment_change_requests r where r.project_id = p.id and r.status = 'pending')
  from projects p
  join profiles c on c.id = p.client_id
  left join payments pa on pa.project_id = p.id
  where (p_owner is null or p.owner_id = p_owner)
    and (p_client is null or p.client_id = p_client)
  group by p.id, c.full_name
  order by p.created_at desc
$$;
