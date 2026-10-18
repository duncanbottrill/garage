-- Partitions of public.signals are regular Postgres tables: enabling RLS on
-- the partitioned parent does NOT enable it on each partition, and anon /
-- authenticated hold default grants on every table in the public schema.
-- That means a client can bypass owner_read on `signals` entirely by
-- querying a partition (e.g. signals_202610) directly. Lock every existing
-- partition down, add a default partition (so future out-of-range rows
-- land somewhere RLS-protected instead of erroring the writer), and expose
-- a security-definer helper so whatever job extends partitions later can
-- secure new ones the same way.

create or replace function public.secure_signals_partition(p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  execute format('alter table public.%I enable row level security', p_name);
  execute format('revoke all on table public.%I from anon, authenticated', p_name);
end;
$$;

revoke execute on function public.secure_signals_partition(text) from public, anon, authenticated;

-- Default partition: catches any row whose recorded_at falls outside the
-- pre-created monthly ranges. Create it before the loop below so the loop
-- (which walks pg_inherits) secures it along with every other partition.
create table if not exists signals_default partition of signals default;

do $$
declare r record;
begin
  for r in
    select c.relname
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    where p.relname = 'signals'
  loop
    perform public.secure_signals_partition(r.relname);
  end loop;
end $$;
