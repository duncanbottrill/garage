create or replace function public.get_tesla_connection()
returns table (connected boolean, rotated_at timestamptz, last_error text, access_expires_at timestamptz, rotating boolean)
language sql security definer set search_path = public stable as $$
  select true, c.rotated_at, c.last_error, c.access_expires_at, (c.refresh_lock_until is not null and c.refresh_lock_until > now())
  from tesla_credentials c where c.owner_id = auth.uid()
  union all
  select false, null, null, null, false where not exists (select 1 from tesla_credentials where owner_id = auth.uid())
  limit 1;
$$;
revoke execute on function public.get_tesla_connection() from public, anon;
grant execute on function public.get_tesla_connection() to authenticated;
