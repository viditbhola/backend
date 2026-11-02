-- Project requests + links.
--  * A project has a payee (owner_id: gets paid, always an owner) and a payer (client_id).
--    The payer is normally a client but may be the other owner.
--  * Either side can PROPOSE a project; the other side accepts or denies. Accepting creates it.
--  * Projects and payments can carry up to 10 http(s) links.
-- Existing rows are not modified. Old function signatures are replaced by ones with a defaulted
-- trailing p_links, so a not-yet-redeployed backend keeps working.

-- One transaction: if any statement fails, nothing is applied. Not re-runnable (like 001/002).
-- Dry run (optional, read-only): select count(*) from projects where owner_id = client_id;  -- expect 0
begin;

alter table projects add column links jsonb not null default '[]'::jsonb;
alter table payments add column links jsonb not null default '[]'::jsonb;
alter table projects add constraint projects_payee_not_payer check (owner_id <> client_id);

-- Returns the cleaned list (only label + url) or raises INVALID.
create function validate_links(p_links jsonb) returns jsonb language plpgsql immutable as $$
declare
  item jsonb;
  cleaned jsonb := '[]'::jsonb;
begin
  if p_links is null then return cleaned; end if;
  if jsonb_typeof(p_links) <> 'array' then
    raise exception 'INVALID: links must be a list';
  end if;
  if jsonb_array_length(p_links) > 10 then
    raise exception 'INVALID: at most 10 links are allowed';
  end if;
  for item in select * from jsonb_array_elements(p_links) loop
    if jsonb_typeof(item) <> 'object' or jsonb_typeof(item -> 'url') is distinct from 'string' then
      raise exception 'INVALID: every link needs a url';
    end if;
    if length(item ->> 'url') > 2000 or (item ->> 'url') !~* '^https?://[^[:space:]]+$' then
      raise exception 'INVALID: links must be http(s) URLs without spaces';
    end if;
    if length(coalesce(item ->> 'label', '')) > 100 then
      raise exception 'INVALID: a link label is limited to 100 characters';
    end if;
    cleaned := cleaned || jsonb_build_array(jsonb_build_object(
      'label', trim(coalesce(item ->> 'label', '')), 'url', item ->> 'url'));
  end loop;
  return cleaned;
end $$;

-- ---------------------------------------------------------------------------
-- Existing rules, now with links (same bodies as 001/002 plus links handling)
-- ---------------------------------------------------------------------------

