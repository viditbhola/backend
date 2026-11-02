-- Undo 006: new projects must be accepted by the other side, so the direct-create helper goes back to
-- client-only (the API no longer calls it). Same signature, create or replace; no table or row is touched.
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
  if not exists (select 1 from profiles where id = p_client and role = 'client') then
    raise exception 'INVALID: client not found';
  end if;
  insert into projects (owner_id, client_id, title, description, budget, links)
  values (p_owner, p_client, trim(p_title), coalesce(p_description, ''), p_budget,
          validate_links(p_links))
  returning * into result;
  return result;
end $$;

commit;
