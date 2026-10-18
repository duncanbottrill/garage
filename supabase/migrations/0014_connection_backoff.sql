-- Surface refresh backoff state (added in 0011) through the owner-facing RPC,
-- so the app can tell "refreshing" apart from "stuck in backoff" instead of
-- just seeing a stale rotated_at.
-- The OUT-parameter row type is widening, which `create or replace` cannot do
-- for a `returns table` function — drop and recreate.
drop function if exists public.get_tesla_connection();
create function public.get_tesla_connection()
returns table (connected boolean, rotated_at timestamptz, last_error text, access_expires_at timestamptz, rotating boolean, refresh_failures int, next_refresh_at timestamptz)
language sql security definer set search_path = public stable as $$
  select true, c.rotated_at, c.last_error, c.access_expires_at, (c.refresh_lock_until is not null and c.refresh_lock_until > now()), c.refresh_failures, c.next_refresh_at
  from tesla_credentials c where c.owner_id = auth.uid()
  union all
  select false, null, null, null, false, 0, null where not exists (select 1 from tesla_credentials where owner_id = auth.uid())
  limit 1;
$$;
revoke execute on function public.get_tesla_connection() from public, anon;
grant execute on function public.get_tesla_connection() to authenticated;

-- A bridge secret is looked up by its hash on every bridge request; guarantee
-- the lookup is unique (and give it an index — owner_id being the PK doesn't
-- index secret_hash) now that the hash is the thing attackers would try to collide.
create unique index if not exists bridge_secrets_hash_idx on bridge_secrets(secret_hash);