drop function create_project(uuid, uuid, text, text, numeric);
create function create_project(
  p_owner uuid, p_client uuid, p_title text, p_description text, p_budget numeric,
  p_links jsonb default '[]'::jsonb
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
  insert into projects (owner_id, client_id, title, description, budget, links)
  values (p_owner, p_client, trim(p_title), coalesce(p_description, ''), p_budget,
          validate_links(p_links))
  returning * into result;
  return result;
end $$;

drop function log_payment(uuid, uuid, numeric, date, text, text, text);
create function log_payment(
  p_project uuid, p_client uuid, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text, p_links jsonb default '[]'::jsonb
) returns payments language plpgsql as $$
declare
  proj projects;
  committed numeric;
  result payments;
begin
  select * into proj from projects where id = p_project for update;
  if not found then raise exception 'NOTFOUND: project not found'; end if;
  if proj.client_id <> p_client then
    raise exception 'FORBIDDEN: you are not the payer of this project';
  end if;
  if proj.status = 'completed' then
    raise exception 'CONFLICT: project is completed; no further payments can be logged';
  end if;

  select coalesce(sum(amount), 0) into committed
  from payments where project_id = p_project and status in ('pending', 'confirmed');

  if p_amount > proj.budget - committed then
    raise exception 'INVALID: amount exceeds the remaining budget of %', proj.budget - committed;
  end if;

  insert into payments (project_id, amount, paid_on, method, reference, note, created_by, links)
  values (p_project, p_amount, p_paid_on, coalesce(p_method, ''), coalesce(p_reference, ''),
          coalesce(p_note, ''), p_client, validate_links(p_links))
  returning * into result;
  return result;
end $$;

-- p_links null keeps the existing links.
drop function edit_pending_payment(uuid, uuid, numeric, date, text, text, text);
create function edit_pending_payment(
  p_payment uuid, p_client uuid, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text, p_links jsonb default null
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
    reference = coalesce(p_reference, ''), note = coalesce(p_note, ''),
    links = case when p_links is null then links else validate_links(p_links) end
  where id = p_payment returning * into pay;
  return pay;
end $$;

-- Adds links and the payee's name; everything else as in 002.
drop function project_summaries(uuid, uuid);
create function project_summaries(p_owner uuid default null, p_client uuid default null)
returns table (
  id uuid, owner_id uuid, client_id uuid, client_name text, title text, description text,
  budget numeric, status text, created_at timestamptz, completed_at timestamptz,
  confirmed numeric, pending numeric, pending_count bigint, has_open_budget_request boolean,
  pending_changes bigint, links jsonb, owner_name text
) language sql stable as $$
  select p.id, p.owner_id, p.client_id, c.full_name, p.title, p.description,
    p.budget, p.status, p.created_at, p.completed_at,
    coalesce(sum(pa.amount) filter (where pa.status = 'confirmed'), 0),
    coalesce(sum(pa.amount) filter (where pa.status = 'pending'), 0),
    count(pa.id) filter (where pa.status = 'pending'),
    exists (select 1 from budget_requests br where br.project_id = p.id and br.status = 'pending'),
    (select count(*) from payment_change_requests r where r.project_id = p.id and r.status = 'pending'),
    p.links, o.full_name
  from projects p
  join profiles c on c.id = p.client_id
  join profiles o on o.id = p.owner_id
  left join payments pa on pa.project_id = p.id
  where (p_owner is null or p.owner_id = p_owner)
    and (p_client is null or p.client_id = p_client)
  group by p.id, c.full_name, o.full_name
  order by p.created_at desc
$$;

-- ---------------------------------------------------------------------------
-- Project proposals
-- ---------------------------------------------------------------------------

create table project_proposals (
  id uuid primary key default gen_random_uuid(),
  proposer_id uuid not null references profiles (id),
  recipient_id uuid not null references profiles (id),
  proposer_side text not null check (proposer_side in ('payee', 'payer')),
  title text not null check (length(trim(title)) > 0),
  description text not null default '',
  budget numeric(12, 2) not null check (budget > 0),
  links jsonb not null default '[]'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  reject_reason text,
  project_id uuid references projects (id),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (proposer_id <> recipient_id)
);
create index project_proposals_proposer_idx on project_proposals (proposer_id, status);
create index project_proposals_recipient_idx on project_proposals (recipient_id, status);
alter table project_proposals enable row level security;

create trigger project_proposals_immutable
  before update or delete on project_proposals
  for each row execute function enforce_decided_immutable();

-- p_side is the proposer's side: 'payee' (I get paid; I must be an owner) or
-- 'payer' (I pay; the recipient must be an owner).
create function create_project_proposal(
  p_proposer uuid, p_recipient uuid, p_side text, p_title text, p_description text,
  p_budget numeric, p_links jsonb default '[]'::jsonb
) returns project_proposals language plpgsql as $$
declare
  proposer_role text;
  recipient_role text;
  result project_proposals;
begin
  select role into proposer_role from profiles where id = p_proposer;
  select role into recipient_role from profiles where id = p_recipient;
  if proposer_role is null then raise exception 'FORBIDDEN: unknown account'; end if;
  if recipient_role is null then raise exception 'INVALID: recipient not found'; end if;
  if p_proposer = p_recipient then
    raise exception 'INVALID: you cannot send a project request to yourself';
  end if;
  if p_side not in ('payee', 'payer') then raise exception 'INVALID: unknown side'; end if;
  if p_side = 'payee' and proposer_role <> 'owner' then
    raise exception 'FORBIDDEN: only an owner can be the one who gets paid';
  end if;
  if p_side = 'payer' and recipient_role <> 'owner' then
    raise exception 'INVALID: a request where you pay must be sent to an owner';
  end if;
  if p_title is null or length(trim(p_title)) = 0 then raise exception 'INVALID: a title is required'; end if;
  if p_budget is null or p_budget <= 0 then raise exception 'INVALID: budget must be positive'; end if;

  insert into project_proposals (proposer_id, recipient_id, proposer_side, title, description, budget, links)
  values (p_proposer, p_recipient, p_side, trim(p_title), coalesce(p_description, ''), p_budget,
          validate_links(p_links))
  returning * into result;
  return result;
end $$;

create function respond_project_proposal(
  p_proposal uuid, p_user uuid, p_accept boolean, p_reason text default null
) returns project_proposals language plpgsql as $$
declare
  prop project_proposals;
  new_project projects;
begin
  select * into prop from project_proposals where id = p_proposal for update;
  if not found then raise exception 'NOTFOUND: project request not found'; end if;
  if prop.recipient_id <> p_user then
    raise exception 'FORBIDDEN: only the person it was sent to can respond';
  end if;
  if prop.status <> 'pending' then
    raise exception 'CONFLICT: request is already %', prop.status;
  end if;

  if not p_accept then
    if p_reason is null or length(trim(p_reason)) = 0 then
      raise exception 'INVALID: a reason is required to deny a request';
    end if;
    update project_proposals set status = 'rejected', reject_reason = trim(p_reason),
      responded_at = now()
    where id = p_proposal returning * into prop;
    return prop;
  end if;

  insert into projects (owner_id, client_id, title, description, budget, links)
  values (
    case when prop.proposer_side = 'payee' then prop.proposer_id else prop.recipient_id end,
    case when prop.proposer_side = 'payee' then prop.recipient_id else prop.proposer_id end,
    prop.title, prop.description, prop.budget, prop.links)
  returning * into new_project;

  update project_proposals set status = 'accepted', project_id = new_project.id,
    responded_at = now()
  where id = p_proposal returning * into prop;
  return prop;
end $$;

create function cancel_project_proposal(p_proposal uuid, p_user uuid)
returns project_proposals language plpgsql as $$
declare
  prop project_proposals;
begin
  update project_proposals set status = 'cancelled', responded_at = now()
  where id = p_proposal and proposer_id = p_user and status = 'pending'
  returning * into prop;
  if not found then
    raise exception 'CONFLICT: request not found, not yours, or already answered';
  end if;
  return prop;
end $$;

commit;
