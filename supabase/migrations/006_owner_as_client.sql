-- Let an owner create a project directly with the other owner as the paying side (client).
-- Only the role check inside create_project is relaxed; the payee is still always an owner and
-- the projects_payee_not_payer check (003) still blocks paying yourself. No table or row is touched.
-- Same signature, so create or replace is safe to re-run.
begin;

create or replace function create_project(
  p_owner uuid, p_client uuid, p_title text, p_description text, p_budget numeric,
  p_links jsonb default '[]'::jsonb
) returns projects language plpgsql as $$
declare
  result projects;
begin
  if not exists (select 1 from profiles where id = p_owner and role = 'owner') then
    raise exception 'FORBIDDEN: only an owner can create projects';
  end if;
  if p_client = p_owner then
    raise exception 'INVALID: you cannot be both the payer and the payee';
  end if;
  if not exists (select 1 from profiles where id = p_client and role in ('client', 'owner')) then
    raise exception 'INVALID: client not found';
  end if;
  insert into projects (owner_id, client_id, title, description, budget, links)
  values (p_owner, p_client, trim(p_title), coalesce(p_description, ''), p_budget,
          validate_links(p_links))
  returning * into result;
  return result;
end $$;

commit;
