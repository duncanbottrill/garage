create or replace function increment_usage(p_owner uuid, p_category text, p_count bigint default 1)
returns void language sql security definer set search_path = public as $$
  insert into api_usage(owner_id, category, month, count)
  values (p_owner, p_category, date_trunc('month', now())::date, p_count)
  on conflict (owner_id, category, month) do update set count = api_usage.count + excluded.count;
$$;

create or replace function set_budget_mode(p_vehicle uuid, p_mode text)
returns void language sql security definer set search_path = public as $$
  update vehicles set budget_mode = p_mode where id = p_vehicle;
$$;

revoke execute on function increment_usage(uuid, text, bigint) from public, anon, authenticated;
revoke execute on function set_budget_mode(uuid, text) from public, anon, authenticated;
