-- The payee owner can record a payment they received when the client did not log it.
-- It is confirmed at once (the owner is the one who confirms money received); the client can
-- dispute it through the normal two-party change request (002). Adds one function only:
-- no table, column or existing row is touched. One transaction; not re-runnable.
-- Dry run (optional, read-only): select proname from pg_proc where proname = 'record_received_payment';  -- expect 0 rows
begin;

create function record_received_payment(
  p_project uuid, p_owner uuid, p_amount numeric, p_paid_on date,
  p_method text, p_reference text, p_note text, p_links jsonb default '[]'::jsonb
) returns payments language plpgsql as $$
declare
  proj projects;
  committed numeric;
  result payments;
begin
  select * into proj from projects where id = p_project for update;
  if not found or proj.status = 'deleted' then raise exception 'NOTFOUND: project not found'; end if;
  if proj.owner_id <> p_owner then
    raise exception 'FORBIDDEN: only the owner who is paid for this project can record a received payment';
  end if;
  if proj.status = 'completed' then
    raise exception 'CONFLICT: project is completed; no further payments can be recorded';
  end if;

  select coalesce(sum(amount), 0) into committed
  from payments where project_id = p_project and status in ('pending', 'confirmed');

  if p_amount is null or p_amount <= 0 then raise exception 'INVALID: amount must be positive'; end if;
  if p_amount > proj.budget - committed then
    raise exception 'INVALID: amount exceeds the remaining budget of %', proj.budget - committed;
  end if;

  insert into payments (project_id, amount, paid_on, method, reference, note, links,
                        status, created_by, decided_by, decided_at)
  values (p_project, p_amount, p_paid_on, coalesce(p_method, ''), coalesce(p_reference, ''),
          coalesce(p_note, ''), validate_links(p_links), 'confirmed', p_owner, p_owner, now())
  returning * into result;

  perform recompute_project_status(p_project);
  return result;
end $$;

commit;
